#!/bin/bash
# Hook command: read the payload on stdin, POST it to the local receiver.
# Stamps X-Sent-Ms so the receiver can measure hook->receiver transport cost
# separately from transition->hook cost.
# Always exits 0 and prints nothing, so it never blocks or perturbs the session.
payload=$(cat)
sent=$(python3 -c 'import time;print(int(time.time()*1000))')
curl -s -m 5 -o /dev/null \
  -X POST "http://127.0.0.1:${VCM_HOOK_PORT:-8787}/" \
  -H 'Content-Type: application/json' \
  -H "X-Sent-Ms: $sent" \
  --data-binary "$payload" || true
exit 0
