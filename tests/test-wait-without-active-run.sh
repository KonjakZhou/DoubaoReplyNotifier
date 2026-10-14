#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-wait-without-active-run.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000041"
AGENT="m_wait_without_run"
SANDBOX="sandbox-41414141-4141-4141-8141-414141414141"
TCID="41414141-4242-4343-8444-454545454545"
SYSTEM="$ROOT/Profile 9/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
mkdir -p "$SYSTEM" "$LOGROOT"
printf '%s\n' '# Assignment' '- Agent ID: m_wait_without_run' '- Role: main' > "$SYSTEM/assignment.md"
: > "$SYSTEM/trajectory.jsonl"
LOG="$LOGROOT/saman_test.log"
: > "$LOG"

DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" \
DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" \
DOUBAO_NOTIFIER_STATE_FILE="$STATE" \
DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 \
DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 \
DOUBAO_NOTIFIER_COMPLETION_GRACE_SECONDS=1 \
DOUBAO_NOTIFIER_INTERACTION_RESUME_GRACE_SECONDS=1 \
"$BIN" >/dev/null 2>&1 &
PID=$!
sleep 3

# 页面切换产生的短暂边界应被忽略，不能成为真实任务轮次。
printf '%s\n' \
  "chat_page_navigate_event conversation=$CID" \
  "presentation_sync_requested conversation=$CID" \
  "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=page_sync:$CID, priority=0, sequence=8, blocker_count=1" \
  "presentation_sync_finished conversation=$CID" \
  "[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=page_sync:$CID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert not d.get('activeRunIDs',{}).get(cid), d
assert not [k for k in d.get('processedEvents',{}) if cid in k], d
PY

# sandbox 已明确归属，但此时没有活跃任务轮次；有效等待仍必须通知。
printf '%s\n' "[lid={\"conversation_id\":\"$CID\",\"agent_id\":\"x\",\"sandbox_id\":\"$SANDBOX\",\"tcid\":\"seed\"}] mapping" >> "$LOG"
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"agent_id\":\"x\",\"name\":\"interaction.ask\",\"sandbox_id\":\"$SANDBOX\",\"seq\":86,\"status\":\"received\",\"tcid\":\"$TCID\"}}\"" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" "$TCID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; tcid=sys.argv[3]
assert d.get('pendingInteractions',{}).get(cid,{}).get(tcid)=='interaction.ask', d
assert d.get('activeRunIDs',{}).get(cid), d
assert sum(cid in k and '|waiting_user|' in k for k in d.get('processedEvents',{}))==1, d
assert sum(cid in k and '|reply_completed|' in k for k in d.get('processedEvents',{}))==0, d
PY

# 相同 received 重复到达不得重复提醒。
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"agent_id\":\"x\",\"name\":\"interaction.ask\",\"sandbox_id\":\"$SANDBOX\",\"seq\":87,\"status\":\"received\",\"tcid\":\"$TCID\"}}\"" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert sum(cid in k and '|waiting_user|' in k for k in d.get('processedEvents',{}))==1, d
PY

# 请求结束后解除等待并完成一次。
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"phase\":\"execution_settled\",\"name\":\"interaction.ask\",\"sandbox_id\":\"$SANDBOX\",\"tcid\":\"$TCID\",\"status\":\"error\"}}\"" >> "$LOG"
sleep 3
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert not d.get('pendingInteractions',{}).get(cid,{}), d
assert sum(cid in k and '|waiting_user|' in k for k in d.get('processedEvents',{}))==1, d
assert sum(cid in k and '|reply_completed|' in k for k in d.get('processedEvents',{}))==1, d
print(json.dumps({
  'page_sync_ignored': True,
  'waiting_without_active_run': True,
  'duplicate_waiting_suppressed': True,
  'settled_completion': 1
}, ensure_ascii=False))
PY
