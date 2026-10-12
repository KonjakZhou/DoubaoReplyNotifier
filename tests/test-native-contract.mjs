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
  ['notification rollback', /processedEvents\.removeValue\(forKey:\s*eventID\)/]
];
const mustNotContain = [
  ['assistant text completion inference', /record\.tool_calls\?\.isEmpty/],
  ['DOM observer', /MutationObserver|querySelector|innerText|data-task-status/],
  ['CDP injection', /remote-debugging|Runtime\.evaluate|webSocketDebuggerUrl|injectIntoChatRenderers/],
  ['accessibility inference', /AXUIElement|ApplicationServices|AXIsProcessTrusted/],
  ['local renderer event server', /NWListener|127\.0\.0\.1:17853|listener_heartbeat/]
];
for (const [name, pattern] of mustContain) {
  if (!pattern.test(source)) throw new Error(`native contract missing: ${name}`);
}
for (const [name, pattern] of mustNotContain) {
  if (pattern.test(source)) throw new Error(`forbidden legacy mechanism remains: ${name}`);
}
console.log(JSON.stringify({checked: mustContain.map(([name]) => name), removed: mustNotContain.map(([name]) => name)}, null, 2));
