# T-VCMPLAN1-003 — Transcript tailing as a cold-start state source

Spike run 2026-07-26. Corpus: 31 transcript files, 12,541 records, 20 projects, Claude Code
2.1.154 → 2.1.220, plus two `sdk-ts` sessions. Everything under `~/.claude` was read only; no file
there was created, modified or removed.

## VERDICT: ship as a real fallback — but only because it abstains

Tailing gets `running` and `idle` right at production quality and detects liveness within one poll
interval (max 0.23s at a 200ms poll). It **cannot see a pending permission prompt at all**, so
`needsInput` — the single most valuable state in the product — is not inferrable except for one narrow
case. The rules resolve every unresolvable situation to `unknown` rather than guessing, which is what
makes it shippable. **Hooks remain the only source that can turn a key amber.**

## 1. What is actually on disk

```
~/.claude/projects/
  -Users-…-codex-micro/                        # cwd with '/' -> '-'
    b40b5695-….jsonl                           # the session
    b40b5695-…/subagents/agent-*.jsonl         # one per subagent
  -Users-…-examples-gcp/memory/MEMORY.md       # not a transcript
```

Four things the plan did not anticipate:

1. **Subagent transcripts.** Every record has `isSidechain: true` and none ever contains a
   turn-boundary record — so a subagent transcript's tail looks *permanently mid-turn*. These must be
   excluded from session enumeration or every parent session gains N phantom "running" siblings.
2. **`memory/` directories** sit alongside transcripts. Filter on `*.jsonl`, not "files in the dir".
3. **A live session can have no transcript file.** Observed: pid 42513 running with `--session-id
   6e5140c0-…` and no such file anywhere. A session that has not completed its first turn is invisible
   to tailing.
4. **A transcript can have no state-bearing records** — one file is 113 bytes, a single `ai-title`.

### The filename is not the session id

| field | meaning |
|---|---|
| `sessionId` (camelCase) | transcript identity; equals the filename, or the **parent's** id inside `subagents/` |
| `session_id` (snake_case) | the id of the process that wrote the record — a **different** uuid on a resumed or forked session |

Observed: `a29ca670-….jsonl` carries records stamped `session_id: 6e5140c0-…`, and `6e5140c0` is what
the live process's argv shows. Matching a transcript to a process on the filename reports that live
session as dead. Collect every candidate id and match on any.

## 2. Observed record schema

14 top-level `type` values. State-bearing ones:

| type | n | carries turn state? |
|---|---:|---|
| `assistant` | 4709 | **yes** — `message.stop_reason`, `tool_use` blocks |
| `user` | 2658 | **yes** — prompt, `tool_result`, `toolDenialKind` |
| `system` | 604 | **yes** — subtypes below |
| `attachment` | 1102 | no (hook output, reminders) |
| `last-prompt` / `mode` / `permission-mode` / `ai-title` | 678/664/627/627 | no |
| `file-history-snapshot` / `-delta` | 316/137 | no |
| `queue-operation` | 207 | weak — user typed while busy |
| `custom-title` / `agent-name` / `pr-link` | 94/94/24 | no |

`system` subtypes: `stop_hook_summary` 253, `turn_duration` 246, `away_summary` 90, `local_command` 11,
`api_error` 3, `compact_boundary` 1.

`assistant.message.stop_reason`: `tool_use` 4267, `end_turn` 373, `stop_sequence` 5, `null` on
streaming chunks. `stop_details` was `null` in every record.

### Three traps in the format

**Re-verified 2026-07-26 during implementation** against a grown corpus (33 main transcripts, 13,090
records): trap 1 is **worse** than first measured — 24 of 33 tails end on an untimestamped record, not
12 of 31. So the backward scan matters more, not less. Trap 3 held (116 of 387 doubled `end_turn`), trap 2
held (499 cluster occurrences). Subagent transcripts: 21 found, **zero** `turn_duration` records among
them, so the exclusion rationale is exact. `error` confirmed useless at 5 records in 13,090. The
session-id trap reproduced live: file `a29ca670…` carries writer id `6e5140c0…` and joins to pid 42513;
filename matching would report that live session dead.

**Trap 1 — most tail records have no timestamp.** `ai-title`, `mode`, `permission-mode`, `last-prompt`,
`custom-title`, `agent-name` and `file-history-snapshot` carry no `timestamp` field. 12 of 31 files end
on one of them, so "the last record's timestamp" is `None` for nearly half the corpus. Scan backwards
for the newest record that has one.

**Trap 2 — the metadata cluster is not a turn boundary.** `last-prompt → ai-title → mode →
permission-mode` appears 508 times and looks exactly like an end-of-turn flush. It is not: a
466-second `Bash` call has that entire cluster written *inside* the gap between its `tool_use` and its
`tool_result`. Treating it as a boundary marks a busy session complete.

**Trap 3 — `end_turn` is not the end of the turn.** 115 of 372 `end_turn` records are followed
immediately by another; the CLI emits one per assistant message and a turn can contain several. Only
`turn_duration` closes a turn. Reading `end_turn` as "done" was the largest error source in the replay
(657 wrong observations, 5.6% → 0.9% total error once fixed).

## 3. Per-state inferrability

`quiet` = newest timestamped record older than `--quiet-after` (default 60s).

| State | Signal | Confidence | Failure mode |
|---|---|---|---|
| `unassigned` | none — not a transcript property | n/a | Whether a key has a session bound is app state. Tailing must never produce this. |
| `idle` | last event is `turn_duration`/`stop_hook_summary` **and** quiet | **high** | Cannot distinguish "user is reading" from "user quit" from "crashed". Needs the `ps` join. |
| `running` | unresolved `tool_use`, or `stop_reason: null` chunk, or fresh `user`/`tool_result`, and not quiet | **medium** | 1.2% of within-turn silences exceed 60s, so a busy session goes `unknown` for the tail of those. Converse: an abandoned session shows `running` for up to `quiet_after`. |
| `complete` | `turn_duration` and not quiet | **medium as a boundary, none as "user hasn't seen it"** | The transcript cannot express acknowledgement. A heuristic decay to `idle`, not a fact. |
| `needsInput` | only when the sole unresolved `tool_use` is `AskUserQuestion` | **high for that case, unavailable otherwise** | **The important gap.** A pending permission prompt produces no record at all. |
| `error` | `isApiErrorMessage: true` or `system/api_error` | **high but rare and transient** | 5 records in 12,541. The CLI retries up to 10 times and the next record erases the signal. A `tool_result` with `is_error: true` is **not** this — 40 occurrences, all routine; mapping it to `error` would paint keys red constantly. |
| `unknown` | everything else | — | The intended output for every unresolvable case. 6.1% of observations. |

### (a) "finished its turn" vs "waiting for the user"

**Solved for CLI sessions by `turn_duration`,** present at the close of every turn in all 29 `cli`
transcripts across versions 2.1.154 → 2.1.220, with counts independent of `stop_hook_summary` (one file
has 9 to 8). Once the boundary is seen, "finished" and "waiting for the user" are the same state; the
panel calls it `complete` if fresh and `idle` if quiet.

Caveats: **both `sdk-ts` transcripts have zero `turn_duration`** — programmatic sessions fall back to
the `end_turn`-plus-silence rule, source of 90 of the 118 wrong observations. And every session in this
corpus came from a machine with Stop hooks installed throughout, so "`turn_duration` does not require
hooks" rests on the count mismatch and on its nature as a duration metric, not on a controlled test.
**Worth re-verifying by running with no Stop hook.**

### (b) A pending tool-approval prompt — not inferrable

This is the hard limit of the whole approach. Nothing is written between a `tool_use` and its
`tool_result`. All 76 gaps longer than 30 seconds:

```
   8713s  AskUserQuestion   denial=user-rejected   between: <nothing written>
   6028s  Bash              denial=None            between: <nothing written>
   1026s  Bash              denial=None            between: <nothing written>
```

A `Bash` call that ran for 100 minutes and a permission prompt that sat open for 145 minutes before
being rejected produce byte-identical tails. The denial is recorded only *after* the user answers, as
`toolDenialKind: "user-rejected"` — useful for history, useless for a live panel.

The one exception is `AskUserQuestion`: the tool *name* is in the `tool_use` block, and that tool exists
only to wait for a human. High-confidence `needsInput` for "agent asked a question", not for "agent
wants to run a command". `permissionMode` is recorded and could suppress the guess when prompts are
impossible, but cannot produce a positive signal.

Hook results *do* land in the transcript as `attachment` records with `hookEvent` ∈ {`Stop` 200,
`PreToolUse` 103, `PostToolUse` 101, `SessionStart` 34, `SubagentStart` 26, `UserPromptSubmit` 21,
`PostToolBatch` 2}. **No `Notification` event appeared** — and `Notification` is the hook that fires on
a permission prompt. This machine has no Notification hook installed, so that is suggestive rather than
conclusive.

Since `needsInput` is what the PRD's fast-glance thesis rests on, this decides the architecture:
**hooks are not an optimisation over tailing, they are the only source for the amber key.**

### (c) A crashed or abandoned session vs an idle one

Not inferrable from the file; solvable next to it. There is no session-exit record of any kind — a
graceful quit, `Ctrl-C`, a crash and a session sitting at the prompt all leave the same tail.

Two approaches that do not work: `lsof` on the transcript returns nothing even for the session writing
it right now (the CLI appends and closes, so there is no open handle); and file age alone is meaningless
(two sessions here were quiet ~35 minutes with live processes attached).

What works is `ps`. Every running CLI carries its id in argv:

```
58644 /Users/…/claude --session-id b40b5695-25e8-406c-87e1-0585d7e0c005 --settings …
```

One `ps -Ao pid=,command=` every two seconds resolves it. Two limits: the process must have been
launched with `--session-id`, and the mapping is racy across a resume. A session with no matching pid
should render `unknown`, not `idle`.

## 4. Measured accuracy

`replay.py` walks every record, calls the same `infer()` the watcher uses on the prefix only, clock
pinned to 1ms before the next record arrives — the worst-case observation moment. Truth comes from
looking forward, which the live watcher cannot do.

```
quiet_after=60s   observations=13677
  correct    12726   93.0%
  abstained    833    6.1%   (rendered `unknown`)
  WRONG        118    0.9%

  running -> running    12014 ok        running -> idle        90 WRONG  (all sdk-ts)
  running -> unknown      822 abstain   running -> complete    21 WRONG  (tool_use outside window)
  idle    -> idle         341 ok        idle    -> running      4 WRONG
  idle    -> complete     338 ok        needsInput -> running   2 WRONG  (prompt inside quiet_after)
  needsInput -> needsInput 28 ok        error   -> complete     1 WRONG
  error   -> error          5 ok
```

`quiet_after` sweep: 20s → 89.2% correct / 9.9% abstain; 60s → 93.0% / 6.1%; 120s → 93.7% / 5.4%;
300s → 94.0% / 5.0%. Wrong stays 0.9% throughout, so 60s is a fine default.

Silence tolerated by a busy session (gaps strictly inside a turn, n=5354): p50 2.2s, p90 10.8s, p99
74s, max 8713s. 1.2% exceed 60s. There is no `quiet_after` that is both responsive and never wrong;
60s puts the cost on the abstain side, which is the correct direction.

**Two honest caveats.** Truth labels derive from the same transcripts, so this measures whether the
rules are self-consistent with what the file eventually reveals — not agreement with the CLI's actual
internal state. The cross-check against the hook spike's live event stream is outstanding and is the
right gate before M2 relies on any of this. And `needsInput` rests on 31 observations from three denial
events; treat its accuracy as unmeasured.

## 5. Measured detection delay

Two numbers; conflating them would flatter the result.

**Poller latency** (file grows → panel would know), synthetic records at known wall times:

| poll interval | min | p50 | max |
|---|---|---|---|
| 200ms | 0.018s | 0.146s | **0.231s** |
| 50ms | 0.005s | 0.030s | **0.052s** |

Bounded by the poll interval. 200ms comfortably meets the M2 exit criterion of state correct within 1s.
FSEvents is not needed — stat-polling 31 files at 200ms is ~150 syscalls/second.

**End-to-end latency** (event happens → panel would know), 4 live sessions, 102 real appends: min
0.028s, p50 0.215s, p90 0.681s, p99 12.9s, max 14.4s.

The long tail is not the watcher. An `assistant` record is timestamped when the response starts and
written when it finishes, so a slow generation arrives as one large append already 14 seconds old. This
matters in a way the p50 hides: **while the model is generating, nothing is appended at all.** A session
mid-response looks quiet, which is why the `running` reading must decay to `unknown` rather than
persisting. Hooks firing at the moment of a call do not have this property.

## 6. The watcher

`watch.py`, one file, standard library only. No build step — the machine has Command Line Tools without
Xcode, and Python 3 ships with macOS.

```bash
cd spikes/tailing
python3 watch.py --selftest     # 19 assertions on the inference rules
python3 watch.py --snapshot     # cold-start state of every session + live pid
python3 watch.py                # follow; prints transitions, delay stats on exit
python3 delay_test.py 0.05 20   # isolate poller latency in a throwaway tree
```

Analysis scripts, each runnable with no arguments: `analyse.py` (record types, key sets, stop reasons),
`perfile.py` (turn_duration/stop_hook_summary presence by version), `sequence.py` (successor
distribution, tail shapes), `pending.py` (what is written during a long tool gap — nothing),
`gaps.py` (how long a busy session stays silent), `attach.py` (hookEvent domains), `samples.py`
(redacted structural samples), `replay.py` (offline accuracy), `delay_test.py` (poller latency).

All read-only on `~/.claude`. `samples.py` redacts by default — keeps only enum-ish discriminating keys
and replaces every other string with its length, so prose, paths, code and anything secret-shaped never
reach the output.

```
$ python3 watch.py --snapshot
mtime    session       inferred   conf    pid     reason
15:42:48 b40b5695-25e  running    low     58644   queue enqueue
15:41:16 6e5140c0-0d1  idle       medium  42513   turn ended, quiet 178s [resumed; file a29ca670]
15:36:48 5e7e9f47-03b  idle       low     -       end_turn then 430s silence
15:15:21 55bf6efb-22b  idle       medium  26648   turn ended, quiet 2208s
12:17:07 4857be9e-3c6  unknown    none    -       no state-bearing records
-        6e5140c0-0d1  unknown    none    42513   live process, no transcript file on disk
```

Two deliberate ceilings, marked in the source: `TAIL_BYTES = 1MB` on cold start (a `tool_use` older
than the last megabyte loses its pairing — 21 of 118 replay errors), and `stat()` polling instead of
FSEvents (fine to ~50ms and a few hundred files).

## Three things that must be true in the implementation

1. **`unknown` is rendered, never smoothed over.** Every ambiguous tail must reach the key as a grey
   hatch. The 6.1% abstain rate is the feature.
2. **The `ps` join ships with it.** Without liveness, "idle" and "crashed" are the same colour — the
   exact drift the plan calls risk #1.
3. **Subagent transcripts are excluded, and the session↔process join uses the candidate id set rather
   than the filename.** Either mistake produces confident wrong output: phantom running sessions, or
   live sessions shown as dead.

## Outstanding before M2 depends on this

- Ground-truth comparison against the hook spike's live event stream (§4).
- A controlled check that `turn_duration` survives with no Stop hook configured (§3a). If that fails,
  `idle` drops to the same footing as `needsInput` and tailing really is only a hint.
