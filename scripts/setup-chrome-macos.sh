#!/usr/bin/env bash
set -euo pipefail
test -x '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
profile="$HOME/Library/Application Support/WorkflowChrome/User Data"
defaults write com.google.Chrome UserDataDir -string "$profile"
defaults write com.google.Chrome DiskCacheDir -string "$profile/Disk Cache"
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
data.update(browser_backup_repository=os.environ['BROWSER_BACKUP_REPOSITORY'],browser_backup_encrypted=True,browser_profile=os.environ['WORKFLOW_CHROME_PROFILE'],browser_bookmarks_shared=True)
connection.write_text(json.dumps(data,indent=2))
PY
# Set both web URL schemes using Apple's LaunchServices API.
swift - <<'SWIFT'
import CoreServices
for scheme in ["http", "https"] {
    let result = LSSetDefaultHandlerForURLScheme(scheme as CFString, "com.google.Chrome" as CFString)
    guard result == noErr else { fatalError("Could not set Chrome URL handler") }
}
SWIFT
echo 'Chrome shortcuts and shared private browser backups configured'
