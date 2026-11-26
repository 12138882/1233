param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Archive)
$ErrorActionPreference='Stop'
$rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$expected=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'WorkflowChrome')).TrimEnd('\')
if($rootPath -ne $expected){throw 'Snapshot source must be the remote WorkflowChrome directory'}
$archivePath=[IO.Path]::GetFullPath($Archive)
$tempPath=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
if(-not $archivePath.StartsWith($tempPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Snapshot output must be in runner temporary storage'}
$volume=[IO.Path]::GetPathRoot($rootPath)
$created=Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{Volume=$volume;Context='ClientAccessible'}
if($created.ReturnValue -ne 0){throw ('Could not create browser data snapshot: '+$created.ReturnValue)}
$snapshot=$null
try{
    $snapshot=Get-CimInstance -ClassName Win32_ShadowCopy|Where-Object {$_.ID -eq $created.ShadowID}|Select-Object -First 1
    if(-not $snapshot){throw 'Created browser snapshot was not found'}
    $source=$snapshot.DeviceObject+'\'+$rootPath.Substring($volume.Length)
    # Snapshot files are readable even when Chrome holds an exclusive lock on the live file.
    $errorLog=$archivePath+'.errors'
    & python (Join-Path $PSScriptRoot 'archive-profile.py') $source $archivePath full 2> $errorLog
    if($LASTEXITCODE -ne 0){throw ('Snapshot archive failed: '+$LASTEXITCODE)}
    Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue
}finally{
    if($snapshot -and $snapshot.ID -eq $created.ShadowID){$snapshot|Remove-CimInstance}
}
