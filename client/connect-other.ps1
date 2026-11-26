[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('windows','linux','macos')][string]$System,
    [ValidateRange(10,300)][int]$Minutes = 60,
    [switch]$NoConnect,
    [switch]$StatusOnly,
    [switch]$SshOnly,
    [switch]$TestConnection
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
        $statusText = & $ts status --json 2>$null
        $state = $null
        try { $state = $statusText | ConvertFrom-Json } catch {}
        $sameNetwork = (-not $expectedTailnet -or $state.CurrentTailnet.MagicDNSSuffix -eq $expectedTailnet)
        if ($state.BackendState -eq 'Running' -and $sameNetwork) {
            & $ts set --unattended=true --accept-dns=false
            if ($LASTEXITCODE -ne 0) { throw 'Tailscale 无法保持后台连接，请以管理员身份运行启动脚本。' }
            return
        }
        if (-not $config.tailscale_auth_protected) { throw '请先打开 Tailscale 并登录与工作流相同的网络。' }
        if ($state.BackendState -eq 'Running' -and -not $sameNetwork) { Write-Host '本机与远程设备不在同一网络，正在保留原账号并登录工作流网络。' }
        $keyPath = Join-Path $PSScriptRoot ('auth-'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllText($keyPath, (Unprotect-LocalValue $config.tailscale_auth_protected))
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $keyPath /inheritance:r /grant:r "${identity}:(F)" | Out-Null
        & $ts login "--auth-key=file:$keyPath" --accept-dns=false --unattended=true --hostname=client-12138882 --nickname=github-remote-1233 --timeout=60s
        $loginExit = $LASTEXITCODE
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $statusText = & $ts status --json 2>$null
            try { $state = $statusText | ConvertFrom-Json } catch {}
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
        Invoke-Github "/actions/workflows/${System}.yml/dispatches" 'POST' @{ref='main';inputs=@{minutes=[string]$Minutes}} | Out-Null
        for ($i=0; $i -lt 12 -and -not $run; $i++) {
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

try {
    $connection = Get-Connection
    if ($NoConnect) { $connection | ConvertTo-Json -Depth 8; return }
    Ensure-Tailscale
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
            $remoteCommand = if ($System -eq 'linux') { 'printf "SSH_READY\n"; sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding' } else { 'printf "SSH_READY\n"; sysctl -n net.inet.ip.forwarding net.inet6.ip6.forwarding' }
            & ssh.exe @options -o BatchMode=yes -o ConnectTimeout=15 $destination $remoteCommand
            if ($LASTEXITCODE -ne 0) { throw 'SSH 连接检查失败。' }
            return
        } elseif ($System -eq 'linux' -or $SshOnly -or -not $connection.rdp_listening) {
            if ($System -eq 'macos' -and -not $connection.rdp_listening) { Write-Host 'macOS 桌面服务未就绪，先连接 SSH。' }
            & ssh.exe @options $destination
        } else {
            Write-Host 'macOS 桌面需要在系统设置中授权屏幕录制和辅助功能。关闭此窗口会断开隧道。'
            $tunnelArgs = $options + @('-o','BatchMode=yes','-o','ExitOnForwardFailure=yes','-N','-L','127.0.0.1:13389:127.0.0.1:3389',$destination)
            $quoted = $tunnelArgs | ForEach-Object { '"'+$_.Replace('"','\"')+'"' }
            $tunnel = Start-Process -FilePath ssh.exe -ArgumentList $quoted -WindowStyle Hidden -PassThru
            try {
                Start-Sleep -Seconds 3
                if ($tunnel.HasExited) { throw 'SSH 隧道未能启动。' }
                $rdp = Join-Path $PSScriptRoot 'macos.rdp'
                @('full address:s:127.0.0.1:13389','enablecredsspsupport:i:0','authentication level:i:2','prompt for credentials:i:0') | Set-Content -LiteralPath $rdp -Encoding Unicode
                Start-Process -FilePath mstsc.exe -ArgumentList @('"'+$rdp+'"') -Wait
            } finally { if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue } }
        }
    }
} finally { $client.Dispose(); $handler.Dispose() }
