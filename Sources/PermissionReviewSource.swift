import Foundation

struct PermissionReviewPresented: Equatable {
    let conversationID: String
    let reviewID: String
}

struct PermissionToolStarted: Equatable {
    let conversationID: String
    let toolCallID: String
}

/// Extracts the permission-review lifecycle that is rendered by Doubao's native
/// ask-human confirmation UI. The UI creates one iframe per action button, so
/// both buttons intentionally collapse to the timestamp component shared by the
/// request IDs.
struct PermissionReviewSource {
    private static let reviewTimestampRegex = try! NSRegularExpression(
        pattern: #"requestId=common-ask-human-action-button-([0-9]+)-[a-z0-9]+"#
    )
    private static let conversationRegex = try! NSRegularExpression(
        pattern: #"(?:last_committed_url|web_contents URL): (?:doubao|chrome)://doubao-chat/chat/([0-9]+)"#
    )
    private static let toolStartRegex = try! NSRegularExpression(
        pattern: #"\[lid=\{\"conversation_id\":\"([0-9]+)\".*?\"tcid\":\"([0-9a-f-]{36})\"\}\].*?\[sandbox\] operator\(\) \S+ enter "#
    )

    static func reviewPresented(in line: String) -> PermissionReviewPresented? {
        guard line.contains("DidStartNavigation chat_page_navigate_event"),
              line.contains("agent-confirm_09_10_1.html"),
              line.contains("common-ask-human-action-button-") else { return nil }
        guard let timestamp = firstCapture(reviewTimestampRegex, in: line),
              let conversationID = firstCapture(conversationRegex, in: line) else { return nil }
        return PermissionReviewPresented(
            conversationID: conversationID,
            reviewID: "permission-review-\(timestamp)"
        )
    }

    static func toolStarted(in line: String) -> PermissionToolStarted? {
        guard line.contains("[sandbox] operator()"), line.contains(" enter ") else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let result = toolStartRegex.firstMatch(in: line, range: range),
              result.numberOfRanges == 3,
              let conversationRange = Range(result.range(at: 1), in: line),
              let toolCallRange = Range(result.range(at: 2), in: line) else { return nil }
        return PermissionToolStarted(
            conversationID: String(line[conversationRange]),
            toolCallID: String(line[toolCallRange])
        )
    }

    private static func firstCapture(_ regex: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let result = regex.firstMatch(in: line, range: range),
              result.numberOfRanges >= 2,
              let capture = Range(result.range(at: 1), in: line) else { return nil }
        return String(line[capture])
    }
}
