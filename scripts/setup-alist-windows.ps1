$ErrorActionPreference = 'Stop'
if (-not $env:ALIST_ADMIN_PASSWORD) { throw 'Missing ALIST_ADMIN_PASSWORD' }
$app = Join-Path $env:LOCALAPPDATA 'WorkflowAList'
$data = Join-Path $app 'data'
New-Item -ItemType Directory -Force -Path $app,$data | Out-Null
$archive = Join-Path $env:RUNNER_TEMP 'alist-windows.zip'
Invoke-WebRequest -Uri 'https://github.com/AlistGo/alist/releases/download/v3.66.0/alist-windows-amd64.zip' -OutFile $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '6daf6975932eef646e2d16f47ff2bbf181b0135808773fcaac9b67d297998b36') { throw 'AList SHA256 mismatch' }
Expand-Archive -LiteralPath $archive -DestinationPath $app -Force
$exe = Join-Path $app 'alist.exe'
& $exe admin set $env:ALIST_ADMIN_PASSWORD --data $data *> (Join-Path $app 'admin-setup.log')
if ($LASTEXITCODE -ne 0) { throw 'AList account initialization failed' }
$ip = (& tailscale ip -4).Trim()
$configFile = Join-Path $data 'config.json'
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$config.scheme.address = $ip
$config.scheme.http_port = 5244
$config.scheme.https_port = -1
[IO.File]::WriteAllText($configFile, ($config|ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
Start-Process -FilePath $exe -ArgumentList @('server','--data',('"'+$data+'"')) -WorkingDirectory $app -WindowStyle Hidden -RedirectStandardOutput (Join-Path $app 'server.log') -RedirectStandardError (Join-Path $app 'server-error.log')
New-NetFirewallRule -DisplayName 'Workflow AList over Tailscale' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5244 -LocalAddress $ip -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
$base = "http://${ip}:5244"
function Invoke-Alist {
    param([string]$Path,$Body=$null,[string]$Token='')
    $headers=@{}
    if($Token){$headers.Authorization=$Token}
    $arguments=@{Uri=($base+$Path);Headers=$headers;TimeoutSec=20;NoProxy=$true}
    if($null -ne $Body){$arguments.Method='POST';$arguments.ContentType='application/json';$arguments.Body=($Body|ConvertTo-Json -Depth 15 -Compress)}
    $result=Invoke-RestMethod @arguments
    if($result.code -ne 200){throw ('AList API: '+$result.message)}
    return $result.data
}
$ready=$false
for($i=0;$i -lt 60;$i++){try{Invoke-Alist '/api/public/settings'|Out-Null;$ready=$true;break}catch{Start-Sleep -Seconds 1}}
if(-not $ready){throw 'AList server did not become ready'}
$token=(Invoke-Alist '/api/auth/login' @{username='admin';password=$env:ALIST_ADMIN_PASSWORD}).token
$storages=Invoke-Alist '/api/admin/storage/list?page=1&per_page=100' $null $token
$storage=@{mount_path='/';driver='Local';order=0;addition=(@{root_folder_path='C:\';show_hidden=$true;mkdir_perm='0755';thumbnail=$false;use_ffmpeg=$false}|ConvertTo-Json -Compress);webdav_policy='native_proxy';cache_expiration=0;disabled=$false}
$existing=$storages.content|Where-Object {$_.mount_path -eq '/'}|Select-Object -First 1
if($existing){$storage.id=$existing.id;Invoke-Alist '/api/admin/storage/update' $storage $token|Out-Null}else{Invoke-Alist '/api/admin/storage/create' $storage $token|Out-Null}
Invoke-Alist '/api/fs/list' @{path='/';password='';page=1;per_page=10;refresh=$true} $token | Out-Null
$connectionFile=Join-Path $env:RUNNER_TEMP 'connection.json'
$connection=Get-Content -LiteralPath $connectionFile -Raw|ConvertFrom-Json
foreach($item in @{alist_url=$base;alist_username='admin';alist_storage_root='C:\';alist_mount_path='/'}.GetEnumerator()){$connection|Add-Member -NotePropertyName $item.Key -NotePropertyValue $item.Value -Force}
$connection|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $connectionFile -Encoding utf8
$desktop=[Environment]::GetFolderPath('Desktop')
$sites=[ordered]@{ChatGPT='https://chatgpt.com/';X='https://x.com/';YouTube='https://www.youtube.com/';Google='https://www.google.com/';Baidu='https://www.baidu.com/';Gemini='https://gemini.google.com/';AList=$base}
foreach($site in $sites.GetEnumerator()){[IO.File]::WriteAllText((Join-Path $desktop ($site.Key+'.url')), ('[InternetShortcut]'+"`r`nURL="+$site.Value+"`r`n"),[Text.Encoding]::ASCII)}
Write-Host ('AList ready: '+$base+'; username=admin; mount=/; local root=C:\')
Write-Host 'Desktop shortcuts created: ChatGPT, X, YouTube, Google, Baidu, Gemini, AList'
