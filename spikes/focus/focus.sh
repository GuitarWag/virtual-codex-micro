#!/bin/bash
# Raise the terminal window/tab hosting the agent process <pid>.
# Prints one of:
#   focused <emulator> <tty> [tmux-target]   - window and tab/pane both targeted
#   app-only <emulator>                      - app raised, tab NOT targetable
#   unsupported <emulator>                   - cannot even raise the app
#   detached-tmux <target>                   - pane selected, but no client to raise
#   no-tty                                   - process has no controlling terminal
#
# Exit status mirrors that: 0 focused, 1 degraded, 2 impossible.
set -uo pipefail
cd "$(dirname "$0")"

pid="${1:?usage: focus.sh <pid>}"
read -r tty host tmux_target <<<"$(./host-for-pid.sh "$pid")"

[ "$tty" = "no-tty" ] && { echo "no-tty"; exit 2; }

# tmux first: the pane has to be brought into view before raising anything, and for a
# detached session there is no window to raise at all.
if [ "$tmux_target" != "-" ]; then
  tmux select-window -t "${tmux_target%.*}" 2>/dev/null
  tmux select-pane -t "$tmux_target" 2>/dev/null
  if [ "$host" = "-" ]; then
    echo "detached-tmux $tmux_target"; exit 1
  fi
  # raise the client's window, not the pane's tty (a pane tty belongs to no window)
  tty=$(tmux list-clients -t "${tmux_target%%:*}" -F '#{client_tty}' | head -1)
fi

app="$(basename "$host" .app)"
case "$app" in
  Terminal)
    r=$(osascript raise-terminal.applescript "$tty")
    case "$r" in ok*) echo "focused Terminal $tty $tmux_target"; exit 0;;
                 *)   echo "unsupported Terminal ($r)"; exit 2;; esac ;;
  iTerm2|iTerm)
    r=$(osascript raise-iterm.applescript "$tty")
    case "$r" in ok*) echo "focused iTerm2 $tty $tmux_target"; exit 0;;
                 *)   echo "unsupported iTerm2 ($r)"; exit 2;; esac ;;
  cmux)
    # cmux exposes windows/tabs/terminals and a `focus` command, but no tty or pid on
    # a terminal panel, so there is nothing to match a session against. Working
    # directory is the only candidate key and it is ambiguous by design here (several
    # agents in one repo). App-level raise only.
    osascript -e 'tell application "cmux" to activate' >/dev/null 2>&1
    echo "app-only cmux"; exit 1 ;;
  *)
    if [ "$host" = "-" ]; then echo "unsupported unknown-host"; exit 2; fi
    if osascript -e "tell application \"$app\" to activate" >/dev/null 2>&1; then
      echo "app-only $app"; exit 1
    fi
    echo "unsupported $app"; exit 2 ;;
esac
