#!/usr/bin/env bash
set -euo pipefail
test -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
profile="$HOME/Library/Application Support/WorkflowChrome/User Data"
defaults write com.google.Chrome UserDataDir -string "$profile"
defaults write com.google.Chrome DiskCacheDir -string "$profile/Disk Cache"
defaults write com.google.Chrome RestoreOnStartup -int 1
mkdir -p "$HOME/Desktop"
export WORKFLOW_CHROME_PROFILE="$profile"
python3 - <<'PY'
import os, pathlib, plistlib, subprocess, json
desktop=pathlib.Path.home()/'Desktop'
sites={'ChatGPT':'https://chatgpt.com/','X':'https://x.com/','YouTube':'https://www.youtube.com/','Google':'https://www.google.com/','Baidu':'https://www.baidu.com/','Gemini':'https://gemini.google.com/'}
for name,url in sites.items():
    # Small application shortcuts explicitly open Chrome and the saved remote profile.
    source=f'''on run
do shell script "open -a " & quoted form of "Google Chrome" & " --args --user-data-dir=" & quoted form of {json.dumps(os.environ['WORKFLOW_CHROME_PROFILE'])} & " --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --no-first-run --no-default-browser-check " & quoted form of {json.dumps(url)}
end run
'''
    subprocess.run(['osacompile','-o',str(desktop/(name+'.app')),'-e',source],check=True,stdout=subprocess.DEVNULL)
connection=pathlib.Path(os.environ['RUNNER_TEMP'])/'connection.json'
data=json.loads(connection.read_text())
seed=pathlib.Path(os.environ['WORKFLOW_CHROME_PROFILE']).parent/'local-seed-applied.json'
if seed.exists(): data['browser_local_seed_id']=json.loads(seed.read_text())['id']
data.update(browser_backup_repository=os.environ['BROWSER_BACKUP_REPOSITORY'],browser_backup_encrypted=True,browser_profile=os.environ['WORKFLOW_CHROME_PROFILE'],browser_bookmarks_shared=True)
connection.write_text(json.dumps(data,indent=2))
PY
# Register Chrome before requesting the system's default web URL handlers.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '/Applications/Google Chrome.app'
swift - <<'SWIFT'
import Foundation
import CoreServices
for scheme in ["http", "https"] {
    let result = LSSetDefaultHandlerForURLScheme(scheme as CFString, "com.google.Chrome" as CFString)
    if result != noErr { print("System web handler request returned \(result) for \(scheme); desktop shortcuts explicitly launch Chrome") }
}
SWIFT
echo 'Chrome shortcuts and shared private browser backups configured'
