import Foundation

struct IndexedDBWaitingEvent: Hashable {
    let conversationID: String
    let interactionID: String
}

struct IndexedDBInteractionReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func databaseFiles(doubaoDataRoot: URL) -> [URL] {
        guard let profiles = try? fileManager.contentsOfDirectory(
            at: doubaoDataRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return profiles
            .filter { url in
                let name = url.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ")
            }
            .flatMap { profileURL -> [URL] in
                let databaseURL = profileURL.appendingPathComponent(
                    "IndexedDB/chrome_doubao-chat_0.indexeddb.leveldb",
                    isDirectory: true
                )
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: databaseURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                return entries.filter {
                    let ext = $0.pathExtension.lowercased()
                    return ext == "ldb" || ext == "log"
                }
            }
    }

    func signature(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)"
    }

    func waitingEvents(fileURL: URL, agentConversations: [String: String]) -> [IndexedDBWaitingEvent] {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return [] }
        return Self.waitingEvents(in: data, agentConversations: agentConversations)
    }

    static func waitingEvents(in data: Data, agentConversations: [String: String]) -> [IndexedDBWaitingEvent] {
        guard !data.isEmpty, !agentConversations.isEmpty else { return [] }

        let agentNeedles: [(agentID: String, conversationID: String, needle: Data)] = agentConversations.compactMap {
            guard $0.key.hasPrefix("m_"), !$0.value.isEmpty else { return nil }
            return ($0.key, $0.value, Data($0.key.utf8))
        }
        guard !agentNeedles.isEmpty else { return [] }

        let interactionAnchor = Data("dbx_ic".utf8)
        let requiredAnchor = Data("required".utf8)
        let capabilityAnchor = Data("capab".utf8)
        var bestByInteraction: [String: (conversationID: String, distance: Int)] = [:]
        var index = data.startIndex

        while index + 36 <= data.endIndex {
            guard isUUID(data, at: index) else {
                index += 1
                continue
            }
            let beforeStart = max(data.startIndex, index - 512)
            let afterEnd = min(data.endIndex, index + 1_536)
            let before = data[beforeStart..<index]
            let after = data[(index + 36)..<afterEnd]
            guard before.range(of: interactionAnchor) != nil,
                  after.range(of: requiredAnchor) != nil,
                  after.range(of: capabilityAnchor) != nil,
                  let interactionID = String(data: data[index..<(index + 36)], encoding: .ascii) else {
                index += 36
                continue
            }

            let associationStart = index + 36
            let associationEnd = min(data.endIndex, index + 8_192)
            let associationRange = associationStart..<associationEnd
            let nearest = agentNeedles.compactMap { candidate -> (conversationID: String, distance: Int)? in
                guard let match = data.range(of: candidate.needle, in: associationRange) else { return nil }
                return (candidate.conversationID, abs(match.lowerBound - index))
            }.min { $0.distance < $1.distance }

            if let nearest,
               nearest.distance < (bestByInteraction[interactionID]?.distance ?? Int.max) {
                bestByInteraction[interactionID] = nearest
            }
            index += 36
        }
        return bestByInteraction.map {
            IndexedDBWaitingEvent(conversationID: $0.value.conversationID, interactionID: $0.key)
        }
    }

    private static func isUUID(_ data: Data, at index: Int) -> Bool {
        guard index >= data.startIndex, index + 36 <= data.endIndex else { return false }
        let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
        for offset in 0..<36 {
            let byte = data[index + offset]
            if hyphenOffsets.contains(offset) {
                if byte != 0x2d { return false }
            } else if !isLowerHex(byte) {
                return false
            }
        }
        return true
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }
}
