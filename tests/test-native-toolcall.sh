#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-native-toolcall.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"; PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"; STATE="$TMP/state.json"; LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000021"; AGENT="m_native_toolcall"; SANDBOX="sandbox-11111111-2222-3333-4444-555555555555"
SYSTEM="$ROOT/Profile 9/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
mkdir -p "$SYSTEM" "$LOGROOT"
printf '%s\n' '# Assignment' '- Agent ID: m_native_toolcall' '- Role: main' > "$SYSTEM/assignment.md"
: > "$SYSTEM/trajectory.jsonl"; : > "$LOGROOT/saman_test.log"
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_GRACE_SECONDS=1 DOUBAO_NOTIFIER_INTERACTION_RESUME_GRACE_SECONDS=1 "$BIN" >/dev/null 2>&1 & PID=$!
sleep 4
LOG="$LOGROOT/saman_test.log"
printf '%s\n' "[lid={\"conversation_id\":\"$CID\",\"agent_id\":\"x\",\"sandbox_id\":\"$SANDBOX\",\"tcid\":\"seed\"}] mapping" >> "$LOG"

TOOLS=("interaction.ask" "interaction.authorize_folder" "interaction.request_action")
for INDEX in 0 1 2; do
  TOOL="${TOOLS[$INDEX]}"; SEQ=$((INDEX+50)); TCID="00000000-0000-4000-8000-0000000000$((INDEX+10))"
  printf '%s\n' "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=native_$INDEX:$CID, priority=0, sequence=$SEQ, blocker_count=1" >> "$LOG"
  sleep 1
  printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"agent_id\":\"x\",\"name\":\"$TOOL\",\"sandbox_id\":\"$SANDBOX\",\"seq\":$SEQ,\"status\":\"received\",\"tcid\":\"$TCID\"}}\"" >> "$LOG"
  sleep 1
  printf '%s\n' "[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=native_$INDEX:$CID, removed_count=1, blocker_count=0" >> "$LOG"
  sleep 2
  python3 - "$STATE" "$CID" "$TCID" "$((INDEX+1))" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; tcid=sys.argv[3]; expected=int(sys.argv[4])
assert d.get('pendingInteractions',{}).get(cid,{}).get(tcid), d
assert sum('|waiting_user|' in x for x in d.get('processedEvents',{}))==expected, d
assert sum('|reply_completed|' in x for x in d.get('processedEvents',{}))==expected-1, d
PY
  printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"phase\":\"execution_settled\",\"name\":\"$TOOL\",\"sandbox_id\":\"$SANDBOX\",\"tcid\":\"$TCID\",\"status\":\"success\"}}\"" >> "$LOG"
  sleep 3
  python3 - "$STATE" "$CID" "$((INDEX+1))" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; expected=int(sys.argv[3])
assert not d.get('pendingInteractions',{}).get(cid,{}), d
assert sum('|reply_completed|' in x for x in d.get('processedEvents',{}))==expected, d
PY
done
python3 - "$STATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));
print(json.dumps({'native_received_waiting':3,'native_settled_resolved':3,'background_conversation_mapped':True,'waiting':sum('|waiting_user|' in x for x in d['processedEvents']),'completed':sum('|reply_completed|' in x for x in d['processedEvents'])},ensure_ascii=False))
PY
