[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('windows','linux','macos')][string]$System,
    [ValidateRange(10,340)][int]$Minutes = 60,
    [switch]$NoConnect,
    [switch]$StatusOnly,
    [switch]$SshOnly,
    [switch]$TestConnection,
    [switch]$StopAutoRun
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'credentials.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tokenText = [IO.File]::ReadAllText($config.token_file)
$token = [regex]::Match($tokenText, '(?:g?ithub_pat_|gh[pousr]_)[A-Za-z0-9_]+').Value
if (-not $token) { throw '令牌文件中未找到有效格式的 GitHub 令牌。' }
if ($token.StartsWith('ithub_')) { $token = 'g' + $token }
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression
$handler = New-Object Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$client = New-Object Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(45)
$base = 'https://api.github.com/repos/' + $config.repository

function Invoke-Github {
    param([string]$Path, [string]$Method='GET', $Body=$null)
    $request = New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod($Method)), ($base+$Path))
    $request.Headers.TryAddWithoutValidation('Authorization', 'Bearer '+$token) | Out-Null
    $request.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github+json') | Out-Null
    $request.Headers.TryAddWithoutValidation('User-Agent', 'SkyWorkflowRemote') | Out-Null
    if ($null -ne $Body) { $request.Content = New-Object Net.Http.StringContent(($Body | ConvertTo-Json -Depth 8 -Compress), [Text.Encoding]::UTF8, 'application/json') }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $message = $text
            try { $message = ($text | ConvertFrom-Json).message } catch {}
            throw "GitHub $([int]$response.StatusCode): $message"
        }
        if ($text) { return ($text | ConvertFrom-Json) }
    } finally { $request.Dispose() }
}

function Read-ConnectionArtifact {
    param([long]$ArtifactId)
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, ($base+'/actions/artifacts/'+$ArtifactId+'/zip'))
    $request.Headers.TryAddWithoutValidation('Authorization', 'Bearer '+$token) | Out-Null
    $request.Headers.TryAddWithoutValidation('User-Agent', 'SkyWorkflowRemote') | Out-Null
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 302) { throw "下载连接信息失败：HTTP $([int]$response.StatusCode)" }
        $uri = $response.Headers.Location
        if ($uri.Scheme -ne 'https') { throw '连接信息下载地址必须使用 HTTPS。' }
        $download = $client.GetAsync($uri).GetAwaiter().GetResult()
        $download.EnsureSuccessStatusCode() | Out-Null
        [byte[]]$bytes = $download.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $stream = New-Object IO.MemoryStream(,$bytes)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            $entry = $zip.GetEntry('connection.json')
            if (-not $entry -or $entry.Length -gt 65536) { throw '连接信息文件无效。' }
            $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        } finally { $zip.Dispose(); $stream.Dispose() }
    } finally { $request.Dispose() }
}

function Unprotect-LocalValue {
    param([string]$Value)
    $secure = ConvertTo-SecureString $Value
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-TailscaleState {
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $ts
        $start.Arguments = 'status --json'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $output = $process.StandardOutput.ReadToEnd()
            $errorOutput = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -eq 0 -and $output.TrimStart().StartsWith('{')) {
                try {
                    $parsed = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.BackendState) { return $parsed }
                } catch {}
            }
        } finally { $process.Dispose() }
        Start-Sleep -Milliseconds 800
    }
    throw '无法读取 Tailscale 状态。请确认 Tailscale 服务已启动，关闭旧的连接窗口后重新运行桌面脚本。'
}

function Start-LocalTailscaleService {
    $service=Get-Service -Name Tailscale -ErrorAction Stop
    if($service.Status -eq 'Running'){return}
    try{Start-Service -Name Tailscale -ErrorAction Stop}
    catch{
        Write-Host 'Tailscale 服务已停止，需要 Windows 管理员授权来启动服务。'
        $command="`$ErrorActionPreference='Stop';Set-Service -Name Tailscale -StartupType Automatic;Start-Service -Name Tailscale"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $helper=Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -Wait -PassThru
        if($helper.ExitCode -ne 0){throw '启动 Tailscale 服务失败，请允许 Windows 管理员授权后重试。'}
    }
    $service=Get-Service -Name Tailscale
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
}

function Ensure-Tailscale {
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $ts)) { throw '请先安装 Tailscale：https://tailscale.com/download/windows' }
    $expectedTailnet = $connection.tailnet
    if (-not $expectedTailnet) { $expectedTailnet = $config.expected_tailnet }
    $mutex = New-Object Threading.Mutex($false, 'Local\SkyWorkflowRemote-Tailscale')
    $acquired = $false
    $keyPath = $null
    try {
        $acquired = $mutex.WaitOne(90000)
        if (-not $acquired) { throw '另一个连接窗口正在登录 Tailscale，请稍后重试。' }
        Start-LocalTailscaleService
        $state = Get-TailscaleState
        $sameNetwork = (-not $expectedTailnet -or $state.CurrentTailnet.MagicDNSSuffix -eq $expectedTailnet)
        if ($state.BackendState -eq 'Running' -and $sameNetwork) {
            & $ts set --unattended=true --accept-dns=false --hostname=client-12138882
            if ($LASTEXITCODE -ne 0) { throw 'Tailscale 无法保持后台连接，请以管理员身份运行启动脚本。' }
            return
        }
        if (-not $config.tailscale_auth_protected) { throw '请先打开 Tailscale 并登录与工作流相同的网络。' }
        if ($state.BackendState -eq 'Running' -and -not $sameNetwork) { Write-Host '本机与远程设备不在同一网络，正在保留原账号并登录工作流网络。' }
        $keyPath = Join-Path $PSScriptRoot ('auth-'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllText($keyPath, (Unprotect-LocalValue $config.tailscale_auth_protected))
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $keyPath /inheritance:r /grant:r "${identity}:(F)" | Out-Null
        & $ts login "--auth-key=file:$keyPath" --accept-dns=false --unattended=true --hostname=client-12138882 --timeout=60s
        $loginExit = $LASTEXITCODE
        if ($loginExit -ne 0) { throw "Tailscale 登录未完成（退出码 $loginExit）。请查看上方的具体错误。" }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $state = Get-TailscaleState
            if ($state.BackendState -eq 'Running' -and (-not $expectedTailnet -or $state.CurrentTailnet.MagicDNSSuffix -eq $expectedTailnet)) { return }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($state.BackendState -eq 'NeedsMachineAuth') { throw '本机已申请加入网络，需要管理员在 Tailscale 后台批准此设备。' }
        throw "Tailscale 未进入目标网络：状态=$($state.BackendState)，登录退出码=$loginExit。请打开客户端查看网络和设备审批状态。"
    } finally {
        if ($keyPath -and (Test-Path -LiteralPath $keyPath)) { Remove-Item -LiteralPath $keyPath -Force }
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-Connection {
    $runs = Invoke-Github "/actions/workflows/${System}.yml/runs?branch=main&event=workflow_dispatch&per_page=20"
    $run = $runs.workflow_runs | Where-Object { $_.status -in @('queued','in_progress','waiting','pending','requested') } | Select-Object -First 1
    if (-not $run) {
        if ($StatusOnly) { throw '没有活动的工作流。' }
        Write-Host "正在启动 $System，时长 $Minutes 分钟。"
        if ($System -eq 'linux') {
            Invoke-Github '/actions/workflows/linux-watchdog.yml/dispatches' 'POST' @{ref='main'} | Out-Null
        } else {
            Invoke-Github "/actions/workflows/${System}.yml/dispatches" 'POST' @{ref='main';inputs=@{minutes=[string]$Minutes}} | Out-Null
        }
        for ($i=0; $i -lt 45 -and -not $run; $i++) {
            Start-Sleep -Seconds 2
            $runs = Invoke-Github "/actions/workflows/${System}.yml/runs?branch=main&event=workflow_dispatch&per_page=20"
            $run = $runs.workflow_runs | Where-Object { $_.status -in @('queued','in_progress','waiting','pending','requested') } | Select-Object -First 1
        }
        if (-not $run) { throw '已发出启动请求，但还未找到运行记录，请稍后重试。' }
    }
    Write-Host ('运行页面：'+$run.html_url)
    $deadline = [DateTime]::UtcNow.AddMinutes(18)
    while ([DateTime]::UtcNow -lt $deadline) {
        $artifacts = Invoke-Github ('/actions/runs/'+$run.id+'/artifacts')
        $artifact = $artifacts.artifacts | Where-Object { $_.name -eq ($System+'-connection') -and -not $_.expired } | Select-Object -First 1
        if ($artifact) {
            $connection = Read-ConnectionArtifact $artifact.id
            if ($connection.system -ne $System -or [string]$connection.run_id -ne [string]$run.id -or $connection.ip -notmatch '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -or $connection.username -notmatch '^[A-Za-z0-9_-]+$') { throw '连接信息校验失败。' }
            return $connection
        }
        $state = Invoke-Github ('/actions/runs/'+$run.id)
        if ($state.status -eq 'completed') { throw "工作流已结束：$($state.conclusion)，请查看运行页面。" }
        Write-Host '等待远程环境准备就绪……'
        Start-Sleep -Seconds 8
    }
    throw '准备环境超时，请查看运行页面中的日志。'
}

function Resolve-LiveAddress {
    param($Connection)
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    $fixedName = $System
    $legacyName = 'remote-'+$System+'-1233'
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        $status = Get-TailscaleState
        $peers = @($status.Peer.PSObject.Properties.Value | Where-Object {
            $_.Online -and ($_.HostName -in @($fixedName,$legacyName) -or $_.DNSName -like ($fixedName+'.*') -or $_.DNSName -like ($legacyName+'.*'))
        })
        $matchingRun = @($peers | Where-Object { $_.TailscaleIPs -contains $Connection.ip })
        if ($matchingRun.Count -eq 1) { $selected = $matchingRun[0] }
        elseif ($peers.Count -eq 1) { $selected = $peers[0] }
        else { $selected = $null }
        if ($selected) {
            $address = $selected.TailscaleIPs | Where-Object { $_ -match '^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } | Select-Object -First 1
            if ($address) {
                $Connection.ip = [string]$address
                if ($Connection.PSObject.Properties.Name -contains 'alist_url') { $Connection.alist_url = 'http://'+$address+':5244' }
                Write-Host "已自动识别 $fixedName 的 IP：$address"
                return $Connection
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "未能从 Tailscale 在线设备中确认 $fixedName 的 IP，请检查设备是否在线以及账号网络是否一致。"
}

try {
    if ($StopAutoRun) {
        if ($System -ne 'linux') { throw '自动循环开关仅用于 Linux SSH。' }
        Invoke-Github '/actions/variables/LINUX_AUTORUN' 'PATCH' @{name='LINUX_AUTORUN';value='false'} | Out-Null
        $runs=Invoke-Github '/actions/workflows/linux.yml/runs?per_page=30'
        foreach($run in $runs.workflow_runs){if($run.status -ne 'completed'){Invoke-Github ('/actions/runs/'+$run.id+'/cancel') 'POST' | Out-Null}}
        Write-Host 'Linux 自动循环已关闭，已请求停止当前实例。'
        return
    }
    if ($System -eq 'linux' -and -not $StatusOnly) {
        Invoke-Github '/actions/variables/LINUX_AUTORUN' 'PATCH' @{name='LINUX_AUTORUN';value='true'} | Out-Null
    }
    $connection = Get-Connection
    if ($NoConnect) { $connection | ConvertTo-Json -Depth 8; return }
    Ensure-Tailscale
    $connection = Resolve-LiveAddress $connection
    if ($connection.alist_url) { Write-Host ('AList 面板：'+$connection.alist_url+'，用户名：admin') }
    if ($System -eq 'windows') {
        if ($TestConnection) {
            $tcp = New-Object Net.Sockets.TcpClient
            try {
                if (-not $tcp.ConnectAsync($connection.ip,3389).Wait(10000)) { throw 'RDP TCP 连接超时。' }
                if (-not $tcp.Connected) { throw 'RDP 端口不可用。' }
                Write-Output ('Windows RDP port reachable: '+$connection.ip+':3389')
            } finally { $tcp.Dispose() }
            return
        }
        $password = Unprotect-LocalValue $config.password_protected
        & cmdkey.exe "/generic:TERMSRV/$($connection.ip)" '/user:runneradmin' "/pass:$password" | Out-Null
        $password = $null
        Start-Process -FilePath mstsc.exe -ArgumentList @("/v:$($connection.ip):3389")
    } else {
        $sshKey = Join-Path $PSScriptRoot 'id_ed25519'
        $knownHosts = Join-Path $PSScriptRoot 'known_hosts'
        $alias = 'github-'+$System+'-1233'
        $expected = Get-Content -LiteralPath $knownHosts | Where-Object { $_.StartsWith($alias+' ') } | Select-Object -First 1
        if (-not $expected -or -not $connection.ssh_host_key -or -not $expected.StartsWith($alias+' '+$connection.ssh_host_key)) { throw '远程 SSH 主机密钥与本机记录不符，已停止连接。' }
        $options = @('-i',$sshKey,'-p',[string]$connection.ssh_port,'-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$knownHosts),'-o',('HostKeyAlias='+$alias))
        $destination = $connection.username+'@'+$connection.ip
        if ($TestConnection) {
            $remoteCommand = if ($System -eq 'linux') { 'echo SSH_READY; sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding' } else { 'echo SSH_READY; sysctl -n net.inet.ip.forwarding net.inet6.ip6.forwarding' }
            & ssh.exe @options -o BatchMode=yes -o ConnectTimeout=15 $destination $remoteCommand
            if ($LASTEXITCODE -ne 0) { throw 'SSH 连接检查失败。' }
            return
        } elseif ($System -eq 'linux' -or $SshOnly -or -not $connection.rdp_listening) {
            if ($System -eq 'macos' -and -not $connection.rdp_listening) { Write-Host 'macOS 桌面服务未就绪，先连接 SSH。' }
            & ssh.exe @options $destination
        } else {
            Write-Host '正在建立 macOS 桌面隧道。关闭此窗口会断开连接。'
            $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $reservation.Start()
            $localPort = $reservation.LocalEndpoint.Port
            $reservation.Stop()
            $tunnelArgs = $options + @('-o','BatchMode=yes','-o','ConnectTimeout=20','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-o','ExitOnForwardFailure=yes','-N','-L',("127.0.0.1:${localPort}:127.0.0.1:3389"),$destination)
            $quoted = $tunnelArgs | ForEach-Object { '"'+$_.Replace('"','\"')+'"' }
            $errorLog = Join-Path $PSScriptRoot ("macos-tunnel-$PID.log")
            $tunnel = Start-Process -FilePath ssh.exe -ArgumentList $quoted -WindowStyle Hidden -RedirectStandardError $errorLog -PassThru
            $rdp = Join-Path $PSScriptRoot ("macos-$PID.rdp")
            try {
                $ready = $false
                for ($attempt=0; $attempt -lt 60; $attempt++) {
                    if ($tunnel.HasExited) { throw ('SSH 隧道未能启动：'+(Get-Content -LiteralPath $errorLog -Raw -ErrorAction SilentlyContinue)) }
                    $listening = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $localPort -State Listen -ErrorAction SilentlyContinue
                    if ($listening) {$ready=$true;break}
                    Start-Sleep -Milliseconds 500
                }
                if (-not $ready) {throw '等待 macOS 桌面隧道超时，请重试。'}
                @("full address:s:127.0.0.1:$localPort",'enablecredsspsupport:i:0','authentication level:i:2','prompt for credentials:i:0') | Set-Content -LiteralPath $rdp -Encoding Unicode
                Start-Process -FilePath mstsc.exe -ArgumentList @('"'+$rdp+'"') -Wait
            } finally {
                if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $rdp,$errorLog -Force -ErrorAction SilentlyContinue
            }
        }
    }
} finally { $client.Dispose(); $handler.Dispose() }
