import Foundation

enum CanonicalEventKind: String, Codable {
    case runStarted
    case runBlockerEnded
    case interactionWaiting
    case interactionResolved
    case assistantActivity
}

struct CanonicalEvent: Equatable {
    let kind: CanonicalEventKind
    let conversationID: String
    let source: String
    var runID: String? = nil
    var blockerID: String? = nil
    var interactionID: String? = nil
    var waitingTool: String? = nil
}

struct TrajectoryInteractionCall: Equatable {
    let id: String
    let tool: String
}

struct PendingNativeInteraction: Codable, Equatable {
    let sandboxID: String
    let interactionID: String
    let waitingTool: String
    let receivedAt: TimeInterval
    var settledAt: TimeInterval?
    var provisionalConversationID: String?
    var candidateConversationIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case sandboxID, interactionID, waitingTool, receivedAt, settledAt
        case provisionalConversationID, candidateConversationIDs
    }

    init(
        sandboxID: String,
        interactionID: String,
        waitingTool: String,
        receivedAt: TimeInterval,
        settledAt: TimeInterval?,
        provisionalConversationID: String?,
        candidateConversationIDs: [String]
    ) {
        self.sandboxID = sandboxID
        self.interactionID = interactionID
        self.waitingTool = waitingTool
        self.receivedAt = receivedAt
        self.settledAt = settledAt
        self.provisionalConversationID = provisionalConversationID
        self.candidateConversationIDs = candidateConversationIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sandboxID = try values.decode(String.self, forKey: .sandboxID)
        interactionID = try values.decode(String.self, forKey: .interactionID)
        waitingTool = try values.decode(String.self, forKey: .waitingTool)
        receivedAt = try values.decode(TimeInterval.self, forKey: .receivedAt)
        settledAt = try values.decodeIfPresent(TimeInterval.self, forKey: .settledAt)
        provisionalConversationID = try values.decodeIfPresent(String.self, forKey: .provisionalConversationID)
        candidateConversationIDs = try values.decodeIfPresent([String].self, forKey: .candidateConversationIDs) ?? []
    }
}

struct EventResolverState: Codable, Equatable {
    var sandboxConversations: [String: String] = [:]
    var pendingNativeInteractions: [String: PendingNativeInteraction] = [:]
    var settledInteractionIDs: [String: TimeInterval] = [:]

    private enum CodingKeys: String, CodingKey {
        case sandboxConversations, pendingNativeInteractions, settledInteractionIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sandboxConversations = try values.decodeIfPresent([String: String].self, forKey: .sandboxConversations) ?? [:]
        pendingNativeInteractions = try values.decodeIfPresent([String: PendingNativeInteraction].self, forKey: .pendingNativeInteractions) ?? [:]
        settledInteractionIDs = try values.decodeIfPresent([String: TimeInterval].self, forKey: .settledInteractionIDs) ?? [:]
    }
}

struct EventResolver {
    private(set) var state: EventResolverState

    init(state: EventResolverState = EventResolverState()) {
        self.state = state
    }

    mutating func replaceState(_ newState: EventResolverState) {
        state = newState
    }

    mutating func recordSandboxMapping(
        sandboxID: String,
        conversationID: String,
        source: String
    ) -> [CanonicalEvent] {
        state.sandboxConversations[sandboxID] = conversationID
        var events: [CanonicalEvent] = []
        let pending = state.pendingNativeInteractions.values
            .filter { $0.sandboxID == sandboxID }
            .sorted { $0.receivedAt < $1.receivedAt }
        for interaction in pending {
            state.pendingNativeInteractions.removeValue(forKey: interaction.interactionID)
            guard interaction.settledAt == nil else { continue }
            if let provisional = interaction.provisionalConversationID {
                if provisional == conversationID { continue }
                events.append(CanonicalEvent(
                    kind: .interactionResolved,
                    conversationID: provisional,
                    source: "resolver:provisional_migration",
                    interactionID: interaction.interactionID
                ))
            }
            events.append(CanonicalEvent(
                kind: .interactionWaiting,
                conversationID: conversationID,
                source: source,
                interactionID: interaction.interactionID,
                waitingTool: interaction.waitingTool
            ))
        }
        return events
    }

    mutating func ingestNativeReceived(
        sandboxID: String,
        interactionID: String,
        waitingTool: String,
        receivedAt: TimeInterval,
        source: String,
        provisionalConversationID: String? = nil,
        candidateConversationIDs: [String] = []
    ) -> [CanonicalEvent] {
        guard state.settledInteractionIDs[interactionID] == nil else { return [] }
        if let conversationID = state.sandboxConversations[sandboxID] {
            return [CanonicalEvent(
                kind: .interactionWaiting,
                conversationID: conversationID,
                source: source,
                interactionID: interactionID,
                waitingTool: waitingTool
            )]
        }
        if state.pendingNativeInteractions[interactionID] == nil {
            state.pendingNativeInteractions[interactionID] = PendingNativeInteraction(
                sandboxID: sandboxID,
                interactionID: interactionID,
                waitingTool: waitingTool,
                receivedAt: receivedAt,
                settledAt: nil,
                provisionalConversationID: provisionalConversationID,
                candidateConversationIDs: candidateConversationIDs
            )
        }
        guard let provisionalConversationID else { return [] }
        return [CanonicalEvent(
            kind: .interactionWaiting,
            conversationID: provisionalConversationID,
            source: "resolver:single_active_run",
            interactionID: interactionID,
            waitingTool: waitingTool
        )]
    }

    mutating func ingestNativeSettled(
        sandboxID: String,
        interactionID: String,
        settledAt: TimeInterval,
        source: String
    ) -> [CanonicalEvent] {
        state.settledInteractionIDs[interactionID] = settledAt
        if let conversationID = state.sandboxConversations[sandboxID] {
            state.pendingNativeInteractions.removeValue(forKey: interactionID)
            return [CanonicalEvent(
                kind: .interactionResolved,
                conversationID: conversationID,
                source: source,
                interactionID: interactionID
            )]
        }
        if var pending = state.pendingNativeInteractions[interactionID] {
            pending.settledAt = settledAt
            state.pendingNativeInteractions[interactionID] = pending
            if let provisional = pending.provisionalConversationID {
                return [CanonicalEvent(
                    kind: .interactionResolved,
                    conversationID: provisional,
                    source: "resolver:provisional_settled",
                    interactionID: interactionID
                )]
            }
        }
        return []
    }

    mutating func ingestTrajectory(
        conversationID: String,
        calls: [TrajectoryInteractionCall],
        results: Set<String>,
        sawAssistantActivity: Bool,
        source: String
    ) -> [CanonicalEvent] {
        var events: [CanonicalEvent] = []
        if sawAssistantActivity {
            events.append(CanonicalEvent(
                kind: .assistantActivity,
                conversationID: conversationID,
                source: source
            ))
        }

        for interactionID in results.sorted() {
            state.settledInteractionIDs[interactionID] = Date().timeIntervalSince1970
            if let pending = state.pendingNativeInteractions.removeValue(forKey: interactionID) {
                state.sandboxConversations[pending.sandboxID] = conversationID
                if let provisional = pending.provisionalConversationID, provisional != conversationID {
                    events.append(CanonicalEvent(
                        kind: .interactionResolved,
                        conversationID: provisional,
                        source: "resolver:provisional_migration",
                        interactionID: interactionID
                    ))
                }
            }
            events.append(CanonicalEvent(
                kind: .interactionResolved,
                conversationID: conversationID,
                source: source,
                interactionID: interactionID
            ))
        }

        for call in calls where !results.contains(call.id) {
            var eventSource = source
            if let pending = state.pendingNativeInteractions.removeValue(forKey: call.id) {
                state.sandboxConversations[pending.sandboxID] = conversationID
                guard pending.settledAt == nil else { continue }
                if let provisional = pending.provisionalConversationID {
                    if provisional == conversationID { continue }
                    events.append(CanonicalEvent(
                        kind: .interactionResolved,
                        conversationID: provisional,
                        source: "resolver:provisional_migration",
                        interactionID: call.id
                    ))
                }
                eventSource = "resolver:native+trajectory"
            }
            events.append(CanonicalEvent(
                kind: .interactionWaiting,
                conversationID: conversationID,
                source: eventSource,
                interactionID: call.id,
                waitingTool: call.tool
            ))
        }
        return events
    }

    mutating func prune(now: TimeInterval, unresolvedTTL: TimeInterval = 24 * 60 * 60, settledTTL: TimeInterval = 10 * 60) {
        state.pendingNativeInteractions = state.pendingNativeInteractions.filter { _, pending in
            let reference = pending.settledAt ?? pending.receivedAt
            let ttl = pending.settledAt == nil ? unresolvedTTL : settledTTL
            return now - reference <= ttl
        }
        state.settledInteractionIDs = state.settledInteractionIDs.filter { now - $0.value <= settledTTL }
    }

    func hasRecentUnresolvedCandidate(conversationID: String, now: TimeInterval, hold: TimeInterval) -> Bool {
        state.pendingNativeInteractions.values.contains { pending in
            pending.settledAt == nil &&
            pending.provisionalConversationID == nil &&
            pending.candidateConversationIDs.contains(conversationID) &&
            now - pending.receivedAt < hold
        }
    }
}
