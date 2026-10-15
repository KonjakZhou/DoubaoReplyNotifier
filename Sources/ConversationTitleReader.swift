import Foundation

struct ConversationTitleReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func title(conversationID: String, doubaoDataRoot: URL) -> String? {
        titles(conversationIDs: [conversationID], doubaoDataRoot: doubaoDataRoot)[conversationID]
    }

    func titles(conversationIDs: Set<String>, doubaoDataRoot: URL) -> [String: String] {
        var unresolved = Set(conversationIDs.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        guard !unresolved.isEmpty,
              let profiles = try? fileManager.contentsOfDirectory(
                at: doubaoDataRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [:] }

        let candidateFiles = profiles
            .filter { url in
                let name = url.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ")
            }
            .flatMap(databaseFiles)
            .sorted { lhs, rhs in
                let leftDate = modificationDate(lhs)
                let rightDate = modificationDate(rhs)
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }

        var result: [String: String] = [:]
        for fileURL in candidateFiles {
            guard !unresolved.isEmpty else { break }
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            for conversationID in unresolved {
                let needle = Data(conversationID.utf8)
                guard let title = Self.latestTitle(in: data, conversationID: needle) else { continue }
                result[conversationID] = title
            }
            unresolved.subtract(result.keys)
        }
        return result
    }

    private static let chatDatabaseDirectoryNames = [
        "chrome_doubaowork-chat_0.indexeddb.leveldb",
        "chrome_doubao-chat_0.indexeddb.leveldb"
    ]

    private func databaseFiles(profileURL: URL) -> [URL] {
        Self.chatDatabaseDirectoryNames.flatMap { directoryName -> [URL] in
            let databaseURL = profileURL.appendingPathComponent(
                "IndexedDB/\(directoryName)",
                isDirectory: true
            )
            guard let entries = try? fileManager.contentsOfDirectory(
                at: databaseURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "ldb" || ext == "log"
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func latestTitle(in data: Data, conversationID: Data) -> String? {
        guard !conversationID.isEmpty, data.count >= conversationID.count else { return nil }
        var searchEnd = data.endIndex
        while searchEnd >= conversationID.count {
            let searchRange = data.startIndex..<searchEnd
            guard let match = data.range(of: conversationID, options: [.backwards], in: searchRange) else { return nil }
            let contextStart = max(data.startIndex, match.lowerBound - 512)
            let context = data[contextStart..<match.lowerBound]
            if context.range(of: Data("conversation-list-data-".utf8)) != nil,
               let title = titleAfterConversationID(in: data, start: match.upperBound) {
                return title
            }
            if match.lowerBound == data.startIndex { return nil }
            searchEnd = match.lowerBound
        }
        return nil
    }

    private static func titleAfterConversationID(in data: Data, start: Data.Index) -> String? {
        let limit = min(data.endIndex, start + 192)
        guard start < limit else { return nil }
        let nameMarker = Data("name".utf8)
        guard let markerRange = data.range(of: nameMarker, in: start..<limit) else { return nil }
        var cursor = markerRange.upperBound
        while cursor < data.endIndex, data[cursor] == 0 { cursor += 1 }
        guard cursor < data.endIndex else { return nil }

        let encodingMarker = data[cursor]
        cursor += 1
        guard let (byteCount, payloadStart) = readVarint(in: data, at: cursor),
              byteCount > 0, byteCount <= 512,
              payloadStart <= data.endIndex,
              byteCount <= data.endIndex - payloadStart else { return nil }
        let payload = data[payloadStart..<(payloadStart + byteCount)]

        let decoded: String?
        switch encodingMarker {
        case 0x63: // Chromium/V8 two-byte string (UTF-16LE).
            guard byteCount.isMultiple(of: 2) else { return nil }
            decoded = String(data: payload, encoding: .utf16LittleEndian)
        case 0x22: // Chromium/V8 one-byte string.
            decoded = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1)
        default:
            return nil
        }
        return sanitize(decoded)
    }

    private static func readVarint(in data: Data, at start: Data.Index) -> (Int, Data.Index)? {
        var cursor = start
        var value = 0
        var shift = 0
        while cursor < data.endIndex, shift <= 28 {
            let byte = data[cursor]
            cursor += 1
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, cursor) }
            shift += 7
        }
        return nil
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200,
              !title.unicodeScalars.contains(where: { scalar in
                  scalar == "\u{fffd}" || (CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar))
              }) else { return nil }
        return title
    }
}
