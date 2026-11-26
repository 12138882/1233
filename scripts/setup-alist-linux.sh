#!/usr/bin/env bash
set -euo pipefail
: "${ALIST_ADMIN_PASSWORD:?Missing ALIST_ADMIN_PASSWORD}"
app="$HOME/.workflow-alist"
data="$app/data"
install -d -m 700 "$app" "$data"
archive="$RUNNER_TEMP/alist-linux.tar.gz"
curl -fLsS --retry 3 --connect-timeout 20 -o "$archive" https://github.com/AlistGo/alist/releases/download/v3.66.0/alist-linux-amd64.tar.gz
echo '06a2ab394c1bce4d29b84021192aa75350f556bd1a1e98d321ad760170b5ed31  '"$archive" | sha256sum -c -
tar -xzf "$archive" -C "$app" alist
chmod 700 "$app/alist"
sudo test -d /root
"$app/alist" admin set "$ALIST_ADMIN_PASSWORD" --data "$data" > "$app/admin-setup.log" 2>&1
export ALIST_DATA="$data" ALIST_IP="$(tailscale ip -4)"
python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ['ALIST_DATA'])/'config.json'
config = json.loads(p.read_text())
config['scheme']['address'] = os.environ['ALIST_IP']
config['scheme']['http_port'] = 5244
config['scheme']['https_port'] = -1
p.write_text(json.dumps(config, indent=2))
PY
sudo tee /etc/systemd/system/workflow-alist.service > /dev/null <<EOF
[Unit]
Description=Workflow AList local storage
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$app
ExecStart=$app/alist server --data $data
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable workflow-alist.service
sudo systemctl restart workflow-alist.service
python3 - <<'PY'
import json, os, pathlib, time, urllib.request
base = 'http://'+os.environ['ALIST_IP']+':5244'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def request(path, body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']=token
    req=urllib.request.Request(base+path, data=None if body is None else json.dumps(body).encode(), headers=headers)
    with opener.open(req, timeout=15) as response:
        result=json.load(response)
    if result.get('code') != 200: raise RuntimeError('AList API: '+str(result.get('message')))
    return result.get('data')
for attempt in range(60):
    try:
        request('/api/public/settings'); break
    except Exception:
        if attempt==59: raise
        time.sleep(1)
token=request('/api/auth/login',{'username':'admin','password':os.environ['ALIST_ADMIN_PASSWORD']})['token']
storages=request('/api/admin/storage/list?page=1&per_page=100',token=token).get('content') or []
storage={'mount_path':'/c','driver':'Local','order':0,'addition':json.dumps({'root_folder_path':'/root','show_hidden':True,'mkdir_perm':'0755','thumbnail':False,'use_ffmpeg':False}),'webdav_policy':'native_proxy','cache_expiration':0,'disabled':False}
existing=next((s for s in storages if s['mount_path']=='/c'),None) or next((s for s in storages if s['mount_path']=='/' and s['driver']=='Local'),None)
if existing:
    storage['id']=existing['id']; request('/api/admin/storage/update',storage,token)
else:
    request('/api/admin/storage/create',storage,token)
request('/api/fs/list',{'path':'/c','password':'','page':1,'per_page':10,'refresh':True},token)
p=pathlib.Path(os.environ['RUNNER_TEMP'])/'connection.json'
connection=json.loads(p.read_text())
connection.update(alist_url=base,alist_username='admin',alist_storage_root='/root',alist_mount_path='/c')
p.write_text(json.dumps(connection,indent=2))
print('AList ready: '+base+'; username=admin; mount=/c; local root=/root')
PY
