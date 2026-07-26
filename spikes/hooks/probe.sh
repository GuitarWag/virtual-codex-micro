#!/bin/bash
# Reports only the identity fields we care about. No env dump, no secrets.
cat >/dev/null
python3 -c '
import json,os,urllib.request
pid=os.environ.get("CLAUDE_PID")
d={"hook_event_name":"PROBE2",
   "CLAUDE_PID":pid,
   "CLAUDE_CODE_SESSION_ID":os.environ.get("CLAUDE_CODE_SESSION_ID"),
   "CLAUDE_PROJECT_DIR":os.environ.get("CLAUDE_PROJECT_DIR"),
   "CLAUDE_CODE_ENTRYPOINT":os.environ.get("CLAUDE_CODE_ENTRYPOINT"),
   "ps_of_claude_pid":os.popen("ps -o pid=,tty=,command= -p %s"%pid).read().strip()[:160] if pid else None}
r=urllib.request.Request("http://127.0.0.1:8787/hook",data=json.dumps(d).encode(),headers={"Content-Type":"application/json"})
try: urllib.request.urlopen(r,timeout=3).read()
except Exception: pass
'
exit 0
