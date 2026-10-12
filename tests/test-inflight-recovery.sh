#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-inflight-recovery.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CONVERSATION_ID="90000000000000002"
AGENT_ID="m_inflight"
PROFILE="$ROOT/Profile 7/.doubao/agent_mode/workspace/.sessions/$CONVERSATION_ID/agents/$AGENT_ID/system"
mkdir -p "$LOGROOT" "$PROFILE"
cat > "$PROFILE/assignment.md" <<'EOF'
# Assignment
- Agent ID: m_inflight
- Role: main
- Assigned by: user
## [2026-10-12T00:00:00Z] 需求
运行中安装恢复测试
EOF
: > "$PROFILE/trajectory.jsonl"
LOG="$LOGROOT/saman_test.log"
printf '%s\n' "[1:1:0101/000000.000000:INFO:x] [exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=7__rfh__9:$CONVERSATION_ID, priority=0, sequence=9, blocker_count=1" > "$LOG"

DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 2
python3 - "$STATE" "$CONVERSATION_ID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert len(d.get('processedEvents',{}))==0, d
assert cid in d.get('activeRunIDs',{}), d
assert len(d.get('activeInterceptors',{}).get(cid,{}))==1, d
PY

printf '%s\n' "[1:1:0101/000001.000000:INFO:x] [exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=7__rfh__9:$CONVERSATION_ID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 5
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ids=list(d.get('processedEvents',{}))
assert len(ids)==1, d
assert '|reply_completed|' in ids[0], ids
print(json.dumps({'inflight_recovered':True,'history_replayed':False,'processed_events':1},ensure_ascii=False))
PY
