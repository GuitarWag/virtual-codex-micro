#!/bin/bash
# Build, then run every check. Fails fast.
#
# Exists because running the self-check after a failed build silently exercises a
# STALE binary and prints "ok" — which happened twice during development and both
# times produced a false pass. `swift build` leaves the previous binary in place
# on failure, so the only safe order is build-or-die, then check.
#
#   ./Scripts/verify.sh              # build + self-check + render comparison
#   ./Scripts/verify.sh --no-render  # skip the render comparison
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> building"
if ! swift build 2>&1 | tee /tmp/vcm-build.log | grep -qv .; then :; fi
if grep -qE "^.*error:" /tmp/vcm-build.log; then
    echo "BUILD FAILED — not running checks against a stale binary:" >&2
    grep -E "error:" /tmp/vcm-build.log | sort -u | head -20 >&2
    exit 1
fi
echo "    build ok"

echo "==> self-check"
# VCM_PIXELCHECK adds the rendered-pixel colour pass: it renders a real agent cap
# per state and measures glyph contrast and lit-pair separation off the bitmap,
# which is the only way to see a regression caused by a layer drawn over the fill.
# It is opt-in because it needs an NSWindow and depends on the rasteriser, so the
# bare `VCM_SELFTEST=1` run stays pure — but it belongs here, because otherwise
# nothing in CI ever measures what the user actually sees. See PixelCheck.swift.
VCM_SELFTEST=1 VCM_PIXELCHECK=1 ./.build/debug/VirtualCodexMicro

if [ "${1:-}" != "--no-render" ]; then
    echo "==> render comparison"
    ./Scripts/check-render.sh
fi

echo "==> all checks passed"
