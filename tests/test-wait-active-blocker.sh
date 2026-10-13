#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-wait-active-blocker.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CONVERSATION_ID="90000000000000003"
AGENT_ID="m_wait_active"
PROFILE="$ROOT/Profile 7/.doubao/agent_mode/workspace/.sessions/$CONVERSATION_ID/agents/$AGENT_ID/system"
mkdir -p "$LOGROOT" "$PROFILE"
cat > "$PROFILE/assignment.md" <<'EOF'
# Assignment
- Agent ID: m_wait_active
- Role: main
- Assigned by: user
## [2026-10-12T00:00:00Z] 需求
等待期间 blocker 活跃测试
EOF
: > "$PROFILE/trajectory.jsonl"
LOG="$LOGROOT/saman_test.log"
: > "$LOG"

DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_INTERACTION_RESUME_GRACE_SECONDS=3 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2

# blocker 保持活跃，两个交互分别进入等待后再完成；不得在 blocker 活跃期间发完成。
printf '%s\n' "[1:1:0101/000000.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, priority=0, sequence=1, blocker_count=1" >> "$LOG"
printf '%s\n' '{"role":"assistant","content":"请选择","tool_calls":[{"id":"choose","type":"function","function":{"name":"interaction.ask","arguments":{}}}]}' >> "$PROFILE/trajectory.jsonl"
sleep 2
printf '%s\n' '{"role":"tool","content":"已选择","tool_call_id":"choose"}' >> "$PROFILE/trajectory.jsonl"
printf '%s\n' '{"role":"assistant","content":"请允许一次","tool_calls":[{"id":"allow","type":"function","function":{"name":"interaction.authorize_folder","arguments":{}}}]}' >> "$PROFILE/trajectory.jsonl"
sleep 2
printf '%s\n' '{"role":"tool","content":"已允许","tool_call_id":"allow"}' >> "$PROFILE/trajectory.jsonl"
sleep 3
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==2, d
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert sum('|reply_completed|' in x for x in ids)==0, ids
assert d.get('activeRunIDs',{}).get('90000000000000003'), d
assert not d.get('pendingInteractions',{}).get('90000000000000003',{}), d
PY

# 最终回复后 blocker 才结束，此时必须新增且只新增一次完成。
printf '%s\n' "[1:1:0101/000010.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__1:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==3, d
assert sum('|waiting_user|' in x for x in ids)==2, ids
assert sum('|reply_completed|' in x for x in ids)==1, ids
assert d.get('lastEventType')=='reply_completed', d
print(json.dumps({'active_blocker_during_wait':True,'waiting_events':2,'final_completion':1},ensure_ascii=False))
PY
