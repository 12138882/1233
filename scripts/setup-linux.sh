#!/usr/bin/env bash
set -euo pipefail
[[ "$SSH_PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]] ]] || { echo 'Invalid SSH public key'; exit 1; }
[[ "$SSH_PUBLIC_KEY" != *$'\n'* && "$SSH_PUBLIC_KEY" != *$'\r'* ]] || exit 1
if ! test -x /usr/sbin/sshd; then
  sudo apt-get update -qq
  sudo apt-get install -y openssh-server
fi
chmod go-w "$HOME"
install -d -m 700 "$HOME/.ssh"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
printf '%s\n' "$SSH_HOST_KEY" | tr -d '\r' | sudo tee /etc/ssh/workflow_host_ed25519_key > /dev/null
sudo chmod 600 /etc/ssh/workflow_host_ed25519_key
ts_ip=$(tailscale ip -4)
[[ "$ts_ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
printf '%s\n' "ListenAddress $ts_ip" 'HostKey /etc/ssh/workflow_host_ed25519_key' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/00-workflow.conf > /dev/null
printf '%s\n' 'net.ipv4.ip_forward = 1' 'net.ipv6.conf.all.forwarding = 1' | sudo tee /etc/sysctl.d/99-workflow-forwarding.conf > /dev/null
sudo sysctl -p /etc/sysctl.d/99-workflow-forwarding.conf
sudo /usr/sbin/sshd -t
sudo systemctl enable --now ssh
sudo systemctl restart ssh
export TS_IP="$ts_ip"
python3 - <<'PY'
import json, os, pathlib, subprocess
data = {'system':'linux','ip':os.environ['TS_IP'],'username':os.environ['USER'],'ssh_port':22,'run_id':os.environ['GITHUB_RUN_ID']}
data['ssh_host_key'] = subprocess.check_output(['sudo','ssh-keygen','-y','-f','/etc/ssh/workflow_host_ed25519_key'],text=True).strip()
data['tailnet'] = json.loads(subprocess.check_output(['tailscale','status','--json'],text=True)).get('CurrentTailnet',{}).get('MagicDNSSuffix','')
data['hostname'] = 'remote-linux-1233'
(pathlib.Path(os.environ['RUNNER_TEMP'])/'connection.json').write_text(json.dumps(data,indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as f:
    f.write(f"SSH: `{data['username']}@{data['ip']}`\n\nIPv4 and IPv6 forwarding enabled.\n")
PY
