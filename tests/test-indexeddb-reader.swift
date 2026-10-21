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
        // The historical fixture has empty/null structured local_conversation_id.
        // A byte-neighbourhood match used to invent ownership; strict parsing must reject it.
        precondition(events.isEmpty, "unowned fixture must not invent a conversation: \(events)")
        let payload = "{\"tool_call_id\":\"12345678-1234-1234-1234-123456789abc\",\"sandbox_id\":\"sandbox-fixture\"}"
        let item: V8TitleValue = .object([
            "schema_payload": .string(payload),
            "extra_params": .object(["pc_native_may_involve": .string("1")])
        ])
        let root: V8TitleValue = .object([
            "extra": .object([
                "local_conversation_id": .string("90000000000000011"),
                "content_blocks_v2": .array([.object(["quick_reply_block": .object(["items": .array([item])])])])
            ])
        ])
        precondition(IndexedDBInteractionReader.structuredWaitingEvents(root: root, allowed: ["90000000000000011"]) == [expected])
        let textOnly: V8TitleValue = .object(["local_conversation_id": .string("90000000000000011"), "content": .string("quick_reply_block schema_payload tool_call_id approve " + payload)])
        precondition(IndexedDBInteractionReader.structuredWaitingEvents(root: textOnly, allowed: ["90000000000000011"]).isEmpty)
        precondition(IndexedDBInteractionReader.structuredWaitingEvents(root: root, allowed: ["90000000000000012"]).isEmpty)

        // User/assistant text can contain old tool IDs and parser source. Those bytes must not
        // become events because they are outside schema_payload -> tool_call.
        precondition(!events.contains(where: { $0.interactionID.hasPrefix("aaaaaaaa") }))
        precondition(!events.contains(where: { $0.interactionID.hasPrefix("bbbbbbbb") }))

        // A structurally valid schema_payload -> tool_call without an explicit supported
        // waiting marker is an ordinary/unknown tool record, not request_action.
        let unknownID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let unknownValue = Data((
            "local_conversation_id90000000000000011" +
            "schema_payload ordinary_tool tool_call " + unknownID
        ).utf8)
        let unknownWAL = makeWAL(value: unknownValue)
        let unknownEvents = IndexedDBInteractionReader.waitingEvents(
            inWAL: unknownWAL,
            agentConversations: ["m_fixture": "90000000000000011"]
        )
        precondition(unknownEvents.isEmpty, "unknown structured tool must not default to request_action: \(unknownEvents)")
        print("{\"unowned_real_fixture_rejected\":true,\"owned_authorize_object_accepted\":true,\"unknown_structured_tools_ignored\":true,\"text_uuid_false_positives\":0}")
    }

    private static func makeWAL(value: Data) -> Data {
        func varint(_ number: Int) -> Data {
            var value = number
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return Data(bytes)
        }
        var batch = Data(repeating: 0, count: 8)
        batch.append(contentsOf: [1, 0, 0, 0])
        batch.append(1)
        batch.append(varint(1))
        batch.append(Data("k".utf8))
        batch.append(varint(value.count))
        batch.append(value)

        var record = Data(repeating: 0, count: 4)
        record.append(UInt8(batch.count & 0xff))
        record.append(UInt8((batch.count >> 8) & 0xff))
        record.append(1)
        record.append(batch)
        return record
    }
}
