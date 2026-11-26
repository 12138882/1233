$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:DESKTOP_PASSWORD)) { throw 'Missing desktop password' }
$password = ConvertTo-SecureString $env:DESKTOP_PASSWORD -AsPlainText -Force
Set-LocalUser -Name runneradmin -Password $password
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService
$tsAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like '*Tailscale*' } | Select-Object -First 1
if (-not $tsAdapter) { throw 'Tailscale adapter not found' }
New-NetFirewallRule -DisplayName 'Workflow RDP over Tailscale' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -InterfaceAlias $tsAdapter.Name -RemoteAddress '100.64.0.0/10','fd7a:115c:a1e0::/48' | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -Type DWord -Value 1
Get-NetIPInterface | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.InterfaceAlias -notlike 'Loopback*' } | Set-NetIPInterface -Forwarding Enabled
$ip = (& tailscale ip -4).Trim()
if ($LASTEXITCODE -ne 0 -or $ip -notmatch '^100\.\d+\.\d+\.\d+$') { throw 'No Tailscale IP address' }
$status = (& tailscale status --json) | ConvertFrom-Json
@{system='windows';ip=$ip;username='runneradmin';rdp_port=3389;run_id=$env:GITHUB_RUN_ID;tailnet=$status.CurrentTailnet.MagicDNSSuffix;hostname='windows'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'connection.json') -Encoding utf8
"RDP: $ip`:3389`n`nUsername: runneradmin`n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
