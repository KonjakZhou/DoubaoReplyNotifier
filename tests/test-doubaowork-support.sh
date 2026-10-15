#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-doubaowork-support.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/DoubaoWork"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000061"
AGENT="m_doubaowork"
SYSTEM="$ROOT/Default/.doubaowork/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
TITLE_DB="$ROOT/Default/IndexedDB/chrome_doubaowork-chat_0.indexeddb.leveldb"
mkdir -p "$SYSTEM" "$LOGROOT" "$TITLE_DB"
printf '%s\n' '# Assignment' '豆包工作 assignment 不包含旧版 Role 元数据' > "$SYSTEM/assignment.md"
: > "$SYSTEM/trajectory.jsonl"
LOG="$LOGROOT/saman_test.log"
: > "$LOG"
python3 - "$TITLE_DB/000005.ldb" "$CID" <<'PY'
import sys
from pathlib import Path
path=Path(sys.argv[1]); cid=sys.argv[2]
title='豆包工作适配测试'
payload=title.encode('utf-16le')
def varint(n):
    out=bytearray()
    while True:
        b=n & 0x7f; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)
path.write_bytes(b'conversation-list-data-overall-v2-c_id'+cid.encode()+b'-type-creator-name'+bytes([0x63])+varint(len(payload))+payload+b'-image_thumb-suffix')
PY
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" \
DOUBAO_NOTIFIER_WORKSPACE_DIR=".doubaowork" \
DOUBAO_NOTIFIER_TARGET_BUNDLE_ID="com.work.pc.doubao" \
DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" \
DOUBAO_NOTIFIER_STATE_FILE="$STATE" \
DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 \
DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 \
DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 \
"$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2
printf '%s\n' "[1:1:0101/000000.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__work__1:$CID, priority=0, sequence=1, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000001.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__work__1:$CID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 3
python3 - "$STATE" "$ROOT" "$CID" <<'PY'
import json,sys
state_path,root,cid=sys.argv[1:]
d=json.load(open(state_path))
trajectory=list(d.get('trajectoryOffsets',{}))
runtime=list(d.get('runtimeLogOffsets',{}))
assert any('/.doubaowork/agent_mode/workspace/.sessions/' in p for p in trajectory), trajectory
assert any('/DoubaoWork/sdk_storage/log/' in p or p.startswith(root+'/sdk_storage/log/') for p in runtime), runtime
assert d.get('conversationTitles',{}).get(cid)=='豆包工作适配测试', d
ids=list(d.get('processedEvents',{}))
assert sum('|reply_completed|' in x for x in ids)==1, ids
assert d.get('lastEventType')=='reply_completed', d
print(json.dumps({
  'doubaowork_workspace_discovered': True,
  'doubaowork_runtime_log_discovered': True,
  'doubaowork_indexeddb_title': d['conversationTitles'][cid],
  'completion_events': 1
}, ensure_ascii=False))
PY
