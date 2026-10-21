#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-unmapped-native.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"
PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"
STATE="$TMP/state.json"
LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000031"
AGENT="m_unmapped_native"
SANDBOX="sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
TCID="11111111-2222-4333-8444-555555555555"
SYSTEM="$ROOT/Profile 9/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
mkdir -p "$SYSTEM" "$LOGROOT"
printf '%s\n' '# Assignment' '- Agent ID: m_unmapped_native' '- Role: main' > "$SYSTEM/assignment.md"
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

# 真实 run 已开始，但新 sandbox 没有 conversation 映射。
printf '%s\n' "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=unmapped_1:$CID, priority=0, sequence=71, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"agent_id\":\"x\",\"name\":\"interaction.ask\",\"sandbox_id\":\"$SANDBOX\",\"seq\":72,\"status\":\"received\",\"tcid\":\"$TCID\"}}\"" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" "$TCID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; tcid=sys.argv[3]
assert d['version']==14, d
assert d.get('pendingInteractions',{}).get(cid,{}).get(tcid)=='interaction.ask', d
assert sum('|waiting_user|' in key for key in d.get('processedEvents',{}))==1, d
pending=d.get('resolverState',{}).get('pendingNativeInteractions',{}).get(tcid)
assert pending and pending.get('provisionalConversationID')==cid, d
PY

# blocker 注销时仍有 interaction，绝不能误报完成。
printf '%s\n' "[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=unmapped_1:$CID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 3
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert sum('|reply_completed|' in key for key in d.get('processedEvents',{}))==0, d
PY

# 即使映射始终缺失，settled 也必须解除临时归属并恢复完成。
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"phase\":\"execution_settled\",\"name\":\"interaction.ask\",\"sandbox_id\":\"$SANDBOX\",\"tcid\":\"$TCID\",\"status\":\"success\"}}\"" >> "$LOG"
sleep 3
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert not d.get('pendingInteractions',{}).get(cid,{}), d
assert sum('|waiting_user|' in key for key in d.get('processedEvents',{}))==1, d
assert sum('|reply_completed|' in key for key in d.get('processedEvents',{}))==1, d
print(json.dumps({
  'unmapped_native_waiting': True,
  'completion_blocked_while_waiting': True,
  'settled_without_mapping_resolved': True,
  'state_version': d['version']
}, ensure_ascii=False))
PY
