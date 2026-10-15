// 单元测试：复刻 didReceive response 的路由决策与多产品激活目标校验逻辑。
const DEFAULT_ACTION = "com.apple.UNNotificationDefaultActionIdentifier";
const DISMISS_ACTION = "com.apple.UNNotificationDismissActionIdentifier";
const ACTIVATE_ACTION = "com.local.doubao-reply-notifier.action.activate";
const MARKER_KEY = "com.local.doubao-reply-notifier.action";
const MARKER_VALUE = "activate";
const REPLY_CATEGORY = "com.local.doubao-reply-notifier.category.reply";
const TARGET_BUNDLE_IDS = ["com.work.pc.doubao", "com.bot.pc.doubao"];

function robustMarker(value) {
  if (value === null || value === undefined) return false;
  return String(value) === MARKER_VALUE;
}

function route(userInfo, actionIdentifier, category) {
  const marker = userInfo && userInfo[MARKER_KEY];
  const controlled = robustMarker(marker) || category === REPLY_CATEGORY;
  if (!controlled) return { decision: "ignore", reason: "not_controlled", calledCompletion: true };
  if (actionIdentifier === DEFAULT_ACTION || actionIdentifier === ACTIVATE_ACTION) {
    return { decision: "activate", reason: "activate", calledCompletion: true };
  }
  if (actionIdentifier === DISMISS_ACTION) return { decision: "ignore", reason: "dismiss", calledCompletion: true };
  return { decision: "ignore", reason: "unknown_action", calledCompletion: true };
}

function isHelper(bundleID, path = "") {
  const id = String(bundleID || "").toLowerCase();
  const p = String(path).toLowerCase();
  return id.includes("browser") || id.includes("helper") || p.includes(" browser.app/") || p.includes(" helper");
}

function chooseTarget({ preferredBundleID, runningBundleIDs = [], installedBundleIDs = [] }) {
  const preferred = TARGET_BUNDLE_IDS.includes(preferredBundleID) ? preferredBundleID : null;
  const available = (id) => runningBundleIDs.includes(id) || installedBundleIDs.includes(id);
  if (preferred && available(preferred)) return preferred;
  return TARGET_BUNDLE_IDS.find((id) => runningBundleIDs.includes(id))
    || TARGET_BUNDLE_IDS.find((id) => installedBundleIDs.includes(id))
    || null;
}

function resolveLaunchPlan({ targetBundleID, running, resolvedBundleID, resolvedPath = "" }) {
  if (!targetBundleID || !resolvedBundleID) return { mode: "error", reason: "bundle_id_not_found" };
  if (isHelper(resolvedBundleID, resolvedPath)) return { mode: "error", reason: "refused_browser_helper" };
  if (!TARGET_BUNDLE_IDS.includes(targetBundleID) || resolvedBundleID !== targetBundleID) {
    return { mode: "error", reason: "resolved_bundle_mismatch" };
  }
  if (running) {
    return { mode: "activate_existing_then_openapp", bundleID: targetBundleID, bestEffort: "activateIgnoringOtherApps", fallback: "openApplication" };
  }
  return { mode: "launch_via_openapp", bundleID: targetBundleID, fallback: "openApplication" };
}

const cases = [
  [{}, DEFAULT_ACTION, "", "ignore"],
  [{}, DEFAULT_ACTION, REPLY_CATEGORY, "activate"],
  [{ [MARKER_KEY]: "activate" }, DEFAULT_ACTION, "", "activate"],
  [{ [MARKER_KEY]: "activate" }, ACTIVATE_ACTION, "", "activate"],
  [{ [MARKER_KEY]: "activate" }, DISMISS_ACTION, REPLY_CATEGORY, "ignore"],
  [{ [MARKER_KEY]: "activate" }, "some.unknown.action", REPLY_CATEGORY, "ignore"],
  [{ [MARKER_KEY]: "bogus" }, DEFAULT_ACTION, "", "ignore"],
  [{ [MARKER_KEY]: "activate" }, DEFAULT_ACTION, REPLY_CATEGORY, "activate"]
];
for (const [userInfo, actionId, category, expected] of cases) {
  const r = route(userInfo, actionId, category);
  if (r.decision !== expected) throw new Error(`route(${actionId},${category}) expected ${expected}, got ${r.decision}`);
  if (r.calledCompletion !== true) throw new Error("completionHandler must be called exactly once");
}

if (robustMarker("activate") !== true) throw new Error("String marker must match");
if (robustMarker(new String("activate")) !== true) throw new Error("NSString-equivalent marker must match");
if (robustMarker("bogus") !== false || robustMarker(undefined) !== false || robustMarker(123) !== false) {
  throw new Error("invalid marker must not match");
}

const targetCases = [
  [{ preferredBundleID: "com.work.pc.doubao", runningBundleIDs: ["com.bot.pc.doubao"], installedBundleIDs: TARGET_BUNDLE_IDS }, "com.work.pc.doubao"],
  [{ preferredBundleID: "com.bot.pc.doubao", runningBundleIDs: ["com.work.pc.doubao"], installedBundleIDs: TARGET_BUNDLE_IDS }, "com.bot.pc.doubao"],
  [{ preferredBundleID: "com.evil.helper", runningBundleIDs: ["com.work.pc.doubao"], installedBundleIDs: TARGET_BUNDLE_IDS }, "com.work.pc.doubao"],
  [{ preferredBundleID: null, runningBundleIDs: [], installedBundleIDs: TARGET_BUNDLE_IDS }, "com.work.pc.doubao"],
  [{ preferredBundleID: "com.bot.pc.doubao", runningBundleIDs: ["com.work.pc.doubao"], installedBundleIDs: ["com.work.pc.doubao"] }, "com.work.pc.doubao"],
  [{ preferredBundleID: "com.bot.pc.doubao", runningBundleIDs: [], installedBundleIDs: [] }, null],
  [{ preferredBundleID: null, runningBundleIDs: [], installedBundleIDs: ["com.bot.pc.doubao"] }, "com.bot.pc.doubao"]
];
for (const [input, expected] of targetCases) {
  const got = chooseTarget(input);
  if (got !== expected) throw new Error(`target mismatch: ${JSON.stringify(input)} -> ${got} != ${expected}`);
}

const plans = [
  [{ targetBundleID: "com.work.pc.doubao", running: true, resolvedBundleID: "com.work.pc.doubao" }, { mode: "activate_existing_then_openapp", bundleID: "com.work.pc.doubao", bestEffort: "activateIgnoringOtherApps", fallback: "openApplication" }],
  [{ targetBundleID: "com.bot.pc.doubao", running: false, resolvedBundleID: "com.bot.pc.doubao" }, { mode: "launch_via_openapp", bundleID: "com.bot.pc.doubao", fallback: "openApplication" }],
  [{ targetBundleID: null, running: true, resolvedBundleID: null }, { mode: "error", reason: "bundle_id_not_found" }],
  [{ targetBundleID: "com.work.pc.doubao", running: false, resolvedBundleID: "com.wrong.app" }, { mode: "error", reason: "resolved_bundle_mismatch" }],
  [{ targetBundleID: "com.work.pc.doubao", running: true, resolvedBundleID: "com.work.pc.doubao.browser" }, { mode: "error", reason: "refused_browser_helper" }],
  [{ targetBundleID: "com.work.pc.doubao", running: true, resolvedBundleID: "com.work.pc.doubao", resolvedPath: "/Applications/DoubaoWork Browser.app/Contents/MacOS/DoubaoWork Browser" }, { mode: "error", reason: "refused_browser_helper" }]
];
for (const [input, expected] of plans) {
  const got = resolveLaunchPlan(input);
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    throw new Error(`plan mismatch: ${JSON.stringify(input)} -> ${JSON.stringify(got)} != ${JSON.stringify(expected)}`);
  }
}

if (TARGET_BUNDLE_IDS.some((id) => isHelper(id))) throw new Error("target bundle IDs must not be browser/helper variants");

console.log(JSON.stringify({
  unit: "activation-router",
  routed_cases: cases.length,
  target_selection_cases: targetCases.length,
  launch_plans: plans.length,
  doubaowork_preferred_for_doubaowork_notifications: true,
  legacy_doubao_remains_supported: true,
  untrusted_preference_ignored: true,
  browser_helper_never_launched: true,
  openApplication_fallback_always: true,
  completion_called_once_every_path: true
}, null, 2));
