import fs from 'node:fs';

const source = fs.readFileSync(new URL('../Sources/main.swift', import.meta.url), 'utf8');
const mustContain = [
  ['runtime blocker register', /Register added blocker\\\. scope_id=local-task-conversation/],
  ['runtime blocker unregister', /Unregister blocker\\\. scope_id=local-task-conversation/],
  ['runtime log discovery', /saman_/],
  ['trajectory watcher', /trajectory\.jsonl/],
  ['main-agent filter', /assignment\.contains\("- Role: main"\)/],
  ['multi-profile discovery', /name == "Default" \|\| name\.hasPrefix\("Profile "\)/],
  ['runtime offsets', /runtimeLogOffsets:\s*\[String:\s*UInt64\]/],
  ['trajectory offsets', /trajectoryOffsets:\s*\[String:\s*UInt64\]/],
  ['explicit interaction signal', /interaction\.ask/],
  ['completion grace window', /completionGraceSeconds/],
  ['persistent event ledger', /processedEvents:\s*\[String:\s*String\]/],
  ['concurrent blocker ledger', /activeInterceptors:\s*\[String:\s*\[String:\s*String\]\]/],
  ['event replay guard', /processedEvents\[eventID\]\s*==\s*nil/],
  ['stable request identifier', /UNNotificationRequest\(identifier:\s*identifier/],
  ['notification rollback', /processedEvents\.removeValue\(forKey:\s*eventID\)/],
  // 点击通知激活豆包主应用（本轮新增契约）
  ['didReceive delegate implemented', /func userNotificationCenter\(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse/],
  ['controlled action marker written', /content\.userInfo = \[Self\.actionMarkerKey: Self\.actionMarkerValue\]/],
  ['reply category registered', /setNotificationCategories/],
  ['explicit activate action button', /UNNotificationAction\(/],
  ['default click handled', /UNNotificationDefaultActionIdentifier/],
  ['dismiss action ignored', /UNNotificationDismissActionIdentifier/],
  ['unknown action ignored', /ACTIVATE_IGNORED_ACTION/],
  ['target main bundle id constant', /targetBundleID = "com\.bot\.pc\.doubao"/],
  ['running-app activate all windows', /activate\(from: \.current,\s*options: \[\.activateAllWindows\]\)/],
  ['locate by bundle id when not running', /urlForApplication\(withBundleIdentifier: Self\.targetBundleID\)/],
  ['launch via openApplication', /openApplication\(at: appURL, configuration: config\)/],
  ['resolved bundle verified', /resolvedID == Self\.targetBundleID/],
  ['browser helper suffix refused', /hasSuffix\("\.browser"\)/],
  ['structured activation error log', /recordActivationError\(\s*stage:/],
  ['no CDP/DOM/renderer for activation', /openApplication/],
  ['userInfo marker guard before activate', /guard let marker = userInfo\[Self\.actionMarkerKey\] as\? String/]
];
const mustNotContain = [
  ['assistant text completion inference', /record\.tool_calls\?\.isEmpty/],
  ['DOM observer', /MutationObserver|querySelector|innerText|data-task-status/],
  ['CDP injection', /remote-debugging|Runtime\.evaluate|webSocketDebuggerUrl|injectIntoChatRenderers/],
  ['accessibility inference', /AXUIElement|ApplicationServices|AXIsProcessTrusted/],
  ['local renderer event server', /NWListener|127\.0\.0\.1:17853|listener_heartbeat/],
  ['never resolve browser bundle id', /withBundleIdentifier: "com\.bot\.pc\.doubao\.browser"/],
  ['no hardcoded session deep link', /doubao\.com\/chat|doubao\.com\/conversation|https:\/\/[^"\\ ]*\/chat\//],
  ['no window listing via accessibility', /CGWindowListCopyWindowInfo|NSAccessibility/],
  ['no launching browser to satisfy click', /openApplication\(at: .*doubao\.browser|launchApplication\(at: .*doubao\.browser/]
];
for (const [name, pattern] of mustContain) {
  if (!pattern.test(source)) throw new Error(`native contract missing: ${name}`);
}
for (const [name, pattern] of mustNotContain) {
  if (pattern.test(source)) throw new Error(`forbidden legacy mechanism remains: ${name}`);
}
console.log(JSON.stringify({checked: mustContain.map(([name]) => name), removed: mustNotContain.map(([name]) => name)}, null, 2));
