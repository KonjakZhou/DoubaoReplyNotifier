import Foundation

// Persisted native identity, not renderer/DOM state. Both aliases and sessions are
// scoped by product; temporary IDs additionally include the client process epoch.
struct NativeRound: Codable, Equatable {
    let conversationID: String
    let product: String
    let sessionID: String
    let queryTimestamp: Double
    let runID: String
    var ended: Bool
}
struct NativeRoundState: Codable {
    var aliases: [String: String] = [:]
    var rounds: [String: NativeRound] = [:]
}
struct WaitingOwnership: Codable {
    var runID: String
    let product: String
    let receivedAt: Double
    let source: String
}
struct NativeRoundSignal {
    let round: NativeRound
    let localID: String?
    let isEnd: Bool
}

enum NativeRoundSource {
    static func key(product: String, conversationID: String) -> String { product + "|" + conversationID }
    static func epoch(_ line: String) -> String {
        let pattern = #"^\[([0-9]+):"#
        return captures(pattern, line)?.first ?? "test"
    }
    static func aliasKey(product: String, line: String, localID: String) -> String {
        product + "|" + epoch(line) + "|" + localID
    }
    static func captures(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { i in
            Range(match.range(at: i), in: line).map { String(line[$0]) }
        }
    }
    static func numeric(_ id: String) -> Bool { !id.isEmpty && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    static func temporary(_ id: String) -> Bool { id.hasPrefix("local_") && numeric(String(id.dropFirst(6))) }

    // Decode one balanced JSON object only from the client's structured logger.
    // Never search arbitrary tool output or snippets for lifecycle words.
    static func signal(in line: String, product: String) -> NativeRoundSignal? {
        guard line.contains("[office-api-logger]"), let marker = line.range(of: "[logifier-report]: ") else { return nil }
        let text = line[marker.upperBound...]
        guard text.first == "{" else { return nil }
        var depth = 0, quoted = false, escaped = false
        var end: String.Index?
        for i in text.indices {
            let c = text[i]
            if quoted {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = text.index(after: i); break } }
        }
        guard let end, let data = String(text[..<end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] as? Int == 1, object["type"] as? String == "event",
              let event = object["eventName"] as? String,
              event == "on_message_receiving_start" || event == "on_message_session_end",
              let meta = object["meta"] as? [String: Any],
              meta["page_role"] as? String == "mainagent", meta["mode_type"] as? String == "work_task",
              let cid = meta["conversation_id"] as? String, numeric(cid),
              let session = meta["chat_session_id"] as? String, UUID(uuidString: session) != nil,
              let timestamp = meta["query_send_timestamp"] as? NSNumber,
              CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue > 0 else { return nil }
        let isEnd = event == "on_message_session_end"
        if isEnd {
            guard meta["lifecycle_state"] as? String == "session: SyncMessageReceivingStage, message:MessageEnd",
                  meta["agent_error"] as? String == "0", meta["cancel_source"] as? String == "" else { return nil }
        }
        let local = (meta["local_conversation_id"] as? String).flatMap { temporary($0) ? $0 : nil }
        let runID = "native|\(product)|\(cid)|\(session)|\(timestamp.stringValue)"
        return NativeRoundSignal(round: NativeRound(conversationID: cid, product: product, sessionID: session,
            queryTimestamp: timestamp.doubleValue, runID: runID, ended: isEnd), localID: local, isEnd: isEnd)
    }

    // Navigation only establishes identity, never completion or loading state.
    static func navigationAlias(in line: String) -> (local: String, conversation: String)? {
        guard line.contains("chat_page_navigate_event"),
              let pair = captures(#"url: (?:chrome|doubaowork|doubao)://(?:doubaowork|doubao)-chat/chat/([0-9]+), last_committed_url: (?:chrome|doubaowork|doubao)://(?:doubaowork|doubao)-chat/chat/(local_[0-9]+),"#, line), pair.count == 2 else { return nil }
        return (pair[1], pair[0])
    }

    private static let orderRegex = try? NSRegularExpression(pattern: #"\[[0-9]+:[0-9]+:([0-9]{4}/[0-9]{6}\.[0-9]+):"#)
    static func order(in line: String) -> String {
        guard let regex = orderRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range(at: 1), in: line) else { return "" }
        return String(line[range])
    }
}
