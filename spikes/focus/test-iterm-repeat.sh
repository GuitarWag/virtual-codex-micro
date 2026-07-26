#!/bin/bash
# Reliability run: hit every known iTerm2 tty N times in a shuffled-ish order and
# count how often the requested session actually ends up current.
set -uo pipefail
cd "$(dirname "$0")"

TTYS=("$@")
[ ${#TTYS[@]} -eq 0 ] && { echo "usage: test-iterm-repeat.sh <tty>..."; exit 1; }

pass=0; fail=0
for round in 1 2 3; do
  for tt in "${TTYS[@]}"; do
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    sleep 0.5
    r=$(osascript raise-iterm.applescript "$tt")
    sleep 0.9
    got=$(osascript -e 'tell application "iTerm2" to get tty of current session of current window')
    front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
    if [ "$got" = "$tt" ] && [ "$front" = "iTerm2" ]; then
      pass=$((pass+1)); v=PASS
    else
      fail=$((fail+1)); v=FAIL
    fi
    echo "r$round $v want=$tt got=$got front=$front script=$r"
  done
done
echo "pass=$pass fail=$fail"
