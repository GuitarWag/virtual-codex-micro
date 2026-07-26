#!/bin/bash
# iTerm2: build one window with two tabs plus a vertical split, and a second window.
# Verify the raise script lands on the exact session (window + tab + split) per tty.
set -uo pipefail
cd "$(dirname "$0")"

read -r W1 T1A T1B T1BSPLIT W2 <<<"$(osascript <<'EOS'
tell application "iTerm2"
	set w1 to (create window with default profile)
	delay 0.5
	set s1 to current session of w1
	tell s1 to write text "printf SPIKE_1A"
	set t2 to (create tab with default profile) in w1
	delay 0.5
	set s2 to current session of t2
	tell s2 to write text "printf SPIKE_1B"
	set s3 to (split vertically with default profile) of s2
	delay 0.5
	tell s3 to write text "printf SPIKE_1B_SPLIT"
	set w2 to (create window with default profile)
	delay 0.5
	set s4 to current session of w2
	tell s4 to write text "printf SPIKE_2A"
	delay 0.4
	return ((id of w1) as text) & " " & (tty of s1) & " " & (tty of s2) & " " & (tty of s3) & " " & (tty of s4)
end tell
EOS
)"
echo "iTerm window1=$W1  tab1=$T1A  tab2=$T1B  tab2split=$T1BSPLIT  window2=$W2"

check() { # check <tty> <label> <expect: ok|notfound>
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
  sleep 0.7
  r=$(osascript raise-iterm.applescript "$1")
  sleep 1.0
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  got=$(osascript -e 'tell application "iTerm2" to get tty of current session of current window')
  case "$3" in
    ok)       [ "$got" = "$1" ] && intra=PASS || intra=FAIL
              [ "$front" = "iTerm2" ] && app=PASS || app="FAIL(front=$front)" ;;
    notfound) [ "$r" = "notfound" ] && intra=PASS || intra=FAIL
              [ "$front" != "iTerm2" ] && app=PASS || app="FAIL(front=$front)" ;;
  esac
  echo "$2: intra=$intra app-front=$app want=$1 current=$got script=$r"
}

check "$T1A"      "w1-tab1"       ok
check "$W2"       "w2-tab1"       ok
check "$T1B"      "w1-tab2"       ok
check "$T1BSPLIT" "w1-tab2-split" ok
check "$T1A"      "w1-tab1-again" ok
check "/dev/ttys999" "bogus-tty"  notfound
