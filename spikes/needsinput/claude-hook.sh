#!/bin/sh
# Installed by Virtual Codex Micro. Its uninstaller deletes this file.
#
# Reads one Claude Code hook payload on stdin and drops it in the app's spool
# directory. The settings entry sets "async": true so the CLI does not wait on
# this, and the script itself does one mkdir, one write and one rename.
#
# Always exits 0: a hook exiting non-zero can block the transition it fired on,
# and exit code 2 is a blocking error the model is told about.
d='/Users/wagnerjosedasilva/Library/Application Support/VirtualCodexMicro/hook-spool'
mkdir -p "$d" 2>/dev/null || exit 0
f=$(mktemp "$d/tmp.XXXXXXXX" 2>/dev/null) || exit 0
# First line is the environment the JSON payload does not carry. CLAUDE_PID is
# the CLI process itself, which is what liveness polling and window focus need.
{
  printf 'vcm\tpid=%s\tterm=%s\tentry=%s\n' "${CLAUDE_PID:-}" "${TERM_PROGRAM:-}" "${CLAUDE_CODE_ENTRYPOINT:-}"
  cat
} > "$f" 2>/dev/null
# Rename last. The receiver reads only *.json, so it never sees a partial write.
mv -f "$f" "$f.json" 2>/dev/null || rm -f "$f" 2>/dev/null
exit 0
