#!/bin/bash
# Uninstall KMonad. Keeps ~/.config/kmonad.
#   --remove-driver  also remove the Karabiner driver, if KMonad installed it
set -u
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
LABEL=io.github.zikisoy.kmonad.daemon
STATE="/Library/Application Support/KMonad"
launchctl bootout "system/$LABEL" 2>/dev/null || true
for _ in $(seq 1 20); do launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
rm -f "/Library/LaunchDaemons/$LABEL.plist"
pkill -f '/Applications/KMonad.app/Contents/Resources/bin/kmonad-p' 2>/dev/null || true
if [ "${1:-}" = --remove-driver ] && [ -f "$STATE/installed-driver" ]; then
  U=$(stat -f %Su /dev/console); UID_=$(id -u "$U" 2>/dev/null || echo "")
  S="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall"
  if [ -n "$UID_" ] && [ "$U" != root ] && [ "$U" != loginwindow ]; then
    launchctl asuser "$UID_" sudo -u "$U" bash "$S/deactivate_driver.sh" 2>/dev/null || true
  fi
  bash "$S/remove_files.sh" 2>/dev/null || true
  killall Karabiner-VirtualHIDDevice-Daemon 2>/dev/null || true
fi
rm -rf "$STATE" /Library/Logs/KMonad
pkill -x KMonad 2>/dev/null || true
rm -rf /Applications/KMonad.app
pkgutil --forget io.github.zikisoy.kmonad >/dev/null 2>&1 || true
echo "KMonad removed. Your configs in ~/.config/kmonad were kept."
