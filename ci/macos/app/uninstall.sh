#!/bin/bash
# Uninstall KMonad (keeps ~/.config/kmonad and the Karabiner driver).
set -u
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
launchctl bootout system/io.github.zikisoy.kmonad.supervisor 2>/dev/null || true
rm -f /Library/LaunchDaemons/io.github.zikisoy.kmonad.supervisor.plist
pkill -x KMonad 2>/dev/null || true
[ "$(readlink /usr/local/bin/kmonad)" = /Applications/KMonad.app/Contents/Resources/bin/kmonad ] && rm -f /usr/local/bin/kmonad
rm -rf /Applications/KMonad.app "/Library/Application Support/KMonad" /Library/Logs/KMonad
pkgutil --forget io.github.zikisoy.kmonad >/dev/null 2>&1 || true
echo "KMonad removed. Your configs in ~/.config/kmonad were kept."
