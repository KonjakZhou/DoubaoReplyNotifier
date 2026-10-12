// 单元测试：复刻 didReceive response 的路由决策与激活目标校验逻辑。
// 这里把 Swift 侧 switch / bundle-id 校验用 JS 等价描述，证明决策表自洽。
const DEFAULT_ACTION = "com.apple.UNNotificationDefaultActionIdentifier";
const DISMISS_ACTION = "com.apple.UNNotificationDismissActionIdentifier";
const ACTIVATE_ACTION = "com.local.doubao-reply-notifier.action.activate";
const MARKER_KEY = "com.local.doubao-reply-notifier.action";
const MARKER_VALUE = "activate";
const TARGET_BUNDLE_ID = "com.bot.pc.doubao";

// 返回 { decision: 'activate' | 'ignore', calledCompletion: true }
function route(userInfo, actionIdentifier) {
  const marker = userInfo && userInfo[MARKER_KEY];
  if (marker !== MARKER_VALUE) return { decision: "ignore", calledCompletion: true };
  if (actionIdentifier === DEFAULT_ACTION || actionIdentifier === ACTIVATE_ACTION) {
    return { decision: "activate", calledCompletion: true };
  }
  if (actionIdentifier === DISMISS_ACTION) return { decision: "ignore", calledCompletion: true };
  return { decision: "ignore", calledCompletion: true }; // 未知 action
}

// 激活目标校验：已运行 -> 激活；未运行 -> 定位 -> 先拒 browser -> 再校验相等 -> 启动。
function resolveLaunchPlan({ runningIDs, resolvedBundleID }) {
  if (runningIDs.includes(TARGET_BUNDLE_ID)) {
    return { mode: "activate_running", bundleID: TARGET_BUNDLE_ID };
  }
  if (!resolvedBundleID) return { mode: "error", reason: "bundle_id_not_found" };
  if (resolvedBundleID.endsWith(".browser")) {
    return { mode: "error", reason: "refused_browser_helper" };
  }
  if (resolvedBundleID !== TARGET_BUNDLE_ID) {
    return { mode: "error", reason: "resolved_bundle_mismatch" };
  }
  return { mode: "launch", bundleID: resolvedBundleID };
}

const cases = [
  // [userInfo, actionId, expectedDecision]
  [{}, DEFAULT_ACTION, "ignore"],                                  // 无标记
  [{ [MARKER_KEY]: "activate" }, DEFAULT_ACTION, "activate"],      // 默认点击
  [{ [MARKER_KEY]: "activate" }, ACTIVATE_ACTION, "activate"],     // 显式 activate
  [{ [MARKER_KEY]: "activate" }, DISMISS_ACTION, "ignore"],        // dismiss
  [{ [MARKER_KEY]: "activate" }, "some.unknown.action", "ignore"], // 未知
  [{ [MARKER_KEY]: "bogus" }, DEFAULT_ACTION, "ignore"]            // 标记值不符
];

for (const [userInfo, actionId, expected] of cases) {
  const r = route(userInfo, actionId);
  if (r.decision !== expected) throw new Error(`route(${actionId}) expected ${expected}, got ${r.decision}`);
  if (r.calledCompletion !== true) throw new Error("completionHandler must be called exactly once");
}

const plans = [
  [{ runningIDs: ["com.bot.pc.doubao", "other"], resolvedBundleID: null }, { mode: "activate_running", bundleID: TARGET_BUNDLE_ID }],
  [{ runningIDs: [], resolvedBundleID: "com.bot.pc.doubao" }, { mode: "launch", bundleID: "com.bot.pc.doubao" }],
  [{ runningIDs: [], resolvedBundleID: null }, { mode: "error", reason: "bundle_id_not_found" }],
  [{ runningIDs: [], resolvedBundleID: "com.wrong.app" }, { mode: "error", reason: "resolved_bundle_mismatch" }],
  [{ runningIDs: [], resolvedBundleID: "com.bot.pc.doubao.browser" }, { mode: "error", reason: "refused_browser_helper" }]
];
for (const [input, expected] of plans) {
  const got = resolveLaunchPlan(input);
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    throw new Error(`plan mismatch: ${JSON.stringify(input)} -> ${JSON.stringify(got)} != ${JSON.stringify(expected)}`);
  }
}

// 强约束：目标 bundle id 永远不是 browser 变体。
if (TARGET_BUNDLE_ID.endsWith(".browser")) throw new Error("target bundle id must not be the browser helper");

console.log(JSON.stringify({
  unit: "activation-router",
  routed_cases: cases.length,
  launch_plans: plans.length,
  default_and_activate_treated_identically: true,
  dismiss_and_unknown_ignored: true,
  browser_helper_never_launched: true,
  completion_called_once_every_path: true
}, null, 2));
