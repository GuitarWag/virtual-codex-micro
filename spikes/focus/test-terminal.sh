#!/bin/bash
# Terminal.app: create three windows with known ttys, then verify the raise script
# lands on the exact tty asked for (not merely "some Terminal window").
# Two independent checks per case:
#   1. intra-app: is the requested tty now the front window's selected tab?
#   2. app-level: did Terminal actually become the frontmost process?
set -uo pipefail
cd "$(dirname "$0")"

mk() { # mk <marker> -> tty of the new window's tab, read from the tab ref itself
  osascript -e "tell application \"Terminal\"
	set t to do script \"printf '%s' '$1'; exec sleep 900\"
	delay 0.6
	return tty of t
end tell"
}

A=$(mk SPIKE_A); echo "window A tty: $A"
B=$(mk SPIKE_B); echo "window B tty: $B"
C=$(mk SPIKE_C); echo "window C tty: $C"

check() { # check <tty> <label> <expect: ok|notfound>
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
  sleep 0.7
  r=$(osascript raise-terminal.applescript "$1")
  sleep 1.0
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  got=$(osascript -e 'tell application "Terminal" to get tty of selected tab of front window')
  case "$3" in
    ok)       [ "$got" = "$1" ] && intra=PASS || intra=FAIL
              [ "$front" = "Terminal" ] && app=PASS || app="FAIL(front=$front)" ;;
    notfound) [ "$r" = "notfound" ] && intra=PASS || intra=FAIL
              [ "$front" != "Terminal" ] && app=PASS || app="FAIL(front=$front)" ;;
  esac
  echo "$2: intra=$intra app-front=$app want=$1 selected=$got script=$r"
}

check "$A" "windowA" ok
check "$C" "windowC" ok
check "$B" "windowB" ok
check "$A" "windowA-again" ok
check "/dev/ttys999" "bogus-tty" notfound

echo "--- id/tty map after all raises (ids must still match) ---"
osascript -e 'tell application "Terminal"
set out to ""
repeat with w in windows
 repeat with t in tabs of w
  try
   set out to out & (id of w as text) & " " & (tty of t) & linefeed
  end try
 end repeat
end repeat
return out
end tell'
