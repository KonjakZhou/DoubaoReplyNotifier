import Foundation

struct IndexedDBWaitingEvent: Hashable {
    let conversationID: String
    let interactionID: String
    let kind: String
}

struct IndexedDBInteractionReader {
    private let fileManager: FileManager
    private static let levelDBBlockSize = 32 * 1024

    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    private static let chatDatabaseDirectoryNames = [
        "chrome_doubaowork-chat_0.indexeddb.leveldb",
        "chrome_doubao-chat_0.indexeddb.leveldb"
    ]

    func databaseFiles(doubaoDataRoot: URL) -> [URL] {
        guard let profiles = try? fileManager.contentsOfDirectory(
            at: doubaoDataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return profiles
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .flatMap { profileURL -> [URL] in
                Self.chatDatabaseDirectoryNames.flatMap { directoryName -> [URL] in
                    let databaseURL = profileURL.appendingPathComponent(
                        "IndexedDB/\(directoryName)", isDirectory: true
                    )
                    guard let entries = try? fileManager.contentsOfDirectory(
                        at: databaseURL,
                        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) else { return [] }
                    return entries.filter { ["ldb", "log"].contains($0.pathExtension.lowercased()) }
                }
            }
    }

    /// Parse complete LevelDB physical records and WriteBatch values. Interaction detection is
    /// constrained to one complete value and a schema_payload -> tool_call object; it never uses
    /// a UUID-neighbourhood search, which can match user/assistant text by accident.
    static func waitingEvents(inWAL data: Data, agentConversations: [String: String]) -> [IndexedDBWaitingEvent] {
        guard !data.isEmpty, !agentConversations.isEmpty else { return [] }
        let allowed = Set(agentConversations.values)
        var output = Set<IndexedDBWaitingEvent>()
        for record in logicalRecords(inWAL: data) {
            for value in writeBatchValues(record) ?? [] {
                guard let root = ConversationTitleReader.serializedValue(value) else { continue }
                output.formUnion(structuredWaitingEvents(root: root, allowed: allowed))
            }
        }
        return Array(output)
    }

    static func structuredWaitingEvents(root: V8TitleValue, allowed: Set<String>) -> Set<IndexedDBWaitingEvent> {
        // Scope ownership to a task/message object; never inherit from arbitrary text.
        func string(_ value: V8TitleValue?) -> String? {
            if case .string(let s)? = value { return s }; return nil
        }
        var result = Set<IndexedDBWaitingEvent>()
        func walk(_ node: V8TitleValue, cid: String?, inQuickReply: Bool) {
            switch node {
            case .object(let object):
                var owner = string(object["local_conversation_id"]) ?? cid
                if case .object(let extra)? = object["extra"], let id = string(extra["local_conversation_id"]) { owner = id }
                if inQuickReply, let owner, allowed.contains(owner),
                   let schema = string(object["schema_payload"]), let data = schema.data(using: .utf8),
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = payload["tool_call_id"] as? String, UUID(uuidString: id) != nil,
                   let sandbox = payload["sandbox_id"] as? String, sandbox.hasPrefix("sandbox-") {
                    let native: Bool
                    if case .object(let extra)? = object["extra_params"] { native = string(extra["pc_native_may_involve"]) == "1" }
                    else { native = false }
                    result.insert(IndexedDBWaitingEvent(conversationID: owner, interactionID: id, kind: native ? "authorize" : "ask"))
                }
                for (key, value) in object {
                    walk(value, cid: owner, inQuickReply: inQuickReply || key == "quick_reply_block")
                }
            case .array(let values):
                for value in values { walk(value, cid: cid, inQuickReply: inQuickReply) }
            default: break
            }
        }
        walk(root, cid: nil, inQuickReply: false)
        return result
    }

    private static func logicalRecords(inWAL data: Data) -> [Data] {
        var records: [Data] = [], assembling: Data?
        var blockStart = data.startIndex
        while blockStart < data.endIndex {
            let blockEnd = min(data.endIndex, blockStart + levelDBBlockSize)
            var cursor = blockStart
            while cursor + 7 <= blockEnd {
                let length = Int(data[cursor + 4]) | (Int(data[cursor + 5]) << 8)
                let type = data[cursor + 6]
                if length == 0 && type == 0 { break }
                let start = cursor + 7, end = start + length
                guard end <= blockEnd else { break }
                let payload = Data(data[start..<end])
                switch type {
                case 1: records.append(payload)
                case 2: assembling = payload
                case 3: assembling?.append(payload)
                case 4:
                    if var combined = assembling { combined.append(payload); records.append(combined) }
                    assembling = nil
                default: break
                }
                cursor = end
            }
            blockStart += levelDBBlockSize
        }
        return records
    }

    private static func writeBatchValues(_ record: Data) -> [Data]? {
        guard record.count >= 12 else { return nil }
        let count = Int(record[8]) | (Int(record[9]) << 8) | (Int(record[10]) << 16) | (Int(record[11]) << 24)
        var cursor = 12, values: [Data] = []
        for _ in 0..<max(0, count) {
            guard cursor < record.endIndex else { return nil }
            let tag = record[cursor]; cursor += 1
            guard let (keyLength, afterKeyLength) = readVarint(record, at: cursor),
                  afterKeyLength + keyLength <= record.endIndex else { return nil }
            cursor = afterKeyLength + keyLength
            if tag == 1 {
                guard let (valueLength, afterValueLength) = readVarint(record, at: cursor),
                      afterValueLength + valueLength <= record.endIndex else { return nil }
                values.append(Data(record[afterValueLength..<(afterValueLength + valueLength)]))
                cursor = afterValueLength + valueLength
            } else if tag != 0 { return nil }
        }
        return values
    }

    private static func readVarint(_ data: Data, at start: Int) -> (Int, Int)? {
        var cursor = start, value = 0, shift = 0
        while cursor < data.endIndex, shift <= 56 {
            let byte = data[cursor]; cursor += 1
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, cursor) }
            shift += 7
        }
        return nil
    }

    private static func firstUUID(in data: Data, range: Range<Int>) -> (String, Int)? {
        var cursor = range.lowerBound
        while cursor + 36 <= range.upperBound {
            if isUUID(data, at: cursor),
               let string = String(data: data[cursor..<(cursor + 36)], encoding: .ascii) {
                return (string, cursor)
            }
            cursor += 1
        }
        return nil
    }

    private static func isUUID(_ data: Data, at index: Int) -> Bool {
        guard index >= data.startIndex, index + 36 <= data.endIndex else { return false }
        let hyphens: Set<Int> = [8, 13, 18, 23]
        for offset in 0..<36 {
            let byte = data[index + offset]
            if hyphens.contains(offset) {
                if byte != 0x2d { return false }
            } else if !((byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)) {
                return false
            }
        }
        return true
    }
}
