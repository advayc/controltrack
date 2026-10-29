#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
data_dir="$HOME/Library/Application Support/Focus Ledger"
agent_dir="$HOME/Library/LaunchAgents"
agent_path="$agent_dir/local.focusledger.tracker.plist"
app_path="$data_dir/SelfControl Tracker Helper.app"
service="gui/$(id -u)/local.focusledger.tracker"
mkdir -p "$data_dir" "$agent_dir"
stage_dir="$(mktemp -d "$data_dir/.helper-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/SelfControl Tracker Helper.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$project_dir/helper/Info.plist" "$staged_app/Contents/Info.plist"
cp "$project_dir/helper/SelfControlIcon.icns" "$staged_app/Contents/Resources/SelfControlIcon.icns"
swiftc -target "$(uname -m)-apple-macosx13.0" -O "$project_dir/helper/main.swift" -o "$staged_app/Contents/MacOS/SelfControl Tracker Helper" -framework SwiftUI -framework AppKit -framework IOKit
"$staged_app/Contents/MacOS/SelfControl Tracker Helper" --self-test
xattr -d com.apple.FinderInfo "$staged_app" 2>/dev/null || true
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
python3 - "$stage_dir/new-agent.plist" "$app_path" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump({"Label": "local.focusledger.tracker", "ProgramArguments": [os.path.join(sys.argv[2], "Contents/MacOS/SelfControl Tracker Helper"), "--background"], "RunAtLoad": True, "KeepAlive": True}, f)
PY
if [ -f "$agent_path" ]; then cp -p "$agent_path" "$stage_dir/previous-agent.plist"; fi
launchctl bootout "$service" 2>/dev/null || true
# launchd can return before a terminated GUI service has been fully removed.
for attempt in {1..50}; do
  if ! launchctl print "$service" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if launchctl print "$service" >/dev/null 2>&1; then
  echo "The previous tracker did not stop; its installation was left unchanged." >&2
  exit 1
fi
# A manually opened tracker is not managed by launchd. Stop that exact executable too.
python3 - "$app_path/Contents/MacOS/SelfControl Tracker Helper" <<'PYCODE'
import os, signal, subprocess, sys
executable = sys.argv[1]
result = subprocess.run(["/bin/ps", "-ax", "-o", "pid=,uid=,command="], capture_output=True, text=True, check=True)
for line in result.stdout.splitlines():
    parts = line.strip().split(None, 2)
    if len(parts) == 3 and int(parts[1]) == os.getuid() and (parts[2] == executable or parts[2].startswith(executable + " ")):
        try: os.kill(int(parts[0]), signal.SIGTERM)
        except ProcessLookupError: pass
PYCODE
backup_path=""
if [ -e "$app_path" ]; then
  backup_path="$data_dir/SelfControl Tracker Helper.backup-$(date +%Y%m%d%H%M%S)-$$.disabled"
  mv "$app_path" "$backup_path"
fi
mv "$staged_app" "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path" || true
mv "$stage_dir/new-agent.plist" "$agent_path"
if ! launchctl bootstrap "gui/$(id -u)" "$agent_path"; then
  echo "Could not start the new helper; restoring the previous launch agent." >&2
  rm -rf "$app_path"
  if [ -n "$backup_path" ]; then
    mv "$backup_path" "$app_path"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path" || true
  fi
  if [ -f "$stage_dir/previous-agent.plist" ]; then
    cp -p "$stage_dir/previous-agent.plist" "$agent_path"
    launchctl bootstrap "gui/$(id -u)" "$agent_path" || true
  else
    rm -f "$agent_path"
  fi
  exit 1
fi
echo "SelfControl Tracker helper is installed and runs at login without a Dock icon."
