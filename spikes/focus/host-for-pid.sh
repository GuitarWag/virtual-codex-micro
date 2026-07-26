#!/bin/bash
# Identification chain: agent PID -> controlling TTY + host application bundle.
# Prints three fields: TTY_PATH  HOST_BUNDLE_PATH  TMUX_TARGET
# TMUX_TARGET is "-" unless the process sits inside a tmux pane.
set -uo pipefail

pid="${1:?usage: host-for-pid.sh <pid>}"

tty_short=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
if [ -z "$tty_short" ] || [ "$tty_short" = "??" ]; then
  echo "no-tty - -"; exit 1
fi
tty_path="/dev/$tty_short"

# tmux: ask the server which pane owns this tty. Cheaper and more reliable than
# walking the tree, because a pane's parent chain dead-ends at the tmux server.
tmux_target="-"
if command -v tmux >/dev/null 2>&1; then
  tmux_target=$(tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
    | awk -v t="$tty_path" '$1 == t {print $2; exit}')
  [ -z "$tmux_target" ] && tmux_target="-"
fi

# Walk PPID chain to the first ancestor living inside an .app bundle.
host="-"
cur="$pid"
for _ in $(seq 1 24); do
  read -r ppid cmd <<<"$(ps -o ppid=,comm= -p "$cur" 2>/dev/null)"
  [ -z "${ppid:-}" ] && break
  case "$cmd" in
    */*.app/Contents/MacOS/*) host="${cmd%%.app/Contents/MacOS/*}.app"; break;;
  esac
  [ "$ppid" = "1" ] || [ "$ppid" = "0" ] && break
  cur="$ppid"
done

# If the pane belongs to tmux, the tree walk above found the tmux server's
# ancestor (usually launchd) - resolve the host from the attached client instead.
if [ "$tmux_target" != "-" ] && [ "$host" = "-" ]; then
  client_tty=$(tmux list-clients -F '#{client_tty}' 2>/dev/null | head -1)
  if [ -n "$client_tty" ]; then
    client_pid=$(ps -t "${client_tty#/dev/}" -o pid= 2>/dev/null | head -1 | tr -d ' ')
    [ -n "$client_pid" ] && host=$("$0" "$client_pid" | awk '{print $2}')
  fi
fi

echo "$tty_path $host $tmux_target"
