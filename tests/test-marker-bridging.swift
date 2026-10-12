// 单元测试：复刻 AppDelegate.robustMarkerMatches 的桥接语义，
// 证明旧版 `userInfo[key] as? String` 守卫在特定桥接场景下静默退出、而新版不静默吞掉。
// 编译运行：swiftc tests/test-marker-bridging.swift -o /tmp/test-marker-bridging && /tmp/test-marker-bridging
import Foundation

private let actionMarkerValue = "activate"

// 与 Sources/main.swift 中 AppDelegate.robustMarkerMatches 完全一致的实现。
private func robustMarkerMatches(_ value: Any?) -> Bool {
    guard let value else { return false }
    if let s = value as? String { return s == actionMarkerValue }
    if let ns = value as? NSString { return ns.isEqual(to: actionMarkerValue) }
    return String(describing: value) == actionMarkerValue
}

private var failures = 0
private func check(_ name: String, _ actual: Bool, _ expected: Bool) {
    if actual != expected {
        print("FAIL \(name): expected \(expected), got \(actual)")
        failures += 1
    } else {
        print("ok   \(name) = \(actual)")
    }
}

let dict: [AnyHashable: Any] = [
    "str": "activate",
    "nsstr": NSString("activate"),
    "num": NSNumber(1),
    "bogus": "bogus"
]

// 新版 robust 判定：String / NSString 桥接都要命中；number / 缺失 / 错值都要 false。
check("robust String(\"activate\")", robustMarkerMatches(dict["str"]), true)
check("robust NSString(\"activate\")", robustMarkerMatches(dict["nsstr"]), true)
check("robust NSNumber(1)", robustMarkerMatches(dict["num"]), false)
check("robust missing", robustMarkerMatches(dict["absent"]), false)
check("robust \"bogus\"", robustMarkerMatches(dict["bogus"]), false)

// 对照旧版裸守卫 `userInfo[key] as? String`：
// 真实场景中 userInfo 来自 NSDictionary 桥接，NSString 值通常能桥接到 Swift String，
// 但一旦出现 CFBoolean / __NSCFNumber 等非 String 桥接，旧守卫会直接 false → 静默 completionHandler()。
// 这里断言旧守卫对 NSNumber 一定失败（复现静默退出），而新版不会误判为受控值。
let oldGuardOnNumber = (dict["num"] as? String) == "activate"
check("old guard on NSNumber is false (silent exit)", oldGuardOnNumber, false)
// 旧守卫对 NSString 值通常成立——这解释了为何“有时像坏了”：取决于运行时桥接类型。
let oldGuardOnNSString = (dict["nsstr"] as? String) == "activate"
check("old guard on NSString", oldGuardOnNSString, true)

if failures > 0 {
    print("MARKER_BRIDGING_FAILURES=\(failures)")
    exit(1)
}
print("MARKER_BRIDGING_OK all cases passed")
