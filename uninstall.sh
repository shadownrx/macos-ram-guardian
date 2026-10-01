#!/bin/sh
set -eu
domain="gui/$(id -u)"
agent="$HOME/Library/LaunchAgents/local.codex.ram-guardian.plist"
launchctl bootout "$domain" "$agent" 2>/dev/null || true
launchctl disable "$domain/local.codex.ram-guardian"
echo "RAM Guardian disabled. Configuration, executable and logs preserved."
echo "Run ./install.sh to enable it again."
