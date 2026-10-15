#!/bin/bash
set -euo pipefail
APP="$HOME/Applications/Doubao Reply Notifier.app"
MACOS="$APP/Contents/MacOS"
SERVICE="gui/$(/usr/bin/id -u)/com.local.doubao-reply-notifier.agent"
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
  /bin/launchctl bootout "$SERVICE"
fi
/bin/rm -f "$HOME/Library/LaunchAgents/com.local.doubao-reply-notifier.agent.plist"
pids="$(/usr/bin/pgrep -f "$MACOS/DoubaoReplyNotifier" || true)"
for pid in $pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
/bin/sleep 0.3
pids="$(/usr/bin/pgrep -f "$MACOS/DoubaoReplyNotifier" || true)"
for pid in $pids; do /bin/kill -KILL "$pid" 2>/dev/null || true; done
/bin/rm -f "$HOME/Library/LaunchAgents/com.local.doubao-reply-notifier.plist"
/bin/rm -rf "$HOME/Applications/Doubao Reply Notifier.app" "$HOME/Library/Application Support/DoubaoReplyNotifier"
/bin/rm -f "$HOME/Library/Logs/DoubaoReplyNotifier.log" "$HOME/Library/Logs/DoubaoReplyNotifier.error.log"
printf '%s\n' "Doubao Reply Notifier removed."
