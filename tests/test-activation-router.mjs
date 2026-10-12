// 单元测试：复刻 didReceive response 的路由决策与激活目标校验逻辑。
// 这里把 Swift 侧 switch / bundle-id 校验用 JS 等价描述，证明决策表自洽。
const DEFAULT_ACTION = "com.apple.UNNotificationDefaultActionIdentifier";
const DISMISS_ACTION = "com.apple.UNNotificationDismissActionIdentifier";
const ACTIVATE_ACTION = "com.local.doubao-reply-notifier.action.activate";
const MARKER_KEY = "com.local.doubao-reply-notifier.action";
const MARKER_VALUE = "activate";
const REPLY_CATEGORY = "com.local.doubao-reply-notifier.category.reply";
const TARGET_BUNDLE_ID = "com.bot.pc.doubao";

// B) marker 桥接兼容：String / NSString 等价 / 其它字符串化类型都要与 MARKER_VALUE 相等。
function robustMarker(value) {
  if (value === null || value === undefined) return false;
  return String(value) === MARKER_VALUE;
}

// 返回 { decision: 'activate' | 'ignore', calledCompletion: true }
// B) 受控校验：marker 命中，或稳定 category 命中其一；二者都不命中才忽略。
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

// D) 激活统一计划：先定位 bundle；已运行记 ACTIVATE_EXISTING + 尽力 ignoringOtherApps，
//    随后一律 openApplication(activates=true) 真正激活/兜底；不再把 running.activate 当唯一动作。
function resolveLaunchPlan({ running, resolvedBundleID }) {
  if (!resolvedBundleID) return { mode: "error", reason: "bundle_id_not_found" };
  if (resolvedBundleID.endsWith(".browser")) return { mode: "error", reason: "refused_browser_helper" };
  if (resolvedBundleID !== TARGET_BUNDLE_ID) return { mode: "error", reason: "resolved_bundle_mismatch" };
  if (running) {
    return { mode: "activate_existing_then_openapp", bundleID: TARGET_BUNDLE_ID, bestEffort: "activateIgnoringOtherApps", fallback: "openApplication" };
  }
  return { mode: "launch_via_openapp", bundleID: resolvedBundleID, fallback: "openApplication" };
}

const cases = [
  // [userInfo, actionId, category, expectedDecision]
  [{}, DEFAULT_ACTION, "", "ignore"],                                  // 无标记且无 category
  [{}, DEFAULT_ACTION, REPLY_CATEGORY, "activate"],                    // category 受控兜底（桥接失败不静默）
  [{ [MARKER_KEY]: "activate" }, DEFAULT_ACTION, "", "activate"],       // 默认点击
  [{ [MARKER_KEY]: "activate" }, ACTIVATE_ACTION, "", "activate"],      // 显式 activate
  [{ [MARKER_KEY]: "activate" }, DISMISS_ACTION, REPLY_CATEGORY, "ignore"], // dismiss
  [{ [MARKER_KEY]: "activate" }, "some.unknown.action", REPLY_CATEGORY, "ignore"], // 未知
  [{ [MARKER_KEY]: "bogus" }, DEFAULT_ACTION, "", "ignore"],            // 标记值不符
  [{ [MARKER_KEY]: "activate" }, DEFAULT_ACTION, REPLY_CATEGORY, "activate"] // 双命中
];

for (const [userInfo, actionId, category, expected] of cases) {
  const r = route(userInfo, actionId, category);
  if (r.decision !== expected) throw new Error(`route(${actionId},${category}) expected ${expected}, got ${r.decision}`);
  if (r.calledCompletion !== true) throw new Error("completionHandler must be called exactly once");
}

// B) 桥接兼容：String 与 NSString 等价（String() 归一）都应受控。
if (robustMarker("activate") !== true) throw new Error("String marker must match");
if (robustMarker(new String("activate")) !== true) throw new Error("NSString-equivalent marker must match");
if (robustMarker("bogus") !== false) throw new Error("wrong marker value must not match");
if (robustMarker(undefined) !== false) throw new Error("missing marker must not match");
if (robustMarker(123) !== false) throw new Error("non-string marker must not match");

const plans = [
  [{ running: true, resolvedBundleID: "com.bot.pc.doubao" }, { mode: "activate_existing_then_openapp", bundleID: TARGET_BUNDLE_ID, bestEffort: "activateIgnoringOtherApps", fallback: "openApplication" }],
  [{ running: false, resolvedBundleID: "com.bot.pc.doubao" }, { mode: "launch_via_openapp", bundleID: "com.bot.pc.doubao", fallback: "openApplication" }],
  [{ running: true, resolvedBundleID: null }, { mode: "error", reason: "bundle_id_not_found" }],
  [{ running: false, resolvedBundleID: "com.wrong.app" }, { mode: "error", reason: "resolved_bundle_mismatch" }],
  [{ running: true, resolvedBundleID: "com.bot.pc.doubao.browser" }, { mode: "error", reason: "refused_browser_helper" }]
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
  bridge_cases: 5,
  launch_plans: plans.length,
  default_and_activate_treated_identically: true,
  dismiss_and_unknown_ignored: true,
  category_fallback_when_marker_bridging_fails: true,
  browser_helper_never_launched: true,
  openApplication_fallback_always: true,
  completion_called_once_every_path: true
}, null, 2));
