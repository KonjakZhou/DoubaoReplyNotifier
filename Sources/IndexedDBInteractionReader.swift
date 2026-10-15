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
        let records = logicalRecords(inWAL: data)
        let batches = records.compactMap(writeBatchValues)
        if ProcessInfo.processInfo.environment["DOUBAO_INDEXEDDB_DEBUG"] == "1" {
            fputs("indexeddb records=\(records.count) batches=\(batches.count) values=\(batches.reduce(0) { $0 + $1.count })\n", stderr)
        }
        let identities = agentConversations.map {
            (agent: Data($0.key.utf8), cid: $0.value, cidData: Data($0.value.utf8))
        }
        var result = Set<IndexedDBWaitingEvent>()

        for values in batches {
            for value in values {
                let cid = structuredConversationID(in: value, identities: identities)
                guard let cid else {
                    if ProcessInfo.processInfo.environment["DOUBAO_INDEXEDDB_DEBUG"] == "1",
                       value.range(of: Data("schema_payload".utf8)) != nil {
                        fputs("indexeddb schema without structured local_conversation_id\n", stderr)
                    }
                    continue
                }
                let interactions = structuredInteractions(in: value)
                if ProcessInfo.processInfo.environment["DOUBAO_INDEXEDDB_DEBUG"] == "1", !interactions.isEmpty {
                    fputs("indexeddb cid=\(cid) interactions=\(interactions)\n", stderr)
                }
                for interaction in interactions {
                    result.insert(IndexedDBWaitingEvent(
                        conversationID: cid,
                        interactionID: interaction.id,
                        kind: interaction.kind
                    ))
                }
            }
        }
        return Array(result)
    }

    private static func structuredConversationID(
        in value: Data,
        identities: [(agent: Data, cid: String, cidData: Data)]
    ) -> String? {
        let marker = Data("local_conversation_id".utf8)
        var cursor = value.startIndex
        while cursor < value.endIndex,
              let markerRange = value.range(of: marker, in: cursor..<value.endIndex) {
            let end = min(value.endIndex, markerRange.upperBound + 160)
            for identity in identities where
                value.range(of: identity.cidData, in: markerRange.upperBound..<end) != nil {
                return identity.cid
            }
            cursor = markerRange.upperBound
        }
        return nil
    }

    private static func structuredInteractions(in value: Data) -> [(id: String, kind: String)] {
        let schema = Data("schema_payload".utf8)
        let toolCall = Data("tool_call".utf8)
        var output: [(String, String)] = []
        var cursor = value.startIndex
        while cursor < value.endIndex,
              let schemaRange = value.range(of: schema, in: cursor..<value.endIndex) {
            let end = min(value.endIndex, schemaRange.lowerBound + 4_096)
            guard let toolRange = value.range(of: toolCall, in: schemaRange.upperBound..<end),
                  let (id, _) = firstUUID(in: value, range: toolRange.upperBound..<min(end, toolRange.upperBound + 768)) else {
                cursor = schemaRange.upperBound
                continue
            }
            let contextStart = max(value.startIndex, schemaRange.lowerBound - 768)
            let context = value[contextStart..<end]
            let kind: String?
            if context.range(of: Data("approve".utf8)) != nil ||
                context.range(of: Data("pc_native_may_involve".utf8)) != nil {
                kind = "authorize"
            } else if context.range(of: Data("quick_reply".utf8)) != nil {
                kind = "ask"
            } else if context.range(of: Data("request_action".utf8)) != nil {
                kind = "request_action"
            } else {
                kind = nil
            }
            if let kind { output.append((id, kind)) }
            cursor = schemaRange.upperBound
        }
        return output
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
