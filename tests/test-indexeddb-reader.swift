import Foundation

@main
struct IndexedDBReaderTest {
    static func main() throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: fixtureURL)
        let events = Set(IndexedDBInteractionReader.waitingEvents(
            inWAL: data,
            agentConversations: ["m_fixture": "90000000000000011"]
        ))
        let expected = IndexedDBWaitingEvent(
            conversationID: "90000000000000011",
            interactionID: "12345678-1234-1234-1234-123456789abc",
            kind: "authorize"
        )
        precondition(events == [expected], "unexpected real-WAL events: \(events)")

        // User/assistant text can contain old tool IDs and parser source. Those bytes must not
        // become events because they are outside schema_payload -> tool_call.
        precondition(!events.contains(where: { $0.interactionID.hasPrefix("aaaaaaaa") }))
        precondition(!events.contains(where: { $0.interactionID.hasPrefix("bbbbbbbb") }))
        print("{\"real_wal_fixture\":true,\"authorize_interactions\":1,\"text_uuid_false_positives\":0}")
    }
}
