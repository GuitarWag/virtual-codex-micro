#!/usr/bin/env python3
"""Local hook receiver for the M0 hook spike.

Logs one JSONL line per received hook payload to events.jsonl:
  {"recv_ms": <epoch ms at receipt>, "sent_ms": <epoch ms from X-Sent-Ms header>, "payload": {...}}

Run:  python3 receiver.py [port]      (default 8787, 127.0.0.1 only)
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "events.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        recv_ms = time.time() * 1000
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"_unparsed": raw}
        rec = {
            "recv_ms": round(recv_ms, 1),
            "sent_ms": _f(self.headers.get("X-Sent-Ms")),
            "mark_ms": _f(self.headers.get("X-Mark-Ms")),
            "payload": payload,
        }
        with open(LOG, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        print(
            f"{time.strftime('%H:%M:%S')}.{int(recv_ms % 1000):03d} "
            f"{payload.get('hook_event_name', '?')} "
            f"{payload.get('notification_type', payload.get('tool_name', ''))}",
            flush=True,
        )
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"receiver on 127.0.0.1:{port} -> {LOG}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
