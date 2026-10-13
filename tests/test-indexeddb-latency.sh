#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-indexeddb-latency.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000011"
AGENT="m_indexeddb"
PROFILE_ROOT="$ROOT/Profile 7"
SYSTEM="$PROFILE_ROOT/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
DB="$PROFILE_ROOT/IndexedDB/chrome_doubao-chat_0.indexeddb.leveldb"
WAL="$(python3 - "$DB/000007.log" <<'PY'
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
)"
TRAJECTORY="$SYSTEM/trajectory.jsonl"
mkdir -p "$SYSTEM" "$DB" "$LOGROOT"
: > "$LOGROOT/saman_test.log"
: > "$TRAJECTORY"
printf 'historical-wal-bytes' > "$WAL"
cat > "$SYSTEM/assignment.md" <<EOF
# Assignment
- Agent ID: $AGENT
- Role: main
- Assigned by: user
## 需求
IndexedDB 即时等待测试
EOF

DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" \
DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" \
DOUBAO_NOTIFIER_STATE_FILE="$STATE" \
DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 \
DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 \
"$BIN" >"$TMP/notifier.log" 2>&1 &
PID=$!

for _ in {1..30}; do
  [[ -f "$STATE" ]] && break
  if ! /bin/kill -0 "$PID" 2>/dev/null; then
    /bin/cat "$TMP/notifier.log" >&2
    exit 1
  fi
  sleep 0.1
done
sleep 1
python3 - "$STATE" "$WAL" <<'PY'
import json,sys,os
state=json.load(open(sys.argv[1]))
assert state.get('version') == 7, state
assert state.get('indexedDBOffsets',{}).get(sys.argv[2]) == os.path.getsize(sys.argv[2]), state
assert not state.get('processedEvents'), state
PY

INTERACTION="12345678-1234-1234-1234-123456789abc"
START_NS="$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)"
python3 - "$WAL" "$AGENT" "$INTERACTION" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); agent=sys.argv[2]; interaction=sys.argv[3]
record=(b'\x00'*64 + b'dbx_ic:' + b'B'*40 + interaction.encode() +
        b'"questions:required:capability:allow:' + b'C'*700 +
        f'/agents/{agent}/system/'.encode() + b'D'*100)
with p.open('ab') as f:
    f.write(record)
PY

DETECTED=0
for _ in {1..40}; do
  if python3 - "$STATE" "$CID" "$INTERACTION" 2>/dev/null <<'PY'
import hashlib,json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(1)
eid=f"{sys.argv[2]}|waiting_user|{hashlib.sha256(sys.argv[3].encode()).hexdigest()}"
assert eid in d.get('processedEvents',{})
assert sys.argv[3] in d.get('pendingInteractions',{}).get(sys.argv[2],{})
assert d.get('lastEventSource') == 'indexeddb:interaction'
PY
  then DETECTED=1; break; fi
  sleep 0.1
done
[[ "$DETECTED" == 1 ]]
END_NS="$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)"
LATENCY_MS="$(( (END_NS - START_NS) / 1000000 ))"
[[ "$LATENCY_MS" -lt 2000 ]]

# trajectory arrives later: it must enrich the pending type without a second notification.
printf '%s\n' "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"$INTERACTION\",\"type\":\"function\",\"function\":{\"name\":\"interaction.ask\",\"arguments\":{}}}]}" >> "$TRAJECTORY"
sleep 2
python3 - "$STATE" "$CID" "$INTERACTION" "$LATENCY_MS" <<'PY'
import hashlib,json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; iid=sys.argv[3]
eid=f"{cid}|waiting_user|{hashlib.sha256(iid.encode()).hexdigest()}"
waiting=[x for x in d.get('processedEvents',{}) if '|waiting_user|' in x]
assert waiting == [eid], (waiting,d)
assert d['pendingInteractions'][cid][iid] == 'interaction.ask', d
print(json.dumps({
  'indexeddb_waiting_detected': True,
  'latency_ms': int(sys.argv[4]),
  'trajectory_delayed': True,
  'cross_source_duplicates': 0,
  'historical_wal_replayed': False
}, ensure_ascii=False))
PY

printf '%s\n' "{\"role\":\"tool\",\"content\":\"done\",\"tool_call_id\":\"$INTERACTION\"}" >> "$TRAJECTORY"
sleep 2
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert not d.get('pendingInteractions',{}).get(sys.argv[2]), d
PY
