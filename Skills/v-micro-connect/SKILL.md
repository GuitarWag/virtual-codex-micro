---
name: v-micro-connect
description: Connect the current Claude Code session to a key on the Virtual Codex Micro panel, and/or force a key's colour for testing. Use when the user says "/v-micro-connect", "connect to the panel", "connect to the virtual keyboard", "put this session on key N", or asks to test the panel colours — e.g. "/v-micro-connect green", "make my key red", "force amber".
---

# Connect a session to the Virtual Codex Micro panel, or force its colour

Two jobs, same mechanism.

**Connect.** The panel discovers sessions from the outside — parsing `ps` argv,
reading cmux resume checkpoints, watching the cmux event stream. Every one has a
hole: a bare `claude` carries no `--session-id`, a brand-new cmux session has no
resume checkpoint, an idle session emits no events, and a pid claimed by two
surfaces resolves to neither. The session already knows exactly who it is from
`CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`, so it just says so.

**Force a colour.** For testing an integration end to end without waiting for a
real state change. The forced colour goes through the same arbitration as any real
source and **expires after 45 seconds**, so a test cannot leave a key lying.

## Reading the arguments

- A bare number is a slot: `/v-micro-connect 3` → key 3.
- A colour or state word forces that colour: `/v-micro-connect green`.
- Both work together, in either order: `/v-micro-connect 3 red`.
- Neither: connect to the first free key.

Accepted colour words, following the reference device's own legend:

| word | state | key looks |
|---|---|---|
| `white`, `grey`, `idle` | idle | pale |
| `blue`, `thinking`, `running` | running | blue |
| `green`, `done`, `complete` | complete | green |
| `amber`, `yellow`, `waiting`, `needsInput` | needsInput | amber |
| `red`, `failed`, `error` | error | red |
| `hatched`, `unknown`, `lost` | unknown | grey hatch |
| `empty`, `off`, `clear` | unassigned | dark, dashed |

## What to run

Substitute the values you parsed. Drop the `slot` or `state` line entirely when the
user did not give one — do not invent defaults.

```bash
DIR="$HOME/Library/Application Support/VirtualCodexMicro/connect-requests"
mkdir -p "$DIR"
TMP="$(mktemp "$DIR/tmp.XXXXXXXX")"
python3 - "$TMP" <<'PY'
import json, os, sys
# Only these variables, named explicitly. The environment also holds
# CMUX_SOCKET_CAPABILITY, a live socket credential — never capture or print the
# whole environment here.
payload = {
    "session_id": os.environ.get("CLAUDE_CODE_SESSION_ID", ""),
    "pid": int(os.environ["CLAUDE_PID"]) if os.environ.get("CLAUDE_PID", "").isdigit() else None,
    "cwd": os.getcwd(),
    "surface_id": os.environ.get("CMUX_PANEL_ID") or None,
}
# payload["slot"] = 3       # only if the user named a key
# payload["state"] = "green" # only if the user named a colour
if not payload["session_id"]:
    sys.exit("no CLAUDE_CODE_SESSION_ID in this environment — not a Claude Code session?")
with open(sys.argv[1], "w") as f:
    json.dump({k: v for k, v in payload.items() if v is not None}, f)
PY
mv -f "$TMP" "$TMP.json"
echo "request written"
```

The rename is deliberate: the panel reads only `*.json`, so it can never pick up a
half-written request.

## Then

The panel drains requests within about four seconds. Tell the user which key it
landed on and, if a colour was forced, that **it reverts after ~45 seconds** — that
expiry is the feature, not a limitation, so say it plainly rather than as a caveat.

If the panel is not running the request waits on disk and is honoured at next
launch. Say so rather than reporting failure; nothing is lost.

## Testing a whole sequence

To walk the panel through several colours, issue separate requests with a pause
between them — do not batch, because each one lands on the same key and the last
would win. Roughly 3 seconds apart reads well.

To see all seven states at once instead, the app has a dedicated mode that drives
every key together — mention `VCM_COLORTEST=1` when launching, rather than
scripting seven requests.

## When it will not work

- **Every key bound and no slot named.** The panel logs "connect refused: every key
  is taken". Ask which key to take over, then re-run naming that number.
- **Not inside a Claude Code session.** `CLAUDE_CODE_SESSION_ID` is unset and the
  script says so. There is nothing to connect.
- **A colour word the panel does not know** is ignored rather than guessed at, so
  the session connects with its real state. Check the table above.

## Do not

- Do not dump the whole environment into the request or the transcript. The cmux
  variables include a live socket credential.
- Do not write to `bindings.json`. The panel owns it, holds it in memory, and will
  overwrite anything put there. The request directory is the supported way in.
- Do not use a forced colour to demonstrate that an integration works. It proves
  the panel can render a colour, nothing more — a real state change is the only
  evidence the pipeline works.
