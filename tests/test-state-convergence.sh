#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-state-convergence.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"; PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"; STATE="$TMP/state.json"; LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000051"; AGENT="m_state_convergence"; TCID="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
SYSTEM="$ROOT/Profile 9/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
mkdir -p "$SYSTEM" "$LOGROOT"
printf '%s\n' '# Assignment' '- Agent ID: m_state_convergence' '- Role: main' > "$SYSTEM/assignment.md"
: > "$SYSTEM/trajectory.jsonl"; LOG="$LOGROOT/saman_test.log"; : > "$LOG"
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 & PID=$!
sleep 3

# Completion is state-driven with only a short cancellable merge window.
printf '%s\n' "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=fast:$CID, priority=0, sequence=80, blocker_count=1" >> "$LOG"
sleep 1
START=$(python3 -c 'import time; print(time.time())')
printf '%s\n' "[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=fast:$CID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 1.6
python3 - "$STATE" "$CID" "$START" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
completed=[(k,v) for k,v in d.get('processedEvents',{}).items() if k.startswith(cid+'|reply_completed|')]
assert len(completed)==1,d
assert d.get('version')==12,d
print(json.dumps({'fast_completion':True,'observed_within_seconds':1.6,'state_version':12}))
PY

# Seed the exact failure shape from v10, then restart. Migration must remove
# stale indexeddb waits and stale reconstructed runtime state.
/bin/kill -KILL "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
python3 - "$STATE" "$CID" "$TCID" <<'PY'
import json,sys
p,cid,tcid=sys.argv[1:]
d=json.load(open(p)); d['version']=10
d.setdefault('pendingInteractions',{})[cid]={tcid:'indexeddb.request_action'}
d.setdefault('activeRunIDs',{})[cid]='stale-run'
d.setdefault('activeInterceptors',{})[cid]={'stale':'stale-run'}
d.setdefault('permissionReviewToolIDs',{})[cid+'|'+tcid]=123
json.dump(d,open(p,'w'))
PY
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 & PID=$!
sleep 3
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert d.get('version')==12,d
assert not d.get('pendingInteractions',{}).get(cid),d
assert not d.get('permissionReviewToolIDs'),d
assert 'stale' not in d.get('activeInterceptors',{}).get(cid,{}),d
print(json.dumps({'v10_stale_indexeddb_removed':True,'stale_runtime_rebuilt':True}))
PY

# Generic tool settled must clear any same-ID redundant waiting record. Use an
# explicit live wait to establish state, then settle it under an ordinary tool name.
printf '%s\n' "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=generic:$CID, priority=0, sequence=81, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' "[lid={\"conversation_id\":\"$CID\",\"agent_id\":\"x\",\"sandbox_id\":\"sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"tcid\":\"seed\"}] mapping" >> "$LOG"
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"name\":\"interaction.ask\",\"sandbox_id\":\"sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"status\":\"received\",\"tcid\":\"$TCID\"}}\"" >> "$LOG"
sleep 1
printf '%s\n' "[exit_intercept] Unregister blocker. scope_id=local-task-conversation, intercept_id=generic:$CID, removed_count=1, blocker_count=0" >> "$LOG"
sleep 1
printf '%s\n' "[agent-task] \"{\"event\":\"toolcall\",\"data\":{\"phase\":\"execution_settled\",\"name\":\"Bash\",\"sandbox_id\":\"sandbox-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"tcid\":\"$TCID\",\"status\":\"success\"}}\"" >> "$LOG"
sleep 1.6
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert not d.get('pendingInteractions',{}).get(cid),d
assert sum(k.startswith(cid+'|reply_completed|') for k in d.get('processedEvents',{}))==2,d
print(json.dumps({'generic_settled_cleared_same_id_wait':True,'completion_after_settled':True}))
PY
