#!/bin/bash
# iTerm2: build one window with two tabs plus a vertical split, and a second window,
# then check per-tty raising. Two independent signals per attempt:
#   intra  - is the requested tty now iTerm2's current session?
#   front  - did iTerm2 become the frontmost app?
# A human at the keyboard can steal `front`, so intra is the load-bearing check.
set -uo pipefail
cd "$(dirname "$0")"

read -r W1 T1A T1B T1BSPLIT W2ID T2A <<<"$(osascript <<'EOS'
tell application "iTerm2"
	set w1 to (create window with default profile)
	delay 0.6
	set s1 to current session of w1
	set t2 to (create tab with default profile) in w1
	delay 0.6
	set s2 to current session of t2
	set s3 to (split vertically with default profile) of s2
	delay 0.6
	set w2 to (create window with default profile)
	delay 0.6
	set s4 to current session of w2
	return ((id of w1) as text) & " " & (tty of s1) & " " & (tty of s2) & " " & (tty of s3) & " " & ((id of w2) as text) & " " & (tty of s4)
end tell
EOS
)"
echo "w1=$W1 tab1=$T1A tab2=$T1B tab2split=$T1BSPLIT | w2=$W2ID tab1=$T2A"

cur() { osascript -e 'tell application "iTerm2" to get tty of current session of current window' 2>&1; }

check() { # check <tty> <label>
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
  sleep 0.6
  before=$(cur)
  r=$(osascript raise-iterm.applescript "$1")
  sleep 1.5
  got=$(cur)
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  [ "$got" = "$1" ] && intra=PASS || intra=FAIL
  [ "$front" = "iTerm2" ] && app=PASS || app="FAIL($front)"
  echo "$2: intra=$intra front=$app want=$1 before=$before after=$got script=$r"
}

for round in 1 2; do
  echo "== round $round"
  check "$T1A"      "w1-tab1"
  check "$T2A"      "w2-tab1"
  check "$T1B"      "w1-tab2"
  check "$T1BSPLIT" "w1-tab2-split"
  check "$T1A"      "w1-tab1"
done
