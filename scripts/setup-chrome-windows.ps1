$ErrorActionPreference = 'Stop'
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if (-not $chrome) {throw 'Google Chrome is missing from this runner'}
$profile = Join-Path $env:LOCALAPPDATA 'WorkflowChrome\User Data'
$chromeArgs = '--user-data-dir="'+$profile+'" --disk-cache-dir="'+(Join-Path $profile 'Disk Cache')+'" --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-first-run --no-default-browser-check'
$policy = 'HKCU:\Software\Policies\Google\Chrome'
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name UserDataDir -Value $profile -PropertyType String -Force | Out-Null
New-ItemProperty -Path $policy -Name DiskCacheDir -Value (Join-Path $profile 'Disk Cache') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $policy -Name BackgroundModeEnabled -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $policy -Name RestoreOnStartup -Value 1 -PropertyType DWord -Force | Out-Null
$chromeArgs += ' --profile-directory=Default --restore-last-session'

# Windows applies the supported default association policy when the desktop user signs in.
$associations = Join-Path $env:ProgramData 'WorkflowChrome-defaults.xml'
@'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
</DefaultAssociations>
'@ | Set-Content -LiteralPath $associations -Encoding utf8
$systemPolicy = 'HKLM:\Software\Policies\Microsoft\Windows\System'
New-Item -Path $systemPolicy -Force | Out-Null
New-ItemProperty -Path $systemPolicy -Name DefaultAssociationsConfiguration -Value $associations -PropertyType String -Force | Out-Null
$desktop = [Environment]::GetFolderPath('Desktop')
$connectionFile = Join-Path $env:RUNNER_TEMP 'connection.json'
$connection = Get-Content -LiteralPath $connectionFile -Raw | ConvertFrom-Json
$seedFile=Join-Path (Split-Path $profile) 'local-seed-applied.json'
if(Test-Path -LiteralPath $seedFile){$connection|Add-Member -NotePropertyName browser_local_seed_id -NotePropertyValue ((Get-Content -LiteralPath $seedFile -Raw|ConvertFrom-Json).id) -Force}
$sites = [ordered]@{ChatGPT='https://chatgpt.com/';X='https://x.com/';YouTube='https://www.youtube.com/';Google='https://www.google.com/';Baidu='https://www.baidu.com/';Gemini='https://gemini.google.com/';AList=$connection.alist_url}
$shell = New-Object -ComObject WScript.Shell
foreach ($site in $sites.GetEnumerator()) {
    $shortcut = $shell.CreateShortcut((Join-Path $desktop ($site.Key+'.lnk')))
    $shortcut.TargetPath = $chrome
    $shortcut.Arguments = $chromeArgs+' "'+$site.Value+'"'
    $shortcut.IconLocation = $chrome+',0'
    $shortcut.WorkingDirectory = Split-Path $chrome
    $shortcut.Save()
    Remove-Item -LiteralPath (Join-Path $desktop ($site.Key+'.url')) -Force -ErrorAction SilentlyContinue
}
$shortcut = $shell.CreateShortcut((Join-Path $desktop 'Google Chrome.lnk'))
$shortcut.TargetPath=$chrome; $shortcut.Arguments=$chromeArgs; $shortcut.IconLocation=$chrome+',0'; $shortcut.Save()
$shortcutDirectories = @((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))
foreach ($directory in $shortcutDirectories) {
    Get-ChildItem -LiteralPath $directory -Filter '*Chrome*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $link=$shell.CreateShortcut($_.FullName)
        if($link.TargetPath -eq $chrome){$link.Arguments=$chromeArgs;$link.Save()}
    }
}
foreach($entry in @{browser_backup_repository=$env:BROWSER_BACKUP_REPOSITORY;browser_backup_encrypted=$true;browser_profile=$profile;browser_bookmarks_shared=$true}.GetEnumerator()){
    $connection|Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$connection|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $connectionFile -Encoding utf8
Write-Host 'Chrome desktop shortcuts and profile configured; backups go only to the private repository'
