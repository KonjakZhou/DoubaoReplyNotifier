#!/bin/bash
set -euo pipefail
BIN="${1:?usage: test-permission-review.sh /path/to/DoubaoReplyNotifier}"
TMP="$(mktemp -d)"; PID=""
trap 'if [[ -n "${PID:-}" ]]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi; /bin/rm -rf "$TMP"' EXIT
ROOT="$TMP/Doubao"; STATE="$TMP/state.json"; LOGROOT="$ROOT/sdk_storage/log"
CID="90000000000000031"; AGENT="m_permission_review"
SYSTEM="$ROOT/Profile 9/.doubao/agent_mode/workspace/.sessions/$CID/agents/$AGENT/system"
mkdir -p "$SYSTEM" "$LOGROOT"
printf '%s\n' '# Assignment' '- Agent ID: m_permission_review' '- Role: main' > "$SYSTEM/assignment.md"
: > "$SYSTEM/trajectory.jsonl"; LOG="$LOGROOT/saman_test.log"; : > "$LOG"
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 & PID=$!
sleep 4
printf '%s\n' "[exit_intercept] Register added blocker. scope_id=local-task-conversation, intercept_id=review:$CID, priority=0, sequence=70, blocker_count=1" >> "$LOG"
sleep 1
printf '%s\n' \
  "DidStartNavigation chat_page_navigate_event: stage=navigation_start, url: https://example/agent-confirm_09_10_1.html?requestId=common-ask-human-action-button-1792000000000-reject\\u0026text=reject, last_committed_url: doubao://doubao-chat/chat/$CID, IsSameDocument: 0" \
  "DidStartNavigation chat_page_navigate_event: stage=navigation_start, url: https://example/agent-confirm_09_10_1.html?requestId=common-ask-human-action-button-1792000000000-allow\\u0026text=allow, last_committed_url: doubao://doubao-chat/chat/$CID, IsSameDocument: 0" \
  >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
p=d.get('pendingInteractions',{}).get(cid,{})
assert p == {'permission-review-1792000000000':'permission_review.authorize'}, d
assert sum('|waiting_user|' in x for x in d.get('processedEvents',{})) == 1, d
assert d.get('version') == 14, d
PY
# Restart while the review is still pending. The persisted wait must survive,
# but historical runtime lines must not emit a duplicate notification.
/bin/kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
DOUBAO_NOTIFIER_DATA_ROOT="$ROOT" DOUBAO_NOTIFIER_LOG_ROOT="$LOGROOT" DOUBAO_NOTIFIER_STATE_FILE="$STATE" DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS=1 DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM=1 DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS=0.5 "$BIN" >/dev/null 2>&1 & PID=$!
sleep 3
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert d.get('pendingInteractions',{}).get(cid,{}) == {'permission-review-1792000000000':'permission_review.authorize'}, d
assert sum('|waiting_user|' in x for x in d.get('processedEvents',{})) == 1, d
PY
TCID="99999999-1111-4222-8333-444444444444"
printf '%s\n' "[lid={\"conversation_id\":\"$CID\",\"agent_id\":\"x\",\"sandbox_id\":\"sandbox-x\",\"tcid\":\"$TCID\"}] [sandbox] operator() bash.run enter request_id=x" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" "$TCID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]; tcid=sys.argv[3]
assert not d.get('pendingInteractions',{}).get(cid,{}), d
assert d.get('permissionReviewToolIDs',{}).get(cid+'|'+tcid), d
assert sum('|waiting_user|' in x for x in d.get('processedEvents',{})) == 1, d
PY
# A redraw of the already processed review and a late authorize-like follow-up
# must never generate a second notification.
printf '%s\n' "DidStartNavigation chat_page_navigate_event: stage=navigation_start, url: https://example/agent-confirm_09_10_1.html?requestId=common-ask-human-action-button-1792000000000-redraw\\u0026text=allow, last_committed_url: doubao://doubao-chat/chat/$CID, IsSameDocument: 0" >> "$LOG"
sleep 2
python3 - "$STATE" "$CID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cid=sys.argv[2]
assert not d.get('pendingInteractions',{}).get(cid,{}), d
assert sum('|waiting_user|' in x for x in d.get('processedEvents',{})) == 1, d
print(json.dumps({'permission_review_waiting':1,'paired_button_duplicate':0,'restart_duplicate':0,'tool_started_resolved':True,'redraw_duplicate':0,'state_version':14},ensure_ascii=False))
PY
