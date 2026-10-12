import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import UserNotifications

private struct PersistedNotifierState: Codable {
    var version = 4
    var processedEvents: [String: String] = [:]
    var trajectoryOffsets: [String: UInt64] = [:]
    var runtimeLogOffsets: [String: UInt64] = [:]
    var conversationTitles: [String: String] = [:]
    var activeRunIDs: [String: String] = [:]
    var activeInterceptors: [String: [String: String]] = [:]
    var terminalRuns: [String: String] = [:]
    var lastEventSource = ""
    var lastEventType = ""
    var conversationTitle = ""
    var lastEventID = ""
    var lastEventAt = ""
}

private struct TrajectoryRecord: Decodable {
    struct ToolCall: Decodable {
        struct Function: Decodable { let name: String? }
        let function: Function?
    }
    let role: String?
    let tool_calls: [ToolCall]?
}

private struct MainAgentWatch {
    let conversationID: String
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
    private let conversationTitleReader = ConversationTitleReader()
    private let maxProcessedEvents = 4000
    private let processedEventTTL: TimeInterval = 7 * 24 * 60 * 60
    private let completionGraceSeconds: TimeInterval = 3.0
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
        loadState()
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
        // 只处理带受控 action 标记的通知；其它 App 的通知一律放行并恰好一次回调。
        let userInfo = response.notification.request.content.userInfo
        guard let marker = userInfo[Self.actionMarkerKey] as? String,
              marker == Self.actionMarkerValue else {
            completionHandler()
            return
        }
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, Self.activateActionIdentifier:
            // 默认点击（通知主体）或显式“打开豆包”按钮 → 激活/启动豆包主应用。
            activateDoubaoApp(completion: completionHandler)
        case UNNotificationDismissActionIdentifier:
            // 划掉/关闭：不做任何事，仅结束。
            completionHandler()
        default:
            NSLog("ACTIVATE_IGNORED_ACTION id=%@", response.actionIdentifier)
            completionHandler()
        }
    }

    private func activateDoubaoApp(completion: @escaping () -> Void) {
        let workspace = NSWorkspace.shared
        // 1) 已运行：按 Bundle ID 找到主应用并激活其所有窗口。
        if let running = workspace.runningApplications.first(where: { $0.bundleIdentifier == Self.targetBundleID }) {
            // 同步激活主应用及其所有窗口；返回值表示请求是否成功发出。
            let success = running.activate(from: .current,
                                           options: [.activateAllWindows])
            if !success {
                recordActivationError(
                    stage: "activate_running",
                    reason: "activate_returned_false",
                    detail: "bundleID=\(Self.targetBundleID) pid=\(running.processIdentifier)"
                )
            }
            completion()
            return
        }
        // 2) 未运行：按 Bundle ID 定位应用。
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: Self.targetBundleID) else {
            recordActivationError(
                stage: "locate",
                reason: "bundle_id_not_found",
                detail: "bundleID=\(Self.targetBundleID)"
            )
            completion()
            return
        }
        // 3) 校验解析结果：先显式挡掉 browser helper，再做精确相等校验。
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
        // 4) 启动并激活。
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            guard let self else { completion(); return }
            if let error {
                self.recordActivationError(
                    stage: "launch",
                    reason: "open_application_failed",
                    detail: "bundleID=\(resolvedID) url=\(appURL.path) error=\(error.localizedDescription)"
                )
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
                    result.append(MainAgentWatch(conversationID: conversationID, trajectoryURL: trajectoryURL, assignmentURL: assignmentURL))
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
        changed = scanTrajectories() || changed
        if changed { _ = saveState() }
        updateMenu("监听中 · \(watchesByPath.count) 个会话")
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
        if let match = firstMatch(registerRegex, line), match.count == 3 {
            let interceptID = match[0]
            let conversationID = match[1]
            let sequence = match[2]
            let runID: String
            if let existingRunID = persistedState.activeRunIDs[conversationID] {
                runID = existingRunID
            } else {
                runID = "runtime|\(conversationID)|\(sequence)|\(sha256(line))"
                persistedState.activeRunIDs[conversationID] = runID
                persistedState.terminalRuns.removeValue(forKey: runID)
            }
            var interceptors = persistedState.activeInterceptors[conversationID] ?? [:]
            interceptors[interceptID] = runID
            persistedState.activeInterceptors[conversationID] = interceptors
            if let pending = pendingCompletions.removeValue(forKey: conversationID) { pending.timer.invalidate() }
            return
        }
        if let match = firstMatch(unregisterRegex, line), match.count == 2 {
            let interceptID = match[0]
            let conversationID = match[1]
            guard var interceptors = persistedState.activeInterceptors[conversationID],
                  let runID = interceptors.removeValue(forKey: interceptID) else { return }
            persistedState.activeInterceptors[conversationID] = interceptors
            guard interceptors.isEmpty, persistedState.activeRunIDs[conversationID] == runID else { return }
            if scheduleTerminals {
                scheduleCompletion(conversationID: conversationID, runID: runID)
            } else {
                persistedState.activeRunIDs.removeValue(forKey: conversationID)
                persistedState.activeInterceptors.removeValue(forKey: conversationID)
            }
        }
    }

    private func scheduleCompletion(conversationID: String, runID: String) {
        if persistedState.terminalRuns[runID] != nil { return }
        if let pending = pendingCompletions.removeValue(forKey: conversationID) { pending.timer.invalidate() }
        let timer = Timer.scheduledTimer(withTimeInterval: completionGraceSeconds, repeats: false) { [weak self] _ in
            guard let self,
                  self.persistedState.activeRunIDs[conversationID] == runID,
                  (self.persistedState.activeInterceptors[conversationID] ?? [:]).isEmpty,
                  self.persistedState.terminalRuns[runID] == nil else { return }
            self.pendingCompletions.removeValue(forKey: conversationID)
            self.persistedState.activeRunIDs.removeValue(forKey: conversationID)
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

    private func processTrajectory(chunk: String, watch: MainAgentWatch) {
        for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(TrajectoryRecord.self, from: data),
                  record.role == "assistant" else { continue }
            let toolNames = Set((record.tool_calls ?? []).compactMap { $0.function?.name })
            guard let waitingTool = toolNames.first(where: { waitingTools.contains($0) }) else { continue }
            let runID = persistedState.activeRunIDs[watch.conversationID] ?? "trajectory|\(sha256(line))"
            if let pending = pendingCompletions.removeValue(forKey: watch.conversationID) { pending.timer.invalidate() }
            persistedState.terminalRuns[runID] = "waiting_user"
            persistedState.activeRunIDs.removeValue(forKey: watch.conversationID)
            persistedState.activeInterceptors.removeValue(forKey: watch.conversationID)
            emitTerminal(type: "waiting_user", conversationID: watch.conversationID, runID: runID, source: "trajectory:\(waitingTool)")
        }
    }

    private func emitTerminal(type: String, conversationID: String, runID: String, source: String) {
        let eventID = "\(conversationID)|\(type)|\(sha256(runID))"
        guard persistedState.processedEvents[eventID] == nil else { return }
        let title: String
        if let currentTitle = conversationTitleReader.title(conversationID: conversationID, doubaoDataRoot: doubaoDataRoot) {
            title = currentTitle
            persistedState.conversationTitles[conversationID] = currentTitle
        } else {
            title = persistedState.conversationTitles[conversationID] ?? "豆包工作"
        }
        let body = type == "waiting_user" ? "等待你确认或提供信息" : "当前对话轮次回复完成"
        persistedState.processedEvents[eventID] = ISO8601DateFormatter().string(from: Date())
        persistedState.terminalRuns[runID] = type
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
        persistedState = decoded.version == 4 ? decoded : PersistedNotifierState()
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
