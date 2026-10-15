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
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 &
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
def s(text):
    p=text.encode('utf-16le'); return b'c'+varint(len(p))+p
value=b'\xff\x0fo'+s('schema')+s('conversation-list-data-overall-v2')+s('data')+b'o'+s('conversation_id')+s(cid)+s('name')+s(title)+b'{\x02{\x02'
batch=(1).to_bytes(8,'little')+(1).to_bytes(4,'little')+b'\x01\x01k'+varint(len(value))+value
path.with_suffix('.log').write_bytes(b'\x00'*4+len(batch).to_bytes(2,'little')+b'\x01'+batch)
PY
sleep 4

# 1. 极简回复：只有主进程 blocker 生命周期，没有 assistant trajectory。
printf '%s\n' "[1:1:0101/000000.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, priority=0, sequence=1, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000001.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5

# 2. 等待用户：unregister 后的短合并窗口内轨迹出现 interaction.ask，应取消完成并只产生 waiting。
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
assert 'waiting_user' not in d.get('terminalRuns',{}).values(), d
assert len(d.get('pendingInteractions',{}).get('90000000000000001',{}))==1, d
assert d.get('conversationTitle')=='真实对话标题', d
assert d.get('conversationTitles',{}).get('90000000000000001')=='真实对话标题', d
assert d.get('conversationTitle')!='后台原生信号测试', d
print(json.dumps({'processed_events':2,'simple_completion':1,'waiting':1,'premature_completion':0,'conversation_title':'真实对话标题'},ensure_ascii=False))
PY

# 用户完成第一个交互后，下一交互在短合并窗口内到来，不得提前完成。
printf '%s\n' '{"role":"tool","content":"用户已完成选择","tool_call_id":"b"}' >> "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl"
sleep 0.2
printf '%s\n' '{"role":"assistant","content":"请允许一次","tool_calls":[{"id":"c","type":"function","function":{"name":"interaction.authorize_folder","arguments":{}}}]}' >> "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl"
sleep 1
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==3, d
assert sum('|reply_completed|' in x for x in ids)==1, ids
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert len(d.get('pendingInteractions',{}).get('90000000000000001',{}))==1, d
PY

# 用户完成第二个交互后，本轮应恢复并发送最终完成；等待不是永久终态。
printf '%s\n' '{"role":"tool","content":"用户已授权文件夹权限","tool_call_id":"c"}' >> "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==4, d
assert sum('|reply_completed|' in x for x in ids)==2, ids
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert not d.get('pendingInteractions',{}).get('90000000000000001',{}), d
assert d.get('lastEventType')=='reply_completed', d
print(json.dumps({'two_interactions_resumed':True,'waiting_events':2,'final_completion':1,'processed_events':4},ensure_ascii=False))
PY

# 3. 同一轮多个 blocker 逆序结束，只能完成一次。
printf '%s\n' "[1:1:0101/000020.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__2:$CONVERSATION_ID, priority=0, sequence=3, blocker_count=1" >> "$LOG"
printf '%s\n' "[1:1:0101/000021.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__3:$CONVERSATION_ID, priority=0, sequence=4, blocker_count=2" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000022.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__2:$CONVERSATION_ID, removed_count=1, blocker_count=1" >> "$LOG"
sleep 4
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==4, d
PY
printf '%s\n' "[1:1:0101/000023.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__3:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==5, d
assert sum('|reply_completed|' in x for x in ids)==3, ids
print(json.dumps({'concurrent_blocker_completion':1,'processed_events':5},ensure_ascii=False))
PY

# 重放同一 unregister 不得重复。
printf '%s\n' "[1:1:0101/000012.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 4
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==5, d
PY

/bin/kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==5, d
print(json.dumps({'restart_replayed':False,'processed_events':5},ensure_ascii=False))
PY

# 页面导航/展示同步 blocker 不是 Agent 执行，必须完全忽略。
printf '%s\n' \
  '[1:1:0101/000030.000000:INFO:x] chat_page_navigate_event conversation_id=90000000000000001' \
  '[1:1:0101/000030.010000:INFO:x] presentation_sync_requested {"type":"chat-active"}' \
  "[1:1:0101/000030.020000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__sync__1:$CONVERSATION_ID, priority=0, sequence=30, blocker_count=1" \
  "[1:1:0101/000030.120000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__sync__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert len(d.get('processedEvents',{}))==5, d
assert not d.get('activeRunIDs',{}), d
PY

# 同一批 waiting call + tool result：先归并结果，不得发送等待。
printf '%s\n' "[1:1:0101/000040.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__batch:$CONVERSATION_ID, priority=0, sequence=40, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[1:1:0101/000041.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__batch:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
python3 - "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl" <<'PY'
from pathlib import Path
import sys
with Path(sys.argv[1]).open('a') as f:
    f.write('{"role":"assistant","content":"请选择","tool_calls":[{"id":"answered-in-batch","type":"function","function":{"name":"interaction.ask","arguments":{}}}]}\n')
    f.write('{"role":"tool","content":"已选择","tool_call_id":"answered-in-batch"}\n')
PY
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==6, d
assert sum('|reply_completed|' in x for x in ids)==4, ids
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert not d.get('pendingInteractions',{}).get('90000000000000001',{}), d
PY

# run 已完成后，迟到 trajectory 不能补发旧等待。
printf '%s\n' '{"role":"assistant","content":"迟到交互","tool_calls":[{"id":"late-after-terminal","type":"function","function":{"name":"interaction.ask","arguments":{}}}]}' >> "$PROFILE/$CONVERSATION_ID/agents/$AGENT_ID/system/trajectory.jsonl"
sleep 3
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==6, d
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert not d.get('pendingInteractions',{}).get('90000000000000001',{}), d
print(json.dumps({'page_sync_false_completion':0,'answered_same_batch_waiting':0,'late_waiting_after_terminal':0,'processed_events':6},ensure_ascii=False))
PY
