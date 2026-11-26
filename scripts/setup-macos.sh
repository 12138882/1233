#!/usr/bin/env bash
set -euo pipefail
[[ "$SSH_PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]] ]] || exit 1
[[ "$SSH_PUBLIC_KEY" != *$'\n'* && "$SSH_PUBLIC_KEY" != *$'\r'* ]] || exit 1
chmod go-w "$HOME"
install -d -m 700 "$HOME/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
printf '%s\n' "$SSH_HOST_KEY" | tr -d '\r' | sudo tee /etc/ssh/workflow_host_ed25519_key > /dev/null
sudo chmod 600 /etc/ssh/workflow_host_ed25519_key
sudo sysctl -w net.inet.ip.forwarding=1
sudo sysctl -w net.inet6.ip6.forwarding=1
export TS_IP="$(tailscale ip -4)"
[[ "$TS_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
config="$RUNNER_TEMP/workflow_sshd_config"
printf '%s\n' 'Port 2222' "ListenAddress $TS_IP" 'HostKey /etc/ssh/workflow_host_ed25519_key' 'AuthorizedKeysFile .ssh/authorized_keys' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' 'UsePAM yes' 'Subsystem sftp internal-sftp' > "$config"
sudo /usr/sbin/sshd -t -f "$config"
sudo /usr/sbin/sshd -f "$config" -E "$RUNNER_TEMP/sshd.log"
nc -z -w 3 "$TS_IP" 2222
python3 - <<'PY'
import getpass, json, os, pathlib, subprocess
data = {'system':'macos','ip':os.environ['TS_IP'],'username':getpass.getuser(),'ssh_port':2222,'run_id':os.environ['GITHUB_RUN_ID'],'rdp_listening':False,'rdp_permissions':'RDP server not installed or unavailable'}
data['ssh_host_key'] = subprocess.check_output(['sudo','ssh-keygen','-y','-f','/etc/ssh/workflow_host_ed25519_key'],text=True).strip()
data['tailnet'] = json.loads(subprocess.check_output(['tailscale','status','--json'],text=True)).get('CurrentTailnet',{}).get('MagicDNSSuffix','')
data['hostname'] = 'remote-macos-1233'
(pathlib.Path(os.environ['RUNNER_TEMP'])/'connection.json').write_text(json.dumps(data,indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as f:
    f.write(f"SSH: `{data['username']}@{data['ip']}`\n\nRDP uses an authenticated SSH tunnel to localhost:3389. macOS screen capture and accessibility permissions require manual authorization.\n")
PY
