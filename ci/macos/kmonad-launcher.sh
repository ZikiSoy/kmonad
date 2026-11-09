#!/bin/bash
# kmonad launcher for macOS (dext).
#
# kmonad talks to the Karabiner-DriverKit-VirtualHIDDevice daemon with an IPC
# protocol that is compiled into the binary. This launcher reads the installed
# VirtualHIDDevice version and runs the kmonad binary built for its protocol.
#
#   VirtualHIDDevice 6.x -> kmonad-p5
#   VirtualHIDDevice 7.x -> kmonad-p6
#   VirtualHIDDevice 8.x -> kmonad-p7
#
# Override with KMONAD_PROTOCOL=5|6|7.

set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLIST=/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist

if [[ -n "${KMONAD_PROTOCOL:-}" ]]; then
  proto="$KMONAD_PROTOCOL"
else
  if ! version=$(defaults read "$PLIST" CFBundleVersion 2>/dev/null); then
    echo "kmonad: Karabiner-DriverKit-VirtualHIDDevice is not installed ($PLIST missing)." >&2
    echo "        Install it from https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases" >&2
    exit 1
  fi
  case "${version%%.*}" in
    6) proto=5 ;;
    7) proto=6 ;;
    8) proto=7 ;;
    *)
      echo "kmonad: VirtualHIDDevice $version is not supported by this build" >&2
      echo "        (supported: 6.x, 7.x, 8.x). Rebuild kmonad against $version," >&2
      echo "        or force one with KMONAD_PROTOCOL=5|6|7." >&2
      exit 1 ;;
  esac
fi

bin="$DIR/kmonad-p$proto"
if [[ ! -x "$bin" ]]; then
  echo "kmonad: $bin not found" >&2
  exit 1
fi

exec "$bin" "$@"
