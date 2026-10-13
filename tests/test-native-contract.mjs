import fs from 'node:fs';

const source = fs.readFileSync(new URL('../Sources/main.swift', import.meta.url), 'utf8');
const titleSource = fs.readFileSync(new URL('../Sources/ConversationTitleReader.swift', import.meta.url), 'utf8');
const interactionSource = fs.readFileSync(new URL('../Sources/IndexedDBInteractionReader.swift', import.meta.url), 'utf8');
const combinedSource = `${source}\n${titleSource}\n${interactionSource}`;
const mustContain = [
  ['runtime blocker register', /Register added blocker\\\. scope_id=local-task-conversation/],
  ['runtime blocker unregister', /Unregister blocker\\\. scope_id=local-task-conversation/],
  ['runtime log discovery', /saman_/],
  ['trajectory watcher', /trajectory\.jsonl/],
  ['main-agent filter', /assignment\.contains\("- Role: main"\)/],
  ['multi-profile discovery', /name == "Default" \|\| name\.hasPrefix\("Profile "\)/],
  ['runtime offsets', /runtimeLogOffsets:\s*\[String:\s*UInt64\]/],
  ['trajectory offsets', /trajectoryOffsets:\s*\[String:\s*UInt64\]/],
  ['indexeddb WAL offsets', /indexedDBOffsets:\s*\[String:\s*UInt64\]/],
  ['indexeddb interaction reader', /IndexedDBInteractionReader/],
  ['indexeddb structured interaction signature', /schema_payload/],
  ['indexeddb tool-call structure', /tool_call/],
  ['indexeddb full WAL write batch parser', /logicalRecords\(inWAL:/],
  ['indexeddb structured conversation id', /local_conversation_id/],
  ['indexeddb cross-source registration', /source: "indexeddb:\\?\(event\.kind\)"/],
  ['indexeddb known interaction baseline', /indexedDBKnownInteractions/],
  ['explicit interaction signal', /interaction\.ask/],
  ['trajectory batch call collection', /var calls: \[\(id: String, tool: String, source: String\)\]/],
  ['trajectory batch result collection', /var results = Set<String>\(\)/],
  ['trajectory results before waiting registration', /for interactionID in results/],
  ['page sync blocker filter', /PAGE_SYNC_BLOCKER_IGNORED/],
  ['native toolcall received signal', /nativeWaitingReceivedRegex/],
  ['native toolcall settled signal', /nativeWaitingSettledRegex/],
  ['sandbox conversation mapping', /sandboxConversations/],
  ['late waiting suppression', /STALE_WAITING_IGNORED/],
  ['completion grace window', /completionGraceSeconds/],
  ['persistent event ledger', /processedEvents:\s*\[String:\s*String\]/],
  ['concurrent blocker ledger', /activeInterceptors:\s*\[String:\s*\[String:\s*String\]\]/],
  ['recoverable interaction ledger', /pendingInteractions:\s*\[String:\s*\[String:\s*String\]\]/],
  ['interaction result correlation', /record\.tool_call_id/],
  ['waiting does not terminate run', /emitWaiting\(/],
  ['event replay guard', /processedEvents\[eventID\]\s*==\s*nil/],
  ['stable request identifier', /UNNotificationRequest\(identifier:\s*identifier/],
  ['notification rollback', /processedEvents\.removeValue\(forKey:\s*eventID\)/],
  ['conversation title database', /chrome_doubao-chat_0\.indexeddb\.leveldb/],
  ['conversation list title source', /conversation-list-data-/],
  ['UTF-16 title decoding', /utf16LittleEndian/],
  ['notification uses refreshed title', /conversationTitleReader\.title\(conversationID:/],
  // 点击通知激活豆包主应用。
  ['didReceive delegate implemented', /func userNotificationCenter\(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse/],
  ['controlled action marker written', /content\.userInfo = \[Self\.actionMarkerKey: Self\.actionMarkerValue\]/],
  ['reply category registered', /setNotificationCategories/],
  ['explicit activate action button', /UNNotificationAction\(/],
  ['default click handled', /UNNotificationDefaultActionIdentifier/],
  ['dismiss action ignored', /UNNotificationDismissActionIdentifier/],
  ['unknown action ignored', /RESPONSE_IGNORED reason=unknown_action/],
  ['target main bundle id constant', /targetBundleID = "com\.bot\.pc\.doubao"/],
  ['unconditional first-line response log', /NOTIFICATION_RESPONSE_RECEIVED id=%@ action=%@/],
  ['accepted branch logged', /RESPONSE_ACCEPTED reason=activate/],
  ['ignored branch logged', /RESPONSE_IGNORED reason=not_controlled/],
  ['robust marker bridging helper', /static func robustMarkerMatches\(_ value: Any\?\)/],
  ['category-controlled fallback', /categoryMatches = \(categoryIdentifier == Self\.replyCategoryIdentifier\)/],
  ['marker or category gate', /guard markerMatches \|\| categoryMatches/],
  ['locate by bundle id', /urlForApplication\(withBundleIdentifier: Self\.targetBundleID\)/],
  ['best-effort ignoring-other-apps', /running\.activate\(options: \[\.activateIgnoringOtherApps\]\)/],
  ['activate existing logged', /NSLog\("ACTIVATE_EXISTING pid=%d bundleID=%@"/],
  ['openApplication fallback activation', /openApplication\(at: appURL, configuration: config\)/],
  ['launch succeeded logged', /NSLog\("LAUNCH_SUCCEEDED bundleID=%@/],
  ['launch failed logged', /NSLog\("LAUNCH_FAILED bundleID=%@/],
  ['resolved bundle verified', /resolvedID == Self\.targetBundleID/],
  ['browser helper suffix refused', /hasSuffix\("\.browser"\)/],
  ['structured activation error log', /recordActivationError\(\s*stage:/]
];
const mustNotContain = [
  ['waiting marked as permanent terminal', /terminalRuns\[runID\]\s*=\s*"waiting_user"/],
  ['waiting clears active run', /activeRunIDs\.removeValue\(forKey:\s*watch\.conversationID\)/],
  ['assignment text title inference', /titleFromAssignment|prefix\(28\)/],
  ['assistant text completion inference', /record\.tool_calls\?\.isEmpty/],
  ['DOM observer', /MutationObserver|querySelector|innerText|data-task-status/],
  ['CDP injection', /remote-debugging|Runtime\.evaluate|webSocketDebuggerUrl|injectIntoChatRenderers/],
  ['accessibility inference', /AXUIElement|ApplicationServices|AXIsProcessTrusted/],
  ['local renderer event server', /NWListener|127\.0\.0\.1:17853|listener_heartbeat/],
  ['never resolve browser bundle id', /withBundleIdentifier: "com\.bot\.pc\.doubao\.browser"/],
  ['no hardcoded session deep link', /doubao\.com\/chat|doubao\.com\/conversation|https:\/\/[^"\\ ]*\/chat\//],
  ['no UUID neighbourhood parser', /interactionAnchor|requiredAnchor|capabilityAnchor|nearest\.distance/],
  ['no raw dbx interaction signature', /Data\("dbx_ic"\.utf8\)/],
  ['no window listing via accessibility', /CGWindowListCopyWindowInfo|NSAccessibility/],
  ['no launching browser to satisfy click', /openApplication\(at: .*doubao\.browser|launchApplication\(at: .*doubao\.browser/]
];
for (const [name, pattern] of mustContain) {
  if (!pattern.test(combinedSource)) throw new Error(`native contract missing: ${name}`);
}
for (const [name, pattern] of mustNotContain) {
  if (pattern.test(combinedSource)) throw new Error(`forbidden legacy mechanism remains: ${name}`);
}
console.log(JSON.stringify({checked: mustContain.map(([name]) => name), removed: mustNotContain.map(([name]) => name)}, null, 2));
