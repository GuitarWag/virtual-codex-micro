#!/bin/bash
# Regression guard for composition bugs.
#
# Exists because of a specific miss: DirectionPadView positioned its cells with
# `.offset`, which does not participate in layout, so the pad rendered one cell
# diagonally off and collided with the command cluster. Every per-component check
# passed — its own hit-testing maths was correct — because no component owns
# composition. Only looking at the assembled panel caught it.
#
# Compares a fresh render against the committed reference PNGs.
#
#   ./Scripts/check-render.sh          # verify
#   ./Scripts/check-render.sh --update # accept current output as the new reference
#
# CAVEAT: pixel comparison is machine-sensitive. Font rendering and material
# resolution vary with OS version and display scale, so a mismatch on a different
# machine is not necessarily a regression. Treat this as a local guard, and look
# at the PNG rather than trusting the exit code blindly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$ROOT/docs/renders"
BIN="$ROOT/.build/debug/VirtualCodexMicro"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$BIN" ] || { echo "missing $BIN — run: swift build" >&2; exit 1; }
VCM_RENDER="$TMP/panel" "$BIN" >/dev/null

status=0
for variant in light dark; do
    new="$TMP/panel-$variant.png"
    ref="$REF/panel-$variant.png"
    [ -f "$new" ] || { echo "render produced no $variant output" >&2; exit 1; }

    if [ "${1:-}" = "--update" ]; then
        cp "$new" "$ref"
        echo "updated reference: panel-$variant.png"
        continue
    fi

    if [ ! -f "$ref" ]; then
        echo "no reference for $variant — run with --update to create one" >&2
        status=1
    elif [ "$(shasum -a 256 <"$new" | cut -d' ' -f1)" = "$(shasum -a 256 <"$ref" | cut -d' ' -f1)" ]; then
        echo "$variant: matches reference"
    else
        cp "$new" "$ROOT/.build/panel-$variant-actual.png"
        echo "$variant: DIFFERS from reference" >&2
        echo "  actual saved to .build/panel-$variant-actual.png — open both and compare" >&2
        status=1
    fi
done
exit $status
