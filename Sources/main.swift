import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import UserNotifications

private struct PersistedNotifierState: Codable {
    var version = 11
    var processedEvents: [String: String] = [:]
    var trajectoryOffsets: [String: UInt64] = [:]
    var runtimeLogOffsets: [String: UInt64] = [:]
    var indexedDBOffsets: [String: UInt64] = [:]
    var indexedDBKnownInteractions: [String: String] = [:]
    var permissionReviewToolIDs: [String: TimeInterval] = [:]
    var conversationTitles: [String: String] = [:]
    var activeRunIDs: [String: String] = [:]
    var activeInterceptors: [String: [String: String]] = [:]
    var awaitingActivityRuns: [String: String] = [:]
    var pendingInteractions: [String: [String: String]] = [:]
    var terminalRuns: [String: String] = [:]
    var resolverState = EventResolverState()
    var lastEventSource = ""
    var lastEventType = ""
    var conversationTitle = ""
    var lastEventID = ""
    var lastEventAt = ""

    private enum CodingKeys: String, CodingKey {
        case version, processedEvents, trajectoryOffsets, runtimeLogOffsets, indexedDBOffsets, indexedDBKnownInteractions, permissionReviewToolIDs, conversationTitles
        case activeRunIDs, activeInterceptors, awaitingActivityRuns, pendingInteractions, terminalRuns, resolverState
        case lastEventSource, lastEventType, conversationTitle, lastEventID, lastEventAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        version = 11
        processedEvents = try values.decodeIfPresent([String: String].self, forKey: .processedEvents) ?? [:]
        trajectoryOffsets = try values.decodeIfPresent([String: UInt64].self, forKey: .trajectoryOffsets) ?? [:]
        runtimeLogOffsets = try values.decodeIfPresent([String: UInt64].self, forKey: .runtimeLogOffsets) ?? [:]
        indexedDBOffsets = try values.decodeIfPresent([String: UInt64].self, forKey: .indexedDBOffsets) ?? [:]
        indexedDBKnownInteractions = try values.decodeIfPresent([String: String].self, forKey: .indexedDBKnownInteractions) ?? [:]
        permissionReviewToolIDs = try values.decodeIfPresent([String: TimeInterval].self, forKey: .permissionReviewToolIDs) ?? [:]
        conversationTitles = try values.decodeIfPresent([String: String].self, forKey: .conversationTitles) ?? [:]
        activeRunIDs = try values.decodeIfPresent([String: String].self, forKey: .activeRunIDs) ?? [:]
        activeInterceptors = try values.decodeIfPresent([String: [String: String]].self, forKey: .activeInterceptors) ?? [:]
        awaitingActivityRuns = try values.decodeIfPresent([String: String].self, forKey: .awaitingActivityRuns) ?? [:]
        pendingInteractions = try values.decodeIfPresent([String: [String: String]].self, forKey: .pendingInteractions) ?? [:]
        terminalRuns = try values.decodeIfPresent([String: String].self, forKey: .terminalRuns) ?? [:]
        resolverState = try values.decodeIfPresent(EventResolverState.self, forKey: .resolverState) ?? EventResolverState()
        lastEventSource = try values.decodeIfPresent(String.self, forKey: .lastEventSource) ?? ""
        lastEventType = try values.decodeIfPresent(String.self, forKey: .lastEventType) ?? ""
        conversationTitle = try values.decodeIfPresent(String.self, forKey: .conversationTitle) ?? ""
        lastEventID = try values.decodeIfPresent(String.self, forKey: .lastEventID) ?? ""
        lastEventAt = try values.decodeIfPresent(String.self, forKey: .lastEventAt) ?? ""
        terminalRuns = terminalRuns.filter { $0.value != "waiting_user" }
        if sourceVersion < 6 {
            runtimeLogOffsets.removeAll()
            activeRunIDs.removeAll()
            activeInterceptors.removeAll()
            awaitingActivityRuns.removeAll()
            pendingInteractions.removeAll()
        }
        if sourceVersion < 8 {
            indexedDBOffsets.removeAll()
            indexedDBKnownInteractions.removeAll()
        }
        if sourceVersion < 10 {
            pendingInteractions = pendingInteractions.mapValues { interactions in
                interactions.filter { $0.value != "indexeddb.authorize" }
            }.filter { !$0.value.isEmpty }
            permissionReviewToolIDs.removeAll()
        }
        if sourceVersion < 11 {
            pendingInteractions = pendingInteractions.mapValues { interactions in
                interactions.filter { !$0.value.hasPrefix("indexeddb.") }
            }.filter { !$0.value.isEmpty }
            permissionReviewToolIDs.removeAll()
            runtimeLogOffsets.removeAll()
            activeRunIDs.removeAll()
            activeInterceptors.removeAll()
            awaitingActivityRuns.removeAll()
        }
    }
}

private struct TrajectoryRecord: Decodable {
    struct ToolCall: Decodable {
        struct Function: Decodable { let name: String? }
        let id: String?
        let function: Function?
    }
    let role: String?
    let tool_call_id: String?
    let tool_calls: [ToolCall]?
}

private struct MainAgentWatch {
    let conversationID: String
    let agentID: String
    let trajectoryURL: URL
    let assignmentURL: URL
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let notificationCenter = UNUserNotificationCenter.current()
    private var statusItem: NSStatusItem!
    private var scanTimer: Timer?
    private var persistedState = PersistedNotifierState()
    private var watchesByPath: [String: MainAgentWatch] = [:]
    private var runtimeLogsByPath: [String: URL] = [:]
    private var lastDiscoveryAt = Date.distantPast
    private var pendingCompletions: [String: (runID: String, timer: Timer)] = [:]
    private var recentRuntimeContext: [String] = []
    private var pageSyncInterceptors = Set<String>()
    private var eventResolver = EventResolver()
    private let runtimeContextLimit = 24
    private let conversationTitleReader = ConversationTitleReader()
    private let indexedDBInteractionReader = IndexedDBInteractionReader()
    private let maxProcessedEvents = 4000
    private let processedEventTTL: TimeInterval = 7 * 24 * 60 * 60
    private let permissionReviewToolTTL: TimeInterval = 10 * 60
    private let unresolvedCompletionHold: TimeInterval = 0.5
    private lazy var completionMergeSeconds: TimeInterval = {
        Double(environment["DOUBAO_NOTIFIER_COMPLETION_MERGE_SECONDS"] ?? "") ?? 0.5
    }()
    private let environment = ProcessInfo.processInfo.environment
    // 受控 action 标记：只有带该 userInfo 标记的通知才会被 didReceive 处理。
    private static let actionMarkerKey = "com.local.doubao-reply-notifier.action"
    private static let actionMarkerValue = "activate"
    private static let replyCategoryIdentifier = "com.local.doubao-reply-notifier.category.reply"
    private static let activateActionIdentifier = "com.local.doubao-reply-notifier.action.activate"
    // 目标应用：豆包主应用 Bundle ID。绝不允许启动 com.bot.pc.doubao.browser。
    private static let targetBundleID = "com.bot.pc.doubao"
    private let activationErrorQueue = DispatchQueue(label: "com.local.doubao-reply-notifier.activation-errors")
    private lazy var activationErrorFile: URL = {
        if let override = environment["DOUBAO_NOTIFIER_ACTIVATION_ERROR_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DoubaoReplyNotifier/activation-errors.log")
    }()
    private lazy var doubaoDataRoot: URL = {
        if let override = environment["DOUBAO_NOTIFIER_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Doubao")
    }()
    private lazy var runtimeLogRoot: URL = {
        if let override = environment["DOUBAO_NOTIFIER_LOG_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return doubaoDataRoot.appendingPathComponent("sdk_storage/log", isDirectory: true)
    }()
    private lazy var stateFile: URL = {
        if let override = environment["DOUBAO_NOTIFIER_STATE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DoubaoReplyNotifier/state.json")
    }()
    private lazy var notificationsDisabled = environment["DOUBAO_NOTIFIER_DISABLE_NOTIFICATIONS"] == "1"
    private let waitingTools: Set<String> = [
        "interaction.ask", "interaction_ask",
        "interaction.request_action", "interaction_request_action",
        "interaction.authorize_folder", "interaction_authorize_folder"
    ]
    private let registerRegex = try! NSRegularExpression(
        pattern: #"Register added blocker\. scope_id=local-task-conversation, intercept_id=([^,\s]+):([0-9]+),.*sequence=([0-9]+)"#
    )
    private let unregisterRegex = try! NSRegularExpression(
        pattern: #"Unregister blocker\. scope_id=local-task-conversation, intercept_id=([^,\s]+):([0-9]+),"#
    )
    private let sandboxConversationRegex = try! NSRegularExpression(
        pattern: #"\"conversation_id\":\"([0-9]+)\".*?\"sandbox_id\":\"(sandbox-[0-9a-f-]+)\""#
    )
    private let nativeWaitingReceivedRegex = try! NSRegularExpression(
        pattern: #"\"event\":\"toolcall\".*?\"name\":\"(interaction(?:\.|_)(?:ask|request_action|authorize_folder))\".*?\"sandbox_id\":\"(sandbox-[0-9a-f-]+)\".*?\"status\":\"received\".*?\"tcid\":\"([0-9a-f-]{36})\""#
    )
    private let nativeWaitingSettledRegex = try! NSRegularExpression(
        pattern: #"\"event\":\"toolcall\".*?\"phase\":\"execution_settled\".*?\"name\":\"(interaction(?:\.|_)(?:ask|request_action|authorize_folder))\".*?\"sandbox_id\":\"(sandbox-[0-9a-f-]+)\".*?\"tcid\":\"([0-9a-f-]{36})\""#
    )
    private let anyToolSettledRegex = try! NSRegularExpression(
        pattern: #"\"event\":\"toolcall\".*?\"phase\":\"execution_settled\".*?\"name\":\"[^\"]+\".*?\"tcid\":\"([0-9a-f-]{36})\""#
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // 注册带“打开豆包”显式 action 的 category；不使用 .foreground，避免把本通知器带到前台。
        let activateAction = UNNotificationAction(
            identifier: Self.activateActionIdentifier,
            title: "打开豆包",
            options: []
        )
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.replyCategoryIdentifier,
                actions: [activateAction],
                intentIdentifiers: [],
                options: []
            )
        ])
        // 一次性测试投递：由环境变量指定唯一标题，走与生产完全一致的 marker+category 投递路径，
        // 投递后短暂等待即退出（用于人工点击回归，避免常驻第二实例）。
        if let testTitle = environment["DOUBAO_NOTIFIER_TEST_TITLE"], !testTitle.isEmpty {
            let testBody = environment["DOUBAO_NOTIFIER_TEST_BODY"] ?? "点击此通知应激活豆包主应用。"
            let uniq = String(UUID().uuidString.prefix(8))
            NSLog("ONESHOT_POST_BEGIN id=doubao-reply-oneshot-%@ title=%@", uniq, testTitle)
            postNotification(identifier: "doubao-reply-oneshot-\(uniq)", title: testTitle, body: testBody) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { NSApp.terminate(nil) }
            }
            return
        }
        loadState()
        eventResolver.replaceState(persistedState.resolverState)
        pruneProcessedEvents()
        configureMenu()
        if environment["DOUBAO_NOTIFIER_DISABLE_LOGIN_ITEM"] != "1" { registerLoginItem() }
        initializeExistingSources()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.scanSources() }
        if let scanTimer { RunLoop.current.add(scanTimer, forMode: .common) }
        scanSources()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let userInfo = request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let categoryIdentifier = request.content.categoryIdentifier
        // A) 第一行无条件记录：仅 id / action / category / marker 类型 / userInfo 键，绝不记录敏感值。
        //    用于判定系统 response 是否真正到达本 delegate（旧版此处无日志，导致桥接失败被静默吞掉）。
        let markerType: String = {
            guard let raw = userInfo[Self.actionMarkerKey] else { return "missing" }
            return String(describing: type(of: raw))
        }()
        let userInfoKeys = userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        NSLog("NOTIFICATION_RESPONSE_RECEIVED id=%@ action=%@ category=%@ markerType=%@ userInfoKeys=%@",
              request.identifier, actionIdentifier, categoryIdentifier, markerType, userInfoKeys)

        // B) 受控校验：marker（兼容 NSString/String/桥接）命中，或稳定 category 命中其一。
        //    二者都不命中才放行忽略；杜绝 as? String 桥接失败被静默退出、从不激活豆包。
        let markerMatches = Self.robustMarkerMatches(userInfo[Self.actionMarkerKey])
        let categoryMatches = (categoryIdentifier == Self.replyCategoryIdentifier)
        guard markerMatches || categoryMatches else {
            NSLog("RESPONSE_IGNORED reason=not_controlled id=%@ action=%@", request.identifier, actionIdentifier)
            completionHandler()
            return
        }

        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, Self.activateActionIdentifier:
            // 默认点击（通知主体）或显式“打开豆包”按钮 → 激活/启动豆包主应用。
            NSLog("RESPONSE_ACCEPTED reason=activate id=%@ action=%@", request.identifier, actionIdentifier)
            activateDoubaoApp(completion: completionHandler)
        case UNNotificationDismissActionIdentifier:
            // 划掉/关闭：不激活，仅结束。
            NSLog("RESPONSE_IGNORED reason=dismiss id=%@ action=%@", request.identifier, actionIdentifier)
            completionHandler()
        default:
            NSLog("RESPONSE_IGNORED reason=unknown_action id=%@ action=%@", request.identifier, actionIdentifier)
            completionHandler()
        }
    }

    // B) 兼容 NSString / Swift String / 桥接类型的 marker 判定；缺失或类型不符一律返回 false（由 category 兜底）。
    private static func robustMarkerMatches(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let s = value as? String { return s == actionMarkerValue }
        if let ns = value as? NSString { return ns.isEqual(to: actionMarkerValue) }
        return String(describing: value) == actionMarkerValue
    }

    private func activateDoubaoApp(completion: @escaping () -> Void) {
        let workspace = NSWorkspace.shared
        // D) 统一入口：先按 Bundle ID 定位豆包主应用（已运行 / 未运行都走这一条路）。
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: Self.targetBundleID) else {
            recordActivationError(
                stage: "locate",
                reason: "bundle_id_not_found",
                detail: "bundleID=\(Self.targetBundleID)"
            )
            NSLog("LAUNCH_FAILED stage=locate reason=bundle_id_not_found bundleID=%@", Self.targetBundleID)
            completion()
            return
        }
        // 校验解析结果：先显式挡掉 browser helper，再做精确相等校验。
        guard let resolvedID = Bundle(url: appURL)?.bundleIdentifier else {
            recordActivationError(
                stage: "verify",
                reason: "unresolved_bundle_id",
                detail: "url=\(appURL.path)"
            )
            completion()
            return
        }
        guard !resolvedID.hasSuffix(".browser") else {
            recordActivationError(
                stage: "verify",
                reason: "refused_browser_helper",
                detail: "bundleID=\(resolvedID) url=\(appURL.path)"
            )
            completion()
            return
        }
        guard resolvedID == Self.targetBundleID else {
            recordActivationError(
                stage: "verify",
                reason: "resolved_bundle_mismatch",
                detail: "expected=\(Self.targetBundleID) resolved=\(resolvedID) url=\(appURL.path)"
            )
            completion()
            return
        }
        // E) 已运行：记录 ACTIVATE_EXISTING，并尽力调用旧版可靠 API activateIgnoringOtherApps。
        //    但它不是唯一动作——随后统一用 openApplication(activates=true) 真正激活/兜底，
        //    不再把 macOS14 的 running.activate(from:.current) 当作唯一激活手段。
        if let running = workspace.runningApplications.first(where: { $0.bundleIdentifier == Self.targetBundleID }) {
            NSLog("ACTIVATE_EXISTING pid=%d bundleID=%@", running.processIdentifier, Self.targetBundleID)
            if #unavailable(macOS 14.0) {
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }
        // D) 统一真正激活/启动：openApplication + activates=true。
        //    对已运行实例会把它带到前台；对未运行实例则启动并激活。
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: appURL, configuration: config) { [weak self] runningApp, error in
            guard let self else { completion(); return }
            if let error {
                self.recordActivationError(
                    stage: "launch",
                    reason: "open_application_failed",
                    detail: "bundleID=\(resolvedID) url=\(appURL.path) error=\(error.localizedDescription)"
                )
                NSLog("LAUNCH_FAILED bundleID=%@ error=%@", resolvedID, error.localizedDescription)
            } else {
                NSLog("LAUNCH_SUCCEEDED bundleID=%@ pid=%d", resolvedID, runningApp?.processIdentifier ?? -1)
            }
            completion()
        }
    }

    private func recordActivationError(stage: String, reason: String, detail: String) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "stage": stage,
            "reason": reason,
            "detail": detail
        ]
        NSLog("ACTIVATE_ERROR stage=%@ reason=%@ detail=%@", stage, reason, detail)
        activationErrorQueue.async { [activationErrorFile] in
            let folder = activationErrorFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            var line = data
            line.append(Data("\n".utf8))
            if FileManager.default.fileExists(atPath: activationErrorFile.path),
               let handle = try? FileHandle(forWritingTo: activationErrorFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: activationErrorFile)
            }
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "豆包回复通知")
        let menu = NSMenu()
        let state = NSMenuItem(title: "监听豆包工作原生任务事件", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(NSMenuItem(title: "发送测试通知", action: #selector(sendTest), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func registerLoginItem() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("Unable to register login item: %@", error.localizedDescription) }
        }
    }

    private func sessionRoots() -> [URL] {
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: doubaoDataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return profiles.compactMap { profileURL in
            let name = profileURL.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") else { return nil }
            let sessionsURL = profileURL.appendingPathComponent(".doubao/agent_mode/workspace/.sessions", isDirectory: true)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: sessionsURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? sessionsURL : nil
        }
    }

    private func discoverMainAgents() -> [MainAgentWatch] {
        var result: [MainAgentWatch] = []
        for sessionsRoot in sessionRoots() {
            guard let conversations = try? FileManager.default.contentsOfDirectory(
                at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for conversationURL in conversations {
                let conversationID = conversationURL.lastPathComponent
                let agentsURL = conversationURL.appendingPathComponent("agents", isDirectory: true)
                guard let agentURLs = try? FileManager.default.contentsOfDirectory(
                    at: agentsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for agentURL in agentURLs where agentURL.lastPathComponent.hasPrefix("m_") {
                    let systemURL = agentURL.appendingPathComponent("system", isDirectory: true)
                    let assignmentURL = systemURL.appendingPathComponent("assignment.md")
                    let trajectoryURL = systemURL.appendingPathComponent("trajectory.jsonl")
                    guard FileManager.default.fileExists(atPath: assignmentURL.path),
                          FileManager.default.fileExists(atPath: trajectoryURL.path),
                          let assignment = try? String(contentsOf: assignmentURL, encoding: .utf8),
                          assignment.contains("- Role: main") else { continue }
                    result.append(MainAgentWatch(
                        conversationID: conversationID,
                        agentID: agentURL.lastPathComponent,
                        trajectoryURL: trajectoryURL,
                        assignmentURL: assignmentURL
                    ))
                }
            }
        }
        return result
    }

    private func discoverRuntimeLogs() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimeLogRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.lastPathComponent.hasPrefix("saman_") && $0.pathExtension == "log" }
    }

    private func refreshSourcesIfNeeded(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDiscoveryAt) >= 3 else { return }
        let discoveredWatches = discoverMainAgents()
        watchesByPath = Dictionary(uniqueKeysWithValues: discoveredWatches.map { ($0.trajectoryURL.path, $0) })
        let discoveredLogs = discoverRuntimeLogs()
        runtimeLogsByPath = Dictionary(uniqueKeysWithValues: discoveredLogs.map { ($0.path, $0) })
        lastDiscoveryAt = Date()
    }

    private func initializeExistingSources() {
        refreshSourcesIfNeeded(force: true)
        var changed = false
        let discoveredTitles = conversationTitleReader.titles(
            conversationIDs: Set(watchesByPath.values.map(\.conversationID)),
            doubaoDataRoot: doubaoDataRoot
        )
        for watch in watchesByPath.values {
            let key = watch.trajectoryURL.path
            if persistedState.trajectoryOffsets[key] == nil, let size = fileSize(watch.trajectoryURL) {
                persistedState.trajectoryOffsets[key] = size
                changed = true
            }
            if let title = discoveredTitles[watch.conversationID],
               persistedState.conversationTitles[watch.conversationID] != title {
                persistedState.conversationTitles[watch.conversationID] = title
                changed = true
            }
        }
        for logURL in runtimeLogsByPath.values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if persistedState.runtimeLogOffsets[logURL.path] == nil, let size = fileSize(logURL) {
                rebuildActiveRuntimeState(from: logURL, size: size)
                persistedState.runtimeLogOffsets[logURL.path] = size
                changed = true
            }
        }
        let indexedDBLogs = indexedDBInteractionReader.databaseFiles(doubaoDataRoot: doubaoDataRoot)
            .filter { $0.pathExtension.lowercased() == "log" }
        for fileURL in indexedDBLogs {
            if persistedState.indexedDBOffsets[fileURL.path] == nil, let size = fileSize(fileURL) {
                if let data = readRange(fileURL, offset: 0, length: size) {
                    for event in IndexedDBInteractionReader.waitingEvents(inWAL: data, agentConversations: Dictionary(uniqueKeysWithValues: watchesByPath.values.map { ($0.agentID, $0.conversationID) })) {
                        persistedState.indexedDBKnownInteractions["\(event.conversationID)|\(event.interactionID)"] = event.kind
                    }
                }
                persistedState.indexedDBOffsets[fileURL.path] = size
                changed = true
            }
        }
        let liveIndexedDBPaths = Set(indexedDBLogs.map(\.path))
        persistedState.indexedDBOffsets = persistedState.indexedDBOffsets.filter { liveIndexedDBPaths.contains($0.key) }
        if changed { _ = saveState() }
    }

    private func rebuildActiveRuntimeState(from logURL: URL, size: UInt64) {
        let window: UInt64 = 8 * 1024 * 1024
        let offset = size > window ? size - window : 0
        guard let data = readRange(logURL, offset: offset, length: size - offset),
              let text = String(data: data, encoding: .utf8) else { return }
        let aligned: Substring
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            aligned = text[text.index(after: newline)...]
        } else {
            aligned = Substring(text)
        }
        for line in aligned.split(separator: "\n", omittingEmptySubsequences: true) {
            processRuntimeLogLine(String(line), scheduleTerminals: false)
        }
    }

    private func scanSources() {
        refreshSourcesIfNeeded()
        var changed = scanRuntimeLogs()
        changed = scanIndexedDBInteractions() || changed
        changed = scanTrajectories() || changed
        if changed { _ = saveState() }
        updateMenu("监听中 · \(watchesByPath.count) 个会话")
    }

    private func scanIndexedDBInteractions() -> Bool {
        let agentConversations = Dictionary(uniqueKeysWithValues: watchesByPath.values.map { ($0.agentID, $0.conversationID) })
        guard !agentConversations.isEmpty else { return false }
        let files = indexedDBInteractionReader.databaseFiles(doubaoDataRoot: doubaoDataRoot)
            .filter { $0.pathExtension.lowercased() == "log" }
        let livePaths = Set(files.map(\.path))
        var changed = false

        for fileURL in files {
            let path = fileURL.path
            guard let size = fileSize(fileURL) else { continue }
            let oldOffset: UInt64
            if let saved = persistedState.indexedDBOffsets[path] {
                oldOffset = saved
            } else {
                oldOffset = 0
                persistedState.indexedDBOffsets[path] = 0
                changed = true
            }
            if size < oldOffset {
                persistedState.indexedDBOffsets[path] = 0
                persistedState.indexedDBKnownInteractions.removeAll()
                changed = true
                continue
            }
            if size == oldOffset { continue }

            let readOffset: UInt64 = 0
            guard let data = readRange(fileURL, offset: readOffset, length: size - readOffset) else { continue }
            persistedState.indexedDBOffsets[path] = size
            changed = true
            let events = IndexedDBInteractionReader.waitingEvents(
                inWAL: data,
                agentConversations: agentConversations
            )
            for event in events {
            let key = "\(event.conversationID)|\(event.interactionID)"
            guard persistedState.indexedDBKnownInteractions[key] == nil else { continue }
            persistedState.indexedDBKnownInteractions[key] = event.kind
            if event.kind == "authorize" {
                let toolKey = "\(event.conversationID)|\(event.interactionID)"
                if persistedState.permissionReviewToolIDs[toolKey] != nil {
                    NSLog("INDEXEDDB_AUTHORIZE_AFTER_PERMISSION_REVIEW conversation=%@ interaction=%@", event.conversationID, event.interactionID)
                    continue
                }
            }
            applyCanonicalEvent(CanonicalEvent(
                    kind: .interactionWaiting,
                    conversationID: event.conversationID,
                    source: "indexeddb:\(event.kind)",
                    interactionID: event.interactionID,
                    waitingTool: "indexeddb.\(event.kind)"
                ))
            }
        }

        let previousCount = persistedState.indexedDBOffsets.count
        persistedState.indexedDBOffsets = persistedState.indexedDBOffsets.filter { livePaths.contains($0.key) }
        return changed || persistedState.indexedDBOffsets.count != previousCount
    }

    private func scanRuntimeLogs() -> Bool {
        var changed = false
        for logURL in runtimeLogsByPath.values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let path = logURL.path
            guard let size = fileSize(logURL) else { continue }
            let oldOffset: UInt64
            if let saved = persistedState.runtimeLogOffsets[path] {
                oldOffset = saved
            } else {
                oldOffset = 0
                persistedState.runtimeLogOffsets[path] = 0
                changed = true
            }
            if size < oldOffset {
                persistedState.runtimeLogOffsets[path] = size
                changed = true
                continue
            }
            if size == oldOffset { continue }
            guard let data = readRange(logURL, offset: oldOffset, length: size - oldOffset),
                  let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let completeData = data.prefix(through: lastNewline)
            guard let chunk = String(data: completeData, encoding: .utf8) else { continue }
            persistedState.runtimeLogOffsets[path] = oldOffset + UInt64(completeData.count)
            changed = true
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                processRuntimeLogLine(String(line), scheduleTerminals: true)
            }
        }
        return changed
    }

    private func processRuntimeLogLine(_ line: String, scheduleTerminals: Bool) {
        if let match = firstMatch(sandboxConversationRegex, line), match.count == 2 {
            let events = eventResolver.recordSandboxMapping(
                sandboxID: match[1],
                conversationID: match[0],
                source: "resolver:runtime_mapping"
            )
            for event in events { applyCanonicalEvent(event) }
        }
        if scheduleTerminals,
           let review = PermissionReviewSource.reviewPresented(in: line) {
            applyCanonicalEvent(CanonicalEvent(
                kind: .interactionWaiting,
                conversationID: review.conversationID,
                source: "runtime:permission_review_presented",
                interactionID: review.reviewID,
                waitingTool: "permission_review.authorize"
            ))
        }
        if scheduleTerminals,
           let toolStarted = PermissionReviewSource.toolStarted(in: line) {
            let resolvedReview = resolvePermissionReviews(conversationID: toolStarted.conversationID)
            if resolvedReview {
                persistedState.permissionReviewToolIDs["\(toolStarted.conversationID)|\(toolStarted.toolCallID)"] = Date().timeIntervalSince1970
            }
        }
        if scheduleTerminals,
           let match = firstMatch(nativeWaitingReceivedRegex, line), match.count == 3 {
            let activeConversationIDs = Array(persistedState.activeRunIDs.keys)
            let provisionalConversationID = activeConversationIDs.count == 1
                ? activeConversationIDs.first
                : nil
            let events = eventResolver.ingestNativeReceived(
                sandboxID: match[1],
                interactionID: match[2],
                waitingTool: match[0],
                receivedAt: Date().timeIntervalSince1970,
                source: "runtime:toolcall_received",
                provisionalConversationID: provisionalConversationID,
                candidateConversationIDs: activeConversationIDs
            )
            for event in events { applyCanonicalEvent(event) }
        }
        if scheduleTerminals,
           let match = firstMatch(nativeWaitingSettledRegex, line), match.count == 3 {
            let events = eventResolver.ingestNativeSettled(
                sandboxID: match[1],
                interactionID: match[2],
                settledAt: Date().timeIntervalSince1970,
                source: "runtime:toolcall_settled"
            )
            for event in events { applyCanonicalEvent(event) }
        }
        if scheduleTerminals,
           let match = firstMatch(anyToolSettledRegex, line), match.count == 1 {
            resolveWaitingInteractionEverywhere(interactionID: match[0])
        }

        recentRuntimeContext.append(line)
        if recentRuntimeContext.count > runtimeContextLimit {
            recentRuntimeContext.removeFirst(recentRuntimeContext.count - runtimeContextLimit)
        }

        if let match = firstMatch(registerRegex, line), match.count == 3 {
            let interceptID = match[0]
            let conversationID = match[1]
            let sequence = match[2]
            let context = recentRuntimeContext.joined(separator: "\n")
            let isPageSync = context.contains("chat_page_navigate_event") &&
                context.contains("presentation_sync_")
            if isPageSync {
                pageSyncInterceptors.insert("\(conversationID)|\(interceptID)")
                recentRuntimeContext.removeAll(keepingCapacity: true)
                NSLog("PAGE_SYNC_BLOCKER_IGNORED conversation=%@ intercept=%@ sequence=%@", conversationID, interceptID, sequence)
                return
            }
            recentRuntimeContext.removeAll(keepingCapacity: true)
            let runID = persistedState.activeRunIDs[conversationID] ??
                "runtime|\(conversationID)|\(sequence)|\(sha256(line))"
            applyCanonicalEvent(CanonicalEvent(
                kind: .runStarted,
                conversationID: conversationID,
                source: "runtime:blocker_registered",
                runID: runID,
                blockerID: interceptID
            ))
            return
        }
        if let match = firstMatch(unregisterRegex, line), match.count == 2 {
            let interceptID = match[0]
            let conversationID = match[1]
            let pageSyncKey = "\(conversationID)|\(interceptID)"
            if pageSyncInterceptors.remove(pageSyncKey) != nil { return }
            guard let runID = persistedState.activeInterceptors[conversationID]?[interceptID] else { return }
            if scheduleTerminals {
                applyCanonicalEvent(CanonicalEvent(
                    kind: .runBlockerEnded,
                    conversationID: conversationID,
                    source: "runtime:blocker_unregistered",
                    runID: runID,
                    blockerID: interceptID
                ))
            } else {
                var interceptors = persistedState.activeInterceptors[conversationID] ?? [:]
                interceptors.removeValue(forKey: interceptID)
                persistedState.activeInterceptors[conversationID] = interceptors
                if interceptors.isEmpty {
                    persistedState.activeRunIDs.removeValue(forKey: conversationID)
                    persistedState.activeInterceptors.removeValue(forKey: conversationID)
                    persistedState.awaitingActivityRuns.removeValue(forKey: conversationID)
                }
            }
        }
    }

    private func applyCanonicalEvent(_ event: CanonicalEvent) {
        switch event.kind {
        case .runStarted:
            guard let runID = event.runID, let blockerID = event.blockerID else { return }
            persistedState.activeRunIDs[event.conversationID] = runID
            persistedState.awaitingActivityRuns.removeValue(forKey: event.conversationID)
            persistedState.terminalRuns.removeValue(forKey: runID)
            var interceptors = persistedState.activeInterceptors[event.conversationID] ?? [:]
            interceptors[blockerID] = runID
            persistedState.activeInterceptors[event.conversationID] = interceptors
            if let pending = pendingCompletions.removeValue(forKey: event.conversationID) { pending.timer.invalidate() }
        case .runBlockerEnded:
            guard let runID = event.runID, let blockerID = event.blockerID else { return }
            var interceptors = persistedState.activeInterceptors[event.conversationID] ?? [:]
            guard interceptors.removeValue(forKey: blockerID) != nil else { return }
            persistedState.activeInterceptors[event.conversationID] = interceptors
            guard interceptors.isEmpty, persistedState.activeRunIDs[event.conversationID] == runID else { return }
            reevaluateCompletion(conversationID: event.conversationID)
        case .interactionWaiting:
            guard let interactionID = event.interactionID, let waitingTool = event.waitingTool else { return }
            registerWaitingInteraction(
                conversationID: event.conversationID,
                interactionID: interactionID,
                waitingTool: waitingTool,
                source: event.source
            )
        case .interactionResolved:
            guard let interactionID = event.interactionID else { return }
            resolveWaitingInteraction(conversationID: event.conversationID, interactionID: interactionID)
        case .assistantActivity:
            if let runID = persistedState.activeRunIDs[event.conversationID],
               persistedState.awaitingActivityRuns[event.conversationID] == runID {
                persistedState.awaitingActivityRuns.removeValue(forKey: event.conversationID)
            }
        }
    }

    private func reevaluateCompletion(conversationID: String) {
        guard let runID = persistedState.activeRunIDs[conversationID],
              persistedState.terminalRuns[runID] == nil,
              (persistedState.activeInterceptors[conversationID] ?? [:]).isEmpty,
              (persistedState.pendingInteractions[conversationID] ?? [:]).isEmpty,
              persistedState.awaitingActivityRuns[conversationID] == nil else {
            if let pending = pendingCompletions.removeValue(forKey: conversationID) { pending.timer.invalidate() }
            return
        }
        scheduleCompletion(conversationID: conversationID, runID: runID)
    }

    private func scheduleCompletion(conversationID: String, runID: String) {
        if persistedState.terminalRuns[runID] != nil { return }
        guard (persistedState.pendingInteractions[conversationID] ?? [:]).isEmpty else { return }
        if let pending = pendingCompletions.removeValue(forKey: conversationID) { pending.timer.invalidate() }
        let timer = Timer.scheduledTimer(withTimeInterval: completionMergeSeconds, repeats: false) { [weak self] _ in
            guard let self,
                  self.persistedState.activeRunIDs[conversationID] == runID,
                  (self.persistedState.activeInterceptors[conversationID] ?? [:]).isEmpty,
                  (self.persistedState.pendingInteractions[conversationID] ?? [:]).isEmpty,
                  self.persistedState.awaitingActivityRuns[conversationID] == nil,
                  self.persistedState.terminalRuns[runID] == nil else { return }
            let now = Date().timeIntervalSince1970
            if self.eventResolver.hasRecentUnresolvedCandidate(
                conversationID: conversationID,
                now: now,
                hold: self.unresolvedCompletionHold
            ) {
                self.pendingCompletions.removeValue(forKey: conversationID)
                self.scheduleCompletion(conversationID: conversationID, runID: runID)
                return
            }
            self.pendingCompletions.removeValue(forKey: conversationID)
            self.persistedState.activeRunIDs.removeValue(forKey: conversationID)
            self.persistedState.activeInterceptors.removeValue(forKey: conversationID)
            self.persistedState.awaitingActivityRuns.removeValue(forKey: conversationID)
            self.persistedState.pendingInteractions.removeValue(forKey: conversationID)
            self.emitTerminal(type: "reply_completed", conversationID: conversationID, runID: runID, source: "runtime:exit_intercept")
        }
        pendingCompletions[conversationID] = (runID, timer)
        RunLoop.current.add(timer, forMode: .common)
    }

    private func scanTrajectories() -> Bool {
        var changed = false
        for watch in watchesByPath.values {
            let path = watch.trajectoryURL.path
            guard let size = fileSize(watch.trajectoryURL) else { continue }
            let oldOffset: UInt64
            if let saved = persistedState.trajectoryOffsets[path] {
                oldOffset = saved
            } else {
                oldOffset = 0
                persistedState.trajectoryOffsets[path] = 0
                if let title = conversationTitleReader.title(conversationID: watch.conversationID, doubaoDataRoot: doubaoDataRoot) {
                    persistedState.conversationTitles[watch.conversationID] = title
                }
                changed = true
            }
            if size < oldOffset {
                persistedState.trajectoryOffsets[path] = size
                changed = true
                continue
            }
            if size == oldOffset { continue }
            guard let data = readRange(watch.trajectoryURL, offset: oldOffset, length: size - oldOffset),
                  let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let completeData = data.prefix(through: lastNewline)
            guard let chunk = String(data: completeData, encoding: .utf8) else { continue }
            persistedState.trajectoryOffsets[path] = oldOffset + UInt64(completeData.count)
            if let title = conversationTitleReader.title(conversationID: watch.conversationID, doubaoDataRoot: doubaoDataRoot) {
                persistedState.conversationTitles[watch.conversationID] = title
            }
            changed = true
            processTrajectory(chunk: chunk, watch: watch)
        }
        return changed
    }

    private func indexedDBKind(for waitingTool: String) -> String? {
        if waitingTool.contains("authorize") { return "authorize" }
        if waitingTool.contains("ask") { return "ask" }
        if waitingTool.contains("request_action") { return "request_action" }
        return nil
    }

    private func processTrajectory(chunk: String, watch: MainAgentWatch) {
        var calls: [TrajectoryInteractionCall] = []
        var results = Set<String>()
        var sawAssistantActivity = false

        for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(TrajectoryRecord.self, from: data) else { continue }
            if record.role == "assistant" {
                sawAssistantActivity = true
                for call in record.tool_calls ?? [] {
                    guard let waitingTool = call.function?.name, waitingTools.contains(waitingTool) else { continue }
                    calls.append(TrajectoryInteractionCall(id: call.id ?? sha256(line), tool: waitingTool))
                }
            } else if record.role == "tool", let interactionID = record.tool_call_id {
                results.insert(interactionID)
            }
        }

        let events = eventResolver.ingestTrajectory(
            conversationID: watch.conversationID,
            calls: calls,
            results: results,
            sawAssistantActivity: sawAssistantActivity,
            source: "trajectory"
        )
        for event in events { applyCanonicalEvent(event) }

        if sawAssistantActivity {
            _ = resolvePermissionReviews(conversationID: watch.conversationID)
        }
        guard !results.isEmpty else { return }
        reevaluateCompletion(conversationID: watch.conversationID)
    }

    @discardableResult
    private func resolvePermissionReviews(conversationID: String) -> Bool {
        guard var interactions = persistedState.pendingInteractions[conversationID] else { return false }
        let reviewIDs = interactions.filter { $0.value.hasPrefix("permission_review.") }.map(\.key)
        guard !reviewIDs.isEmpty else { return false }
        for reviewID in reviewIDs { interactions.removeValue(forKey: reviewID) }
        persistedState.pendingInteractions[conversationID] = interactions
        NSLog("PERMISSION_REVIEWS_RESOLVED conversation=%@ count=%d", conversationID, reviewIDs.count)
        reevaluateCompletion(conversationID: conversationID)
        return true
    }

    private func resolveWaitingInteractionEverywhere(interactionID: String) {
        let conversationIDs = persistedState.pendingInteractions.compactMap { conversationID, interactions in
            interactions[interactionID] == nil ? nil : conversationID
        }
        for conversationID in conversationIDs {
            resolveWaitingInteraction(conversationID: conversationID, interactionID: interactionID)
        }
    }

    private func resolveWaitingInteraction(conversationID: String, interactionID: String) {
        guard var interactions = persistedState.pendingInteractions[conversationID],
              interactions.removeValue(forKey: interactionID) != nil else { return }
        persistedState.pendingInteractions[conversationID] = interactions
        reevaluateCompletion(conversationID: conversationID)
    }

    private func registerWaitingInteraction(
        conversationID: String,
        interactionID: String,
        waitingTool: String,
        source: String
    ) {
        let eventID = "\(conversationID)|waiting_user|\(sha256(interactionID))"
        if persistedState.processedEvents[eventID] != nil { return }

        let isPermissionReview = waitingTool.hasPrefix("permission_review.")
        if isPermissionReview,
           (persistedState.pendingInteractions[conversationID] ?? [:]).values.contains(where: { $0.hasPrefix("permission_review.") }) {
            return
        }

        let runID: String
        if let activeRunID = persistedState.activeRunIDs[conversationID],
           persistedState.terminalRuns[activeRunID] == nil {
            runID = activeRunID
        } else if source.hasPrefix("runtime:") || source.hasPrefix("resolver:") {
            runID = "interaction|\(conversationID)|\(sha256(interactionID))"
            persistedState.activeRunIDs[conversationID] = runID
            persistedState.activeInterceptors[conversationID] = [:]
            persistedState.awaitingActivityRuns.removeValue(forKey: conversationID)
            persistedState.terminalRuns.removeValue(forKey: runID)
            NSLog("INTERACTION_RUN_CREATED conversation=%@ interaction=%@ source=%@", conversationID, interactionID, source)
        } else {
            NSLog("STALE_WAITING_IGNORED conversation=%@ interaction=%@ source=%@", conversationID, interactionID, source)
            return
        }
        persistedState.awaitingActivityRuns.removeValue(forKey: conversationID)
        var interactions = persistedState.pendingInteractions[conversationID] ?? [:]
        if isPermissionReview {
            let lateAuthorizeIDs = interactions.filter { $0.value == "indexeddb.authorize" }.map(\.key)
            for authorizeID in lateAuthorizeIDs { interactions.removeValue(forKey: authorizeID) }
        }
        let kind = indexedDBKind(for: waitingTool)
        let matchingIndexedDB = kind.map { expected in
            interactions.filter { $0.value == "indexeddb.\(expected)" && $0.key != interactionID }.map(\.key)
        } ?? []
        for indexedDBID in matchingIndexedDB { interactions.removeValue(forKey: indexedDBID) }
        let wasNew = interactions[interactionID] == nil
        if wasNew {
            interactions[interactionID] = waitingTool
            persistedState.pendingInteractions[conversationID] = interactions
            if let pending = pendingCompletions.removeValue(forKey: conversationID) { pending.timer.invalidate() }
        } else if interactions[interactionID]?.hasPrefix("indexeddb.") == true,
                  !waitingTool.hasPrefix("indexeddb.") {
            interactions[interactionID] = waitingTool
            persistedState.pendingInteractions[conversationID] = interactions
        }
        if wasNew && matchingIndexedDB.isEmpty {
            emitWaiting(conversationID: conversationID, interactionID: interactionID, source: source)
        }
    }

    private func emitWaiting(conversationID: String, interactionID: String, source: String) {
        let eventID = "\(conversationID)|waiting_user|\(sha256(interactionID))"
        guard persistedState.processedEvents[eventID] == nil else { return }
        emitEvent(
            type: "waiting_user",
            eventID: eventID,
            conversationID: conversationID,
            source: source,
            terminalRunID: nil
        )
    }

    private func emitTerminal(type: String, conversationID: String, runID: String, source: String) {
        let eventID = "\(conversationID)|\(type)|\(sha256(runID))"
        guard persistedState.processedEvents[eventID] == nil else { return }
        emitEvent(
            type: type,
            eventID: eventID,
            conversationID: conversationID,
            source: source,
            terminalRunID: runID
        )
    }

    private func emitEvent(type: String, eventID: String, conversationID: String, source: String, terminalRunID: String?) {
        let title: String
        if let currentTitle = conversationTitleReader.title(conversationID: conversationID, doubaoDataRoot: doubaoDataRoot) {
            title = currentTitle
            persistedState.conversationTitles[conversationID] = currentTitle
        } else {
            title = persistedState.conversationTitles[conversationID] ?? "豆包工作"
        }
        let body = type == "waiting_user" ? "等待你确认或提供信息" : "当前对话轮次回复完成"
        persistedState.processedEvents[eventID] = ISO8601DateFormatter().string(from: Date())
        if let terminalRunID { persistedState.terminalRuns[terminalRunID] = type }
        recordState(source: source, eventID: eventID, eventType: type, conversationTitle: title)
        guard saveState() else {
            persistedState.processedEvents.removeValue(forKey: eventID)
            return
        }
        postNotification(identifier: notificationIdentifier(eventID: eventID, conversationID: conversationID), title: title, body: body) { [weak self] success in
            guard let self, !success else { return }
            self.persistedState.processedEvents.removeValue(forKey: eventID)
            _ = self.saveState()
        }
    }

    private func firstMatch(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let result = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(result.range(at: index), in: line) else { return nil }
            return String(line[swiftRange])
        }
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }

    private func readRange(_ url: URL, offset: UInt64, length: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(length))
        } catch {
            NSLog("SOURCE_READ_FAILED path=%@ error=%@", url.path, error.localizedDescription)
            return nil
        }
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func notificationIdentifier(eventID: String, conversationID: String) -> String {
        "doubao-reply-\(sha256("\(conversationID)|\(eventID)"))"
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let decoded = try? JSONDecoder().decode(PersistedNotifierState.self, from: data) else { return }
        persistedState = decoded
    }

    private func pruneProcessedEvents() {
        let formatter = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-processedEventTTL)
        persistedState.processedEvents = persistedState.processedEvents.filter {
            guard let date = formatter.date(from: $0.value) else { return false }
            return date >= cutoff
        }
        if persistedState.processedEvents.count > maxProcessedEvents {
            let kept = persistedState.processedEvents.sorted { $0.value > $1.value }.prefix(maxProcessedEvents)
            persistedState.processedEvents = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        if persistedState.terminalRuns.count > maxProcessedEvents {
            persistedState.terminalRuns.removeAll(keepingCapacity: true)
        }
        let toolCutoff = Date().timeIntervalSince1970 - permissionReviewToolTTL
        persistedState.permissionReviewToolIDs = persistedState.permissionReviewToolIDs.filter { $0.value >= toolCutoff }
        _ = saveState()
    }

    private func recordState(source: String, eventID: String, eventType: String, conversationTitle: String) {
        persistedState.lastEventSource = source
        persistedState.lastEventType = eventType
        persistedState.conversationTitle = conversationTitle
        persistedState.lastEventID = eventID
        persistedState.lastEventAt = ISO8601DateFormatter().string(from: Date())
    }

    @discardableResult private func saveState() -> Bool {
        let folder = stateFile.deletingLastPathComponent()
        do {
            eventResolver.prune(now: Date().timeIntervalSince1970)
            let reviewToolCutoff = Date().timeIntervalSince1970 - permissionReviewToolTTL
            persistedState.permissionReviewToolIDs = persistedState.permissionReviewToolIDs.filter { $0.value >= reviewToolCutoff }
            persistedState.resolverState = eventResolver.state
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder.sortedPretty.encode(persistedState)
            try data.write(to: stateFile, options: .atomic)
            return true
        } catch {
            NSLog("STATE_WRITE_FAILED error=%@", error.localizedDescription)
            return false
        }
    }

    private func postNotification(identifier: String, title: String, body: String, completion: @escaping (Bool) -> Void) {
        if notificationsDisabled {
            NSLog("NOTIFICATION_SUPPRESSED id=%@ title=%@ body=%@", identifier, title, body)
            completion(true)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 受控 action 标记：didReceive 只处理带该标记的通知，并据此激活豆包主应用。
        content.userInfo = [Self.actionMarkerKey: Self.actionMarkerValue]
        content.categoryIdentifier = Self.replyCategoryIdentifier
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        notificationCenter.add(request) { error in
            if let error {
                NSLog("NOTIFICATION_FAILED id=%@ error=%@", identifier, error.localizedDescription)
                DispatchQueue.main.async { completion(false) }
            } else {
                NSLog("NOTIFICATION_SUBMITTED id=%@ title=%@ body=%@", identifier, title, body)
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    @objc private func sendTest() {
        postNotification(identifier: "doubao-reply-test", title: "豆包回复通知测试", body: "原生任务事件监听器已在运行。") { _ in }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateMenu(_ title: String) {
        if let item = statusItem.menu?.items.first, item.title != title { item.title = title }
    }
}

private extension JSONEncoder {
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
