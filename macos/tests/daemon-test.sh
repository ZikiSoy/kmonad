#!/bin/bash
# Integration test of `KMonad --daemon`, unprivileged, against temp dirs and a
# fake kmonad. Usage: daemon-test.sh <path to KMonad binary> <kmonad-cmd>
set -u
KM="$1"; CMD="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
mkdir -p "$T/state" "$T/logs" "$T/bin" "$T/home/.config/kmonad"
for p in 5 6 7; do cp "$HERE/fake-kmonad" "$T/bin/kmonad-p$p"; done
cp "$CMD" "$T/bin/kmonad-cmd"; cp "$HERE/fake-vhid-daemon" "$T/vhid"
chmod +x "$T/bin/"* "$T/vhid"
C="$T/home/.config/kmonad"
echo "tester $(id -u) $T/home" > "$T/user"
echo "8.5.0 1" > "$T/driver"
echo "Apple Internal Keyboard / Trackpad" > "$T/keyboards"
KBD='(defcfg input (iokit-name "Apple Internal Keyboard / Trackpad") output (kext))'
echo "$KBD" > "$C/macbook.kbd"
printf 'macbook.kbd\n' > "$C/enabled"

export KMONAD_STATE_DIR="$T/state" KMONAD_LOG_DIR="$T/logs" KMONAD_BIN_DIR="$T/bin" \
       KMONAD_VHID_DAEMON="$T/vhid" KMONAD_TEST_USER_FILE="$T/user" \
       KMONAD_TEST_DRIVER_FILE="$T/driver" KMONAD_TEST_KEYBOARDS_FILE="$T/keyboards"
"$KM" --daemon > "$T/daemon.out" 2>&1 &
DPID=$!

fail=0
state() { python3 -c "import json,sys; d=json.load(open('$T/state/status.json')); k=[x for x in d['keyboards'] if x['file']=='$1']; print(k[0]['state'] if k else 'none')" 2>/dev/null; }
kcount() { pgrep -f "$T/bin/kmonad-p" | wc -l | tr -d ' '; }
check() { # check <what> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
wait_state() { # wait_state <file> <state> [seconds]
  for _ in $(seq 1 $(( ${3:-10} * 2 ))); do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.5; done
  return 1
}
touchc() { sleep 1.1; echo "$2" > "$C/$1"; }

wait_state macbook.kbd running; check "starts and runs" running "$(state macbook.kbd)"
check "one kmonad" 1 "$(kcount)"
check "our VirtualHIDDevice daemon started" 1 "$(pgrep -f "$T/vhid" | wc -l | tr -d ' ')"

touchc macbook.kbd "$KBD ;; BAD"
wait_state macbook.kbd configErrorOldRunning; check "bad config keeps old running" configErrorOldRunning "$(state macbook.kbd)"
check "old kmonad still there" 1 "$(kcount)"

touchc macbook.kbd "$KBD ;; fixed"
wait_state macbook.kbd running; check "fixed config reloads" running "$(state macbook.kbd)"
check "restarted on save" 2 "$(grep -c 'started macbook.kbd' "$T/daemon.out")"

touchc macbook.kbd "$KBD ;; NOPERM"
wait_state macbook.kbd needsPermission; check "no permission detected" needsPermission "$(state macbook.kbd)"
check "kmonad stopped while waiting" 0 "$(kcount)"

touchc macbook.kbd "$KBD ;; CMD"
wait_state macbook.kbd running 15
sleep 1; check "cmd-button runs through kmonad-cmd" yes "$([ -f "$T/cmd-ran" ] && echo yes || echo no)"

touch "$C/.paused"
wait_state macbook.kbd paused; check "pause" paused "$(state macbook.kbd)"
check "paused: no kmonad" 0 "$(kcount)"
rm "$C/.paused"
wait_state macbook.kbd running; check "resume" running "$(state macbook.kbd)"

echo "8.5.0 0" > "$T/driver"
wait_state macbook.kbd driverNotActivated; check "driver not activated stops" driverNotActivated "$(state macbook.kbd)"
check "no kmonad without virtual keyboard" 0 "$(kcount)"
echo "9.0.0 1" > "$T/driver"
wait_state macbook.kbd driverUnsupported; check "unsupported driver" driverUnsupported "$(state macbook.kbd)"
echo "8.5.0 1" > "$T/driver"
wait_state macbook.kbd running; check "driver back" running "$(state macbook.kbd)"

touchc macbook.kbd "$KBD ;; NOVHID"
wait_state macbook.kbd waitingDriver; check "virtual keyboard lost stops kmonad" waitingDriver "$(state macbook.kbd)"
touchc macbook.kbd "$KBD"
wait_state macbook.kbd running 15; check "back after virtual keyboard returns" running "$(state macbook.kbd)"

echo "$KBD" > "$C/other.kbd"; sleep 1.1; printf 'macbook.kbd\nother.kbd\n' > "$C/enabled"
wait_state other.kbd conflict; check "same keyboard twice" conflict "$(state other.kbd)"
check "still one kmonad" 1 "$(kcount)"
sleep 1.1; printf 'macbook.kbd\n' > "$C/enabled"

touchc macbook.kbd "$KBD ;; CRASH"
wait_state macbook.kbd restarting; check "crash restarts" restarting "$(state macbook.kbd)"
touchc macbook.kbd "$KBD"
wait_state macbook.kbd running 40; check "recovers after crashes" running "$(state macbook.kbd)"

: > "$T/user"
sleep 3; check "login window: nothing runs" 0 "$(kcount)"
echo "tester $(id -u) $T/home" > "$T/user"
wait_state macbook.kbd running; check "user back" running "$(state macbook.kbd)"

"$KM" --status > /dev/null 2>&1; KMONAD_STATE_DIR="$T/state" "$KM" --status

kill -TERM "$DPID"; sleep 3
check "daemon stop ends every kmonad" 0 "$(kcount)"
pkill -f "$T/vhid" 2>/dev/null
if [ "$fail" != 0 ]; then
  echo "---- daemon output"; cat "$T/daemon.out"
  echo "---- macbook log"; tail -40 "$T/logs/macbook.log"
fi
exit $fail
