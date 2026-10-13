import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func waiting(_ events: [CanonicalEvent], conversation: String, interaction: String) -> Bool {
    events.contains { $0.kind == .interactionWaiting && $0.conversationID == conversation && $0.interactionID == interaction }
}

private func resolved(_ events: [CanonicalEvent], conversation: String, interaction: String) -> Bool {
    events.contains { $0.kind == .interactionResolved && $0.conversationID == conversation && $0.interactionID == interaction }
}

@main
struct EventResolverTests {
static func main() {
// 1. 已知映射：原生 received 即时归属。
do {
    var resolver = EventResolver()
    _ = resolver.recordSandboxMapping(sandboxID: "sandbox-a", conversationID: "c1", source: "test")
    let events = resolver.ingestNativeReceived(
        sandboxID: "sandbox-a", interactionID: "i1", waitingTool: "interaction.ask",
        receivedAt: 1, source: "native"
    )
    require(waiting(events, conversation: "c1", interaction: "i1"), "known mapping must emit waiting")
}

// 2. 映射晚到：received 先缓存，映射到达后只回放一次。
do {
    var resolver = EventResolver()
    let before = resolver.ingestNativeReceived(
        sandboxID: "sandbox-b", interactionID: "i2", waitingTool: "interaction.authorize_folder",
        receivedAt: 2, source: "native"
    )
    require(before.isEmpty, "unmapped native event must be buffered")
    let replay = resolver.recordSandboxMapping(sandboxID: "sandbox-b", conversationID: "c2", source: "mapping")
    require(replay.count == 1 && waiting(replay, conversation: "c2", interaction: "i2"), "late mapping must replay exactly once")
    let duplicate = resolver.recordSandboxMapping(sandboxID: "sandbox-b", conversationID: "c2", source: "mapping")
    require(duplicate.isEmpty, "replayed event must be removed from resolver")
}

// 3. trajectory 兜底：缺少原生日志映射时，通过 tool_call_id 归属并学习 sandbox 映射。
do {
    var resolver = EventResolver()
    _ = resolver.ingestNativeReceived(
        sandboxID: "sandbox-c", interactionID: "i3", waitingTool: "interaction.request_action",
        receivedAt: 3, source: "native"
    )
    let events = resolver.ingestTrajectory(
        conversationID: "c3",
        calls: [TrajectoryInteractionCall(id: "i3", tool: "interaction.request_action")],
        results: [], sawAssistantActivity: true, source: "trajectory"
    )
    require(waiting(events, conversation: "c3", interaction: "i3"), "trajectory must resolve missing mapping")
    require(resolver.state.sandboxConversations["sandbox-c"] == "c3", "trajectory resolution must persist sandbox mapping")
}

// 4. 单活跃 run 临时归属正确：trajectory 确认同会话时不重复 waiting。
do {
    var resolver = EventResolver()
    let early = resolver.ingestNativeReceived(
        sandboxID: "sandbox-d", interactionID: "i4", waitingTool: "interaction.ask",
        receivedAt: 4, source: "native", provisionalConversationID: "c4"
    )
    require(waiting(early, conversation: "c4", interaction: "i4"), "single active run must permit low-latency provisional waiting")
    let confirmed = resolver.ingestTrajectory(
        conversationID: "c4", calls: [TrajectoryInteractionCall(id: "i4", tool: "interaction.ask")],
        results: [], sawAssistantActivity: true, source: "trajectory"
    )
    require(!confirmed.contains { $0.kind == .interactionWaiting }, "same-conversation confirmation must not duplicate waiting")
}

// 5. 临时归属错误：trajectory 必须先解除旧会话，再迁移到权威会话。
do {
    var resolver = EventResolver()
    _ = resolver.ingestNativeReceived(
        sandboxID: "sandbox-e", interactionID: "i5", waitingTool: "interaction.ask",
        receivedAt: 5, source: "native", provisionalConversationID: "wrong"
    )
    let migrated = resolver.ingestTrajectory(
        conversationID: "right", calls: [TrajectoryInteractionCall(id: "i5", tool: "interaction.ask")],
        results: [], sawAssistantActivity: true, source: "trajectory"
    )
    require(resolved(migrated, conversation: "wrong", interaction: "i5"), "migration must clear provisional conversation")
    require(waiting(migrated, conversation: "right", interaction: "i5"), "migration must register authoritative conversation")
}

// 6. 未映射但已有临时归属时收到 settled，应立即解除等待且不产生陈旧回放。
do {
    var resolver = EventResolver()
    _ = resolver.ingestNativeReceived(
        sandboxID: "sandbox-f", interactionID: "i6", waitingTool: "interaction.ask",
        receivedAt: 6, source: "native", provisionalConversationID: "c6"
    )
    let settled = resolver.ingestNativeSettled(
        sandboxID: "sandbox-f", interactionID: "i6", settledAt: 7, source: "native"
    )
    require(resolved(settled, conversation: "c6", interaction: "i6"), "settled must clear provisional waiting")
    let lateMapping = resolver.recordSandboxMapping(sandboxID: "sandbox-f", conversationID: "c6", source: "mapping")
    require(lateMapping.isEmpty, "settled event must never replay as stale waiting")
}

// 7. 同批 call + result：不发送 waiting，只发送 resolved。
do {
    var resolver = EventResolver()
    let events = resolver.ingestTrajectory(
        conversationID: "c7", calls: [TrajectoryInteractionCall(id: "i7", tool: "interaction.ask")],
        results: ["i7"], sawAssistantActivity: true, source: "trajectory"
    )
    require(!events.contains { $0.kind == .interactionWaiting }, "same-batch result must suppress waiting")
    require(resolved(events, conversation: "c7", interaction: "i7"), "same-batch result must retain resolved event")
}

// 8. 跨会话隔离：两个 sandbox 映射不能串线。
do {
    var resolver = EventResolver()
    _ = resolver.recordSandboxMapping(sandboxID: "sandbox-g1", conversationID: "c8a", source: "test")
    _ = resolver.recordSandboxMapping(sandboxID: "sandbox-g2", conversationID: "c8b", source: "test")
    let first = resolver.ingestNativeReceived(
        sandboxID: "sandbox-g1", interactionID: "i8a", waitingTool: "interaction.ask",
        receivedAt: 8, source: "native"
    )
    let second = resolver.ingestNativeReceived(
        sandboxID: "sandbox-g2", interactionID: "i8b", waitingTool: "interaction.ask",
        receivedAt: 8, source: "native"
    )
    require(waiting(first, conversation: "c8a", interaction: "i8a"), "first sandbox must stay in first conversation")
    require(waiting(second, conversation: "c8b", interaction: "i8b"), "second sandbox must stay in second conversation")
}

// 9. 持久化恢复：resolver state 编解码后保留未归属事件。
do {
    var resolver = EventResolver()
    _ = resolver.ingestNativeReceived(
        sandboxID: "sandbox-h", interactionID: "i9", waitingTool: "interaction.ask",
        receivedAt: 9, source: "native"
    )
    let data = try! JSONEncoder().encode(resolver.state)
    let decoded = try! JSONDecoder().decode(EventResolverState.self, from: data)
    var restored = EventResolver(state: decoded)
    let events = restored.recordSandboxMapping(sandboxID: "sandbox-h", conversationID: "c9", source: "mapping")
    require(waiting(events, conversation: "c9", interaction: "i9"), "restored resolver must replay buffered event")
}

// 10. TTL：已 settled 的未知事件短 TTL 清理，未 settled 的事件保留更久。
do {
    var resolver = EventResolver()
    _ = resolver.ingestNativeReceived(
        sandboxID: "sandbox-i", interactionID: "i10", waitingTool: "interaction.ask",
        receivedAt: 0, source: "native"
    )
    _ = resolver.ingestNativeSettled(sandboxID: "sandbox-i", interactionID: "i10", settledAt: 1, source: "native")
    resolver.prune(now: 700, unresolvedTTL: 1000, settledTTL: 600)
    require(resolver.state.pendingNativeInteractions["i10"] == nil, "settled pending event must expire on short TTL")
    require(resolver.state.settledInteractionIDs["i10"] == nil, "settled tombstone must expire on short TTL")
}

// 11. settled 先到：迟到 received 必须被 tombstone 抑制。
do {
    var resolver = EventResolver()
    let settled = resolver.ingestNativeSettled(
        sandboxID: "sandbox-j", interactionID: "i11", settledAt: 11, source: "native"
    )
    require(settled.isEmpty, "unmapped settled may wait without emitting")
    let lateReceived = resolver.ingestNativeReceived(
        sandboxID: "sandbox-j", interactionID: "i11", waitingTool: "interaction.ask",
        receivedAt: 12, source: "native", provisionalConversationID: "c11", candidateConversationIDs: ["c11"]
    )
    require(lateReceived.isEmpty, "late received after settled must be suppressed")
}

// 12. 多活跃会话：不临时归属，但仅候选会话受短期完成门禁影响。
do {
    var resolver = EventResolver()
    let events = resolver.ingestNativeReceived(
        sandboxID: "sandbox-k", interactionID: "i12", waitingTool: "interaction.ask",
        receivedAt: 12, source: "native", provisionalConversationID: nil,
        candidateConversationIDs: ["c12a", "c12b"]
    )
    require(events.isEmpty, "multiple active runs must not guess a conversation")
    require(resolver.hasRecentUnresolvedCandidate(conversationID: "c12a", now: 13, hold: 5), "first candidate must be held")
    require(resolver.hasRecentUnresolvedCandidate(conversationID: "c12b", now: 13, hold: 5), "second candidate must be held")
    require(!resolver.hasRecentUnresolvedCandidate(conversationID: "other", now: 13, hold: 5), "unrelated conversation must not be held")
}

print("{\"event_resolver_cases\":12,\"late_mapping\":true,\"trajectory_fallback\":true,\"provisional_migration\":true,\"settled_before_received\":true,\"multi_run_isolation\":true,\"persistence\":true}")
}
}
