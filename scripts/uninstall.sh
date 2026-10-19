#!/bin/bash
# Removes PulseDock from this Mac, reversibly where it touches other apps' configuration.
#   scripts/uninstall.sh [--yes]
#
# 1. Removes PulseDock's hooks from Claude Code and Codex (and restores a chained Codex notify),
#    with the same installers the app uses — backups first, other hooks untouched.
# 2. Quits PulseDock.
# 3. Deletes ~/Library/Application Support/PulseDock (database, helper, socket, backups).
#
# Before running it: if you used Replacement Mode, restore the macOS Dock from PulseDock
# (Settings › Advanced › Restore the macOS Dock), and turn off "Open PulseDock at login".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/PulseDock"
ASSUME_YES="${1:-}"

confirm() {
  [ "$ASSUME_YES" = "--yes" ] && return 0
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[YySs]$ ]]
}

CTL=""
for candidate in "/Applications/PulseDock.app/Contents/Helpers/pulsedockctl" \
                 "$ROOT/build/release/PulseDock.app/Contents/Helpers/pulsedockctl" \
                 "$ROOT/build/debug/PulseDock.app/Contents/Helpers/pulsedockctl"; do
  if [ -x "$candidate" ]; then CTL="$candidate"; break; fi
done

# A Replacement Mode restore point means the macOS Dock still has PulseDock's changes.
if [ -f "$SUPPORT/pulsedock.sqlite" ] && command -v sqlite3 >/dev/null; then
  if sqlite3 "$SUPPORT/pulsedock.sqlite" "select value from settings" 2>/dev/null | grep -q '"systemDockRestorePoint"'; then
    echo "⚠️  Replacement Mode changed the macOS Dock. Restore it first in PulseDock:"
    echo "    Settings › Advanced › Restore the macOS Dock"
    confirm "Continue anyway?" || exit 1
  fi
fi

echo "1/3 Removing PulseDock hooks from Claude Code and Codex…"
if [ -n "$CTL" ]; then
  "$CTL" uninstall-hooks || echo "   Some hooks could not be removed automatically (see above)."
else
  echo "   pulsedockctl not found; remove the hooks from Settings › Advanced before deleting the app."
fi

echo "2/3 Quitting PulseDock…"
osascript -e 'tell application id "app.pulsedock.PulseDock" to quit' >/dev/null 2>&1 || true
pkill -f 'PulseDock.app/Contents/MacOS/PulseDock' 2>/dev/null || true

if [ -d "$SUPPORT" ]; then
  if confirm "3/3 Delete $SUPPORT (history, settings, backups of agent configuration)?"; then
    rm -rf "$SUPPORT"
    echo "   Deleted."
  else
    echo "   Kept."
  fi
fi

defaults delete app.pulsedock.PulseDock >/dev/null 2>&1 || true
echo "Done. Delete PulseDock.app to finish. If it was set to open at login, macOS removes the entry"
echo "when the app is gone (System Settings › General › Login Items)."
