$ErrorActionPreference = 'Stop'
# Keep networking and remote desktop services running, without their foreground UI.
& tailscale set --unattended=true
if($LASTEXITCODE -ne 0){throw 'Could not enable unattended Tailscale'}
Set-Service -Name Tailscale -StartupType Automatic
$serverManager='HKCU:\Software\Microsoft\ServerManager'
New-Item -Path $serverManager -Force|Out-Null
New-ItemProperty -Path $serverManager -Name DoNotOpenServerManagerAtLogon -Value 1 -PropertyType DWord -Force|Out-Null
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Get-Process -Name ServerManager,tailscale-ipn -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
foreach($startup in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')){
    if(Test-Path $startup){Remove-ItemProperty -Path $startup -Name Tailscale -Force -ErrorAction SilentlyContinue}
}
Write-Host 'Background setup enabled; Server Manager and Tailscale foreground startup disabled'
