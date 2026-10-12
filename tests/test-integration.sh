#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-integration.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
PROFILE_ROOT="$ROOT/Profile 7"
PROFILE="$PROFILE_ROOT/.doubao/agent_mode/workspace/.sessions"
TITLE_DB="$PROFILE_ROOT/IndexedDB/chrome_doubao-chat_0.indexeddb.leveldb"
mkdir -p "$LOGROOT" "$PROFILE/history/agents/m_history/system" "$TITLE_DB"
LOG="$LOGROOT/saman_test.log"
: > "$LOG"
cat > "$PROFILE/history/agents/m_history/system/assignment.md" <<'EOF'
# Assignment
- Agent ID: m_history
- Role: main
- Assigned by: user
## [2026-10-12T00:00:00Z] 需求
历史任务
EOF
printf '%s\n' '{"role":"user","content":"历史问题"}' '{"role":"assistant","content":"历史答案"}' > "$PROFILE/history/agents/m_history/system/trajectory.jsonl"
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2
python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
assert len(d.get('processedEvents',{}))==0, d
assert len(d.get('trajectoryOffsets',{}))==1, d
assert len(d.get('runtimeLogOffsets',{}))==1, d
PY

CONVERSATION_ID="90000000000000001"
AGENT_ID="m_background"
mkdir -p "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system"
cat > "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/assignment.md" <<'EOF'
# Assignment
- Agent ID: m_background
- Role: main
- Assigned by: user
## [2026-10-12T00:00:00Z] 需求
后台原生信号测试
EOF
: > "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl"
python3 - "$TITLE_DB/000005.ldb" "$CONVERSATION_ID" <<'PY'
import sys
from pathlib import Path
path=Path(sys.argv[1]); cid=sys.argv[2]
title='真实对话标题'
payload=title.encode('utf-16le')
def varint(n):
    out=bytearray()
    while True:
        b=n & 0x7f; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)
record=(b'conversation-list-data-overall-v2-c_id'+cid.encode()+
        b'-type-creator-name'+bytes([0x63])+varint(len(payload))+payload+
        b'-image_thumb-suffix')
path.write_bytes(record)
PY
sleep 4

# 1. 极简回复：只有主进程 blocker 生命周期，没有 assistant trajectory。
printf '%s\n' "[1:1:0101/000000.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, priority=0, sequence=1, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000001.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5

# 2. 等待用户：unregister 后的 grace 窗口内轨迹出现 interaction.ask，应只产生 waiting。
printf '%s\n' "[1:1:0101/000010.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, priority=0, sequence=2, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000011.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
cat >> "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl" <<'EOF'
{"role":"assistant","content":"普通文本提到等待你确认，但仍继续处理","tool_calls":[{"id":"a","type":"function","function":{"name":"Read","arguments":{}}}]}
{"role":"tool","content":"ok","tool_call_id":"a"}
{"role":"assistant","content":"请确认","tool_calls":[{"id":"b","type":"function","function":{"name":"interaction.ask","arguments":{}}}]}
EOF
sleep 5

python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); ids=list(d.get('processedEvents',{}))
assert len(ids)==2, d
assert sum('|reply_completed|' in x for x in ids)==1, ids
assert sum('|waiting_user|' in x for x in ids)==1, ids
assert all('history|' not in x for x in ids), ids
assert 'waiting_user' in d.get('terminalRuns',{}).values(), d
assert d.get('conversationTitle')=='真实对话标题', d
assert d.get('conversationTitles',{}).get('90000000000000001')=='真实对话标题', d
assert d.get('conversationTitle')!='后台原生信号测试', d
print(json.dumps({'processed_events':2,'simple_completion':1,'waiting':1,'false_text_waiting':0,'conversation_title':'真实对话标题'},ensure_ascii=False))
PY

# 3. 同一轮多个 blocker 逆序结束，只能完成一次。
printf '%s\n' "[1:1:0101/000020.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__2:$CONVERSATION_ID, priority=0, sequence=3, blocker_count=1" >> "$LOG"
printf '%s\n' "[1:1:0101/000021.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__3:$CONVERSATION_ID, priority=0, sequence=4, blocker_count=2" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000022.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__2:$CONVERSATION_ID, removed_count=1, blocker_count=1" >> "$LOG"
sleep 4
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==2, d
PY
printf '%s\n' "[1:1:0101/000023.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__3:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==3, d
assert sum('|reply_completed|' in x for x in ids)==2, ids
print(json.dumps({'concurrent_blocker_completion':1,'processed_events':3},ensure_ascii=False))
PY

# 重放同一 unregister 不得重复。
printf '%s\n' "[1:1:0101/000012.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 4
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==3, d
PY

/bin/kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==3, d
print(json.dumps({'restart_replayed':False,'processed_events':3},ensure_ascii=False))
PY
