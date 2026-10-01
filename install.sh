#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    echo "Run as the logged-in user, without sudo." >&2
    exit 1
fi
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
destination="$HOME/.local/share/codex-ram-guardian"
agent="$HOME/Library/LaunchAgents/local.codex.ram-guardian.plist"
domain="gui/$(id -u)"
mkdir -p "$project_dir/.build/module-cache"
xcrun swiftc -O -module-cache-path "$project_dir/.build/module-cache" "$project_dir/RAMGuardian.swift" -o "$project_dir/.build/ram-guardian"
"$project_dir/.build/ram-guardian" --self-test
mkdir -p "$destination" "$HOME/Library/LaunchAgents"
chmod 700 "$destination"
if [ -f "$agent" ]; then
    cp "$agent" "$destination/launch-agent.previous.plist"
    launchctl bootout "$domain" "$agent" 2>/dev/null || true
fi
install -m 700 "$project_dir/.build/ram-guardian" "$destination/ram-guardian.new"
mv "$destination/ram-guardian.new" "$destination/ram-guardian"
install -m 600 "$project_dir/RAMGuardian.swift" "$destination/RAMGuardian.swift"
install -m 600 "$project_dir/README.md" "$destination/README.md"
if [ ! -f "$destination/config.json" ]; then
    install -m 600 "$project_dir/config.json" "$destination/config.json"
fi
/usr/bin/python3 - "$destination" "$agent" <<'PY'
import plistlib,sys,os
from pathlib import Path
base,agent=map(Path,sys.argv[1:])
agent.write_bytes(plistlib.dumps({
    'Label':'local.codex.ram-guardian',
    'ProgramArguments':[str(base/'ram-guardian'),str(base/'config.json')],
    'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':30,
    'ProcessType':'Background','LimitLoadToSessionType':'Aqua',
    'StandardOutPath':str(base/'service.out.log'),
    'StandardErrorPath':str(base/'service.err.log')
}))
os.chmod(agent,0o600)
PY
plutil -lint "$agent"
launchctl enable "$domain/local.codex.ram-guardian"
launchctl bootstrap "$domain" "$agent"
launchctl print "$domain/local.codex.ram-guardian"
echo "Installed. Configuration: $destination/config.json"
echo "Live status: $destination/status.json"
