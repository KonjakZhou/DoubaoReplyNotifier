import Foundation

func uuidBytes(_ value: String) -> Data { Data(value.utf8) }

func makeRecord(agentID: String, interactionID: String) -> Data {
    var data = Data(repeating: 0x41, count: 200)
    data.append(Data("dbx_ic:".utf8))
    data.append(Data(repeating: 0x42, count: 40))
    data.append(uuidBytes(interactionID))
    data.append(Data("\"questions:required:capability:allow:".utf8))
    data.append(Data(repeating: 0x43, count: 700))
    data.append(Data("/agents/\(agentID)/system/".utf8))
    data.append(Data(repeating: 0x44, count: 100))
    return data
}

let a = "87690c56-b0e4-4207-8438-ad98f1074610"
let b = "061f5e83-8210-4c9a-84f1-8851fc163bb7"
var fixture = makeRecord(agentID: "m_primary", interactionID: a)
fixture.append(Data(repeating: 0x58, count: 100_000))
fixture.append(makeRecord(agentID: "m_secondary", interactionID: b))
// Duplicate physical copy must collapse to one logical event.
fixture.append(makeRecord(agentID: "m_primary", interactionID: a))
// UUID without the interaction signature must not be detected.
fixture.append(Data("dbx_ic:".utf8))
fixture.append(Data("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".utf8))

let events = Set(IndexedDBInteractionReader.waitingEvents(
    in: fixture,
    agentConversations: [
        "m_primary": "90000000000000001",
        "m_secondary": "90000000000000002"
    ]
))
precondition(events.count == 2, "expected two unique interactions: \(events)")
precondition(events.contains(IndexedDBWaitingEvent(conversationID: "90000000000000001", interactionID: a)))
precondition(events.contains(IndexedDBWaitingEvent(conversationID: "90000000000000002", interactionID: b)))
print("{\"indexeddb_interactions\":2,\"duplicate_collapsed\":true,\"agent_mapping\":true}")
