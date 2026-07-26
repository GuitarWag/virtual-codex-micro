#!/bin/bash
# tmux: two windows plus a split, attached from a Terminal.app window.
# Checks: pane tty -> pane target -> select-window/select-pane, then raise the
# terminal window hosting the attached client.
set -uo pipefail
cd "$(dirname "$0")"
S=vcmspike

tmux kill-session -t $S 2>/dev/null
tmux new-session -d -s $S -n w1 'printf PANE_W1; exec sleep 900'
tmux new-window -t $S: -n w2 'printf PANE_W2A; exec sleep 900'
tmux split-window -t $S:w2 'printf PANE_W2B; exec sleep 900'
sleep 0.5
echo "--- panes (detached) ---"
tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid}'
echo "--- clients while detached: [$(tmux list-clients -F '#{client_tty}' 2>/dev/null)]"

# attach from a Terminal.app window
CLIENT_TTY=$(osascript -e "tell application \"Terminal\"
	set t to do script \"tmux attach -t $S\"
	delay 1.2
	return tty of t
end tell")
echo "--- client tty (Terminal.app window): $CLIENT_TTY"
sleep 0.8
tmux list-clients -F 'client=#{client_tty} session=#{client_session}'

ptty() { tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}' | awk -v k="$1" '$2==k{print $1}'; }
P1=$(ptty "$S:0.0"); P2A=$(ptty "$S:1.0"); P2B=$(ptty "$S:1.1")
echo "pane ttys: w1=$P1 w2.0=$P2A w2.1=$P2B"

echo "--- identification chain from a pane's own process ---"
for pt in "$P1" "$P2A" "$P2B"; do
  pid=$(ps -t "${pt#/dev/}" -o pid= | head -1 | tr -d ' ')
  echo "pane $pt pid=$pid -> $(./host-for-pid.sh "$pid")"
done

focus_pane() { # focus_pane <pane_tty>
  target=$(tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}' | awk -v t="$1" '$1==t{print $2}')
  [ -z "$target" ] && { echo "no-pane"; return 1; }
  tmux select-window -t "${target%.*}"
  tmux select-pane -t "$target"
  ctty=$(tmux list-clients -F '#{client_tty}' -t "${target%%:*}" | head -1)
  if [ -z "$ctty" ]; then echo "detached"; return 2; fi
  osascript raise-terminal.applescript "$ctty" >/dev/null
  echo "raised $ctty for $target"
}

check() { # check <pane_tty> <label>
  osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
  sleep 0.6
  r=$(focus_pane "$1")
  sleep 1.0
  active=$(tmux display-message -p -t $S: '#{pane_tty}')
  fronttty=$(osascript -e 'tell application "Terminal" to get tty of selected tab of front window' 2>&1)
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  [ "$active" = "$1" ] && a=PASS || a=FAIL
  [ "$fronttty" = "$CLIENT_TTY" ] && b=PASS || b="FAIL($fronttty)"
  echo "$2: active-pane=$a host-window=$b front=$front want=$1 got=$active [$r]"
}

check "$P2B" "w2-split-b"
check "$P1"  "w1"
check "$P2A" "w2-split-a"
check "$P1"  "w1-again"

echo "--- second client attached to the same session (split-brain check) ---"
CLIENT2=$(osascript -e "tell application \"Terminal\"
	set t to do script \"tmux attach -t $S\"
	delay 1.2
	return tty of t
end tell")
echo "client2 tty=$CLIENT2"
tmux list-clients -F 'client=#{client_tty} win=#{client_session}:#{window_index}'
focus_pane "$P2A" >/dev/null
sleep 0.8
echo "after select w2.0, both clients show: $(tmux list-clients -F '#{client_tty}->#{window_index}' | tr '\n' ' ')"
echo "raise picked: $(tmux list-clients -F '#{client_tty}' -t $S | head -1) (first in list, arbitrary)"
