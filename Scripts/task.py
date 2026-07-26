#!/usr/bin/env python3
"""Minimal stand-in for the `tasks` CLI, which is not installed on this machine.

Reads and writes tasks.md in the same format the real CLI uses, so switching back
to it later is a no-op. Only implements what this project actually needs:
moving a task between sections and listing.

  ./Scripts/task.py list [section]
  ./Scripts/task.py move <id-suffix> <todo|in-progress|done|blocked>

ponytail: markdown surgery on a flat file, no index. Fine at 36 tasks; if the
board outgrows that, install the real CLI rather than growing this.
"""
import re
import sys
import pathlib

SECTIONS = {"todo": "## TODO", "in-progress": "## IN PROGRESS",
            "done": "## DONE", "blocked": "## BLOCKED"}
MARKERS = {"todo": "[ ]", "in-progress": "[>]", "done": "[x]", "blocked": "[!]"}
BOARD = pathlib.Path(__file__).resolve().parent.parent / "tasks.md"


def parse(text):
    """Return (preamble, {section_key: [task_block, ...]}) preserving order."""
    lines = text.split("\n")
    header_at = {}
    for i, line in enumerate(lines):
        for key, heading in SECTIONS.items():
            if line.strip() == heading:
                header_at[i] = key
    if not header_at:
        sys.exit("no section headings found in tasks.md")
    first = min(header_at)
    preamble = "\n".join(lines[:first]).rstrip("\n")

    bounds = sorted(header_at)
    sections = {}
    for n, start in enumerate(bounds):
        end = bounds[n + 1] if n + 1 < len(bounds) else len(lines)
        body = "\n".join(lines[start + 1:end]).strip("\n")
        blocks = [b.strip("\n") for b in re.split(r"\n\s*\n", body) if b.strip()]
        sections[header_at[start]] = blocks
    for key in SECTIONS:
        sections.setdefault(key, [])
    return preamble, sections


def render(preamble, sections):
    out = [preamble, ""]
    for key, heading in SECTIONS.items():
        out.append(heading)
        out.append("")
        for block in sections[key]:
            out.append(block)
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def find(sections, suffix):
    """Locate a task by ID suffix (e.g. '007'). Refuses ambiguous matches."""
    hits = [(key, i, b) for key, blocks in sections.items()
            for i, b in enumerate(blocks) if re.search(rf"\[T-[A-Z0-9]+-{suffix}\]", b)]
    if not hits:
        sys.exit(f"no task matching id suffix {suffix!r}")
    if len(hits) > 1:
        sys.exit(f"{suffix!r} matches {len(hits)} tasks — be more specific")
    return hits[0]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    preamble, sections = parse(BOARD.read_text())
    cmd = sys.argv[1]

    if cmd == "list":
        wanted = sys.argv[2:] or list(SECTIONS)
        for key in wanted:
            print(f"\n{SECTIONS[key]}  ({len(sections[key])})")
            for block in sections[key]:
                title = block.split("\n")[0]
                m = re.search(r"\[(T-[A-Z0-9-]+)\]\s+\*\*(.+?)\*\*", title)
                pri = re.search(r"priority:(\w+)", title)
                if m:
                    print(f"  {m.group(1)}  {pri.group(1) if pri else '?':8} {m.group(2)}")
        return

    if cmd == "move":
        if len(sys.argv) != 4 or sys.argv[3] not in SECTIONS:
            sys.exit("usage: task.py move <id-suffix> <todo|in-progress|done|blocked>")
        suffix, dest = sys.argv[2], sys.argv[3]
        src, idx, block = find(sections, suffix)
        if src == dest:
            print(f"already in {dest}")
            return
        block = re.sub(r"^- \[[ >x!]\]", f"- {MARKERS[dest]}", block, count=1)
        sections[src].pop(idx)
        sections[dest].append(block)
        BOARD.write_text(render(preamble, sections))
        print(f"{suffix}: {src} -> {dest}")
        return

    sys.exit(f"unknown command {cmd!r}")


if __name__ == "__main__":
    main()
