import Foundation

/// Read complete LevelDB values, including Snappy SST blocks, before interpreting V8 data.
struct ConversationTitleReader {
    private let fileManager: FileManager
    private final class Cache {
        var values: [String: (size: UInt64, modified: Date, titles: [String: (UInt64, String)])] = [:]
    }
    private let cache = Cache()
    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func title(conversationID: String, doubaoDataRoot: URL) -> String? {
        titles(conversationIDs: [conversationID], doubaoDataRoot: doubaoDataRoot)[conversationID]
    }

    func titles(conversationIDs: Set<String>, doubaoDataRoot: URL) -> [String: String] {
        let ids = conversationIDs.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard !ids.isEmpty, let profiles = try? fileManager.contentsOfDirectory(
            at: doubaoDataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        let files = profiles.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .flatMap { profile -> [URL] in
                let db = doubaoDataRoot.lastPathComponent == "DoubaoWork"
                    ? "chrome_doubaowork-chat_0.indexeddb.leveldb" : nil
                let names = db.map { [$0] } ?? ["chrome_doubaowork-chat_0.indexeddb.leveldb", "chrome_doubao-chat_0.indexeddb.leveldb"]
                return names.flatMap { name -> [URL] in
                    let url = profile.appendingPathComponent("IndexedDB/\(name)")
                    return ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                        .filter { ["ldb", "log"].contains($0.pathExtension) }
                }
            }
        let livePaths = Set(files.map(\.path))
        cache.values = cache.values.filter { livePaths.contains($0.key) }
        var found: [String: (sequence: UInt64, title: String)] = [:]
        for url in files {
            let attrs = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            if let hit = cache.values[url.path], hit.size == size, hit.modified == modified {
                for (cid, pair) in hit.titles where ids.contains(cid) {
                    if found[cid] == nil || pair.0 >= found[cid]!.sequence { found[cid] = (pair.0, pair.1) }
                }
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            var perFile: [String: (UInt64, String)] = [:]
            for entry in LevelDBTitleValues.entries(data) {
                for (cid, title) in Self.structuredTitles(entry.value) {
                    if perFile[cid] == nil || entry.sequence >= perFile[cid]!.0 { perFile[cid] = (entry.sequence, title) }
                    if ids.contains(cid), found[cid] == nil || entry.sequence >= found[cid]!.sequence {
                        found[cid] = (entry.sequence, title)
                    }
                }
            }
            cache.values[url.path] = (size, modified, perFile)
        }
        return found.mapValues(\.title)
    }

    static func latestTitle(in data: Data, conversationID: Data) -> String? {
        guard let cid = String(data: conversationID, encoding: .utf8) else { return nil }
        let entries = LevelDBTitleValues.entries(data)
        var result: (UInt64, String)?
        for entry in entries {
            if let title = structuredTitles(entry.value)[cid], result == nil || entry.sequence >= result!.0 {
                result = (entry.sequence, title)
            }
        }
        if let result { return result.1 }
        if let title = structuredTitles(data)[cid] { return title }
        // Historical exact fixture format; cannot match permission_name or other objects.
        let prefix = Data("conversation-list-data-overall-v2-c_id\(cid)-type-creator-name".utf8)
        guard let range = data.range(of: prefix, options: .backwards) else { return nil }
        var decoder = V8TitleDecoder(bytes: Array(data), cursor: range.upperBound)
        guard let value = decoder.value(), case .string(let title) = value else { return nil }
        return sanitize(title)
    }

    static func serializedValue(_ data: Data) -> V8TitleValue? {
        guard let payload = serializedPayload(data) else { return nil }
        var decoder = V8TitleDecoder(bytes: Array(payload), cursor: 2)
        return decoder.value()
    }

    static func structuredTitles(_ data: Data) -> [String: String] {
        guard let payload = serializedPayload(data) else { return [:] }
        let bytes = Array(payload)
        var decoder = V8TitleDecoder(bytes: bytes, cursor: 2)
        guard let root = decoder.value() else { return [:] }
        guard case .object(let object) = root,
              case .string(let schema)? = object["schema"],
              schema.hasPrefix("conversation-list-data-") else { return [:] }
        var result: [String: String] = [:]
        func visit(_ node: V8TitleValue) {
            switch node {
            case .object(let obj):
                if case .string(let cid)? = obj["conversation_id"],
                   case .string(let name)? = obj["name"], let title = sanitize(name) {
                    result[cid] = title
                }
                for value in obj.values { visit(value) }
            case .array(let values): for value in values { visit(value) }
            default: break
            }
        }
        visit(root)
        return result
    }

    /// Only unwrap recognized headers at the current cursor. Never search compressed data
    /// for an incidental V8 marker. IndexedDB values can include a leading record varint.
    private static func serializedPayload(_ data: Data) -> Data? {
        var bytes = Array(data)
        guard !bytes.isEmpty else { return nil }
        if bytes[0] != 0xff {
            guard let (_, cursor) = LevelDBTitleValues.vi(bytes, 0), cursor <= 10,
                  cursor < bytes.count, bytes[cursor] == 0xff else { return nil }
            bytes = Array(bytes.dropFirst(cursor))
        }
        for _ in 0..<4 {
            if bytes.starts(with: [0xff, 0x0f]) { return Data(bytes) }
            if bytes.starts(with: [0xff, 0x11, 0x02]) {
                guard let unpacked = LevelDBTitleValues.snappy(Array(bytes.dropFirst(3))) else { return nil }
                bytes = unpacked
            } else if bytes.count >= 15, bytes.starts(with: [0xff, 0x15, 0xfe, 0x00]),
                      bytes[4..<15].allSatisfy({ $0 == 0 }) {
                bytes = Array(bytes.dropFirst(15))
            } else if bytes.count > 4, bytes[0] == 0xff, bytes[2] == 0xfe, bytes[3] == 2 {
                guard let unpacked = LevelDBTitleValues.snappy(Array(bytes.dropFirst(4))) else { return nil }
                bytes = unpacked
            } else {
                return nil
            }
        }
        return nil
    }

    private static func sanitize(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200,
              !title.unicodeScalars.contains(where: { $0 == "\u{fffd}" || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return title
    }
}

indirect enum V8TitleValue {
    case string(String), object([String: V8TitleValue]), array([V8TitleValue]), scalar
}

private struct V8TitleDecoder {
    let bytes: [UInt8]
    var cursor: Int
    var objects: [V8TitleValue] = []
    var depth = 0
    mutating func varint() -> UInt64? {
        var value: UInt64 = 0; var shift: UInt64 = 0
        while cursor < bytes.count && shift < 64 {
            let b = bytes[cursor]; cursor += 1
            value |= UInt64(b & 127) << shift
            if b < 128 { return value }; shift += 7
        }
        return nil
    }
    mutating func value() -> V8TitleValue? {
        guard depth < 100, cursor < bytes.count else { return nil }
        depth += 1; defer { depth -= 1 }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        guard cursor < bytes.count else { return nil }
        let tag = bytes[cursor]; cursor += 1
        switch tag {
        case 0x22, 0x63, 0x53:
            guard let n64 = varint(), n64 <= UInt64(bytes.count - cursor) else { return nil }
            let n = Int(n64); let payload = Data(bytes[cursor..<cursor+n]); cursor += n
            if tag == 0x63 && n % 2 != 0 { return nil }
            let encoding: String.Encoding = tag == 0x63 ? .utf16LittleEndian : tag == 0x22 ? .isoLatin1 : .utf8
            return String(data: payload, encoding: encoding).map(V8TitleValue.string)
        case 0x49, 0x55: guard varint() != nil else { return nil }; return .scalar
        case 0x4e, 0x44:
            guard cursor + 8 <= bytes.count else { return nil }; cursor += 8; return .scalar
        case 0x54, 0x46, 0x5f, 0x30, 0x2d: return .scalar
        case 0x5e:
            guard let i = varint(), i < objects.count else { return nil }; return objects[Int(i)]
        case 0x6f:
            let index = objects.count; objects.append(.scalar)
            var fields: [String: V8TitleValue] = [:]
            while cursor < bytes.count {
                if bytes[cursor] == 0x7b { cursor += 1; guard varint() != nil else { return nil }; let obj = V8TitleValue.object(fields); objects[index] = obj; return obj }
                guard let key = value(), case .string(let name) = key, let item = value() else { return nil }
                fields[name] = item
            }; return nil
        case 0x41:
            guard let count = varint(), count <= 100_000 else { return nil }
            let index = objects.count; objects.append(.scalar)
            var items: [V8TitleValue] = []
            for _ in 0..<count { guard let item = value() else { return nil }; items.append(item) }
            while cursor < bytes.count && bytes[cursor] != 0x24 {
                guard value() != nil, value() != nil else { return nil }
            }
            guard cursor < bytes.count else { return nil }; cursor += 1
            guard varint() != nil, varint() != nil else { return nil }
            let array = V8TitleValue.array(items); objects[index] = array; return array
        case 0x61:
            guard varint() != nil else { return nil }
            let index = objects.count; objects.append(.scalar); var items: [V8TitleValue] = []
            while cursor < bytes.count && bytes[cursor] != 0x40 {
                guard value() != nil, let item = value() else { return nil }; items.append(item)
            }
            guard cursor < bytes.count else { return nil }; cursor += 1
            guard varint() != nil, varint() != nil else { return nil }
            let array = V8TitleValue.array(items); objects[index] = array; return array
        default: return nil // Fail closed on unsupported serialization; never search arbitrary name bytes.
        }
    }
}

private struct LevelDBTitleValues {
    struct Entry { let sequence: UInt64; let value: Data }
    static func vi(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        guard start >= 0 else { return nil }
        var cursor = start; var result: UInt64 = 0; var shift: UInt64 = 0
        while cursor < bytes.count && shift < 64 {
            let b = bytes[cursor]; cursor += 1; result |= UInt64(b & 127) << shift
            if b < 128 { return (result, cursor) }; shift += 7
        }; return nil
    }
    static func little(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        guard i >= 0, i+n <= b.count else { return 0 }
        return (0..<n).reduce(0) { $0 | UInt64(b[i+$1]) << ($1*8) }
    }
    static func snappy(_ b: [UInt8]) -> [UInt8]? {
        guard let (expected, start) = vi(b,0), expected <= 64*1024*1024 else { return nil }
        var i = start; var out: [UInt8] = []; out.reserveCapacity(Int(expected))
        while i < b.count {
            let tag = b[i]; i += 1; let kind = tag & 3
            if kind == 0 {
                var n = Int(tag >> 2)
                if n >= 60 {
                    let size = n-59; guard i+size <= b.count else { return nil }
                    n = Int(little(b,i,size)); i += size
                }; n += 1
                guard n <= Int(expected)-out.count, i+n <= b.count else { return nil }
                out.append(contentsOf: b[i..<i+n]); i += n
            } else {
                let n: Int; let offset: Int
                if kind == 1 {
                    guard i < b.count else { return nil }; n = 4+Int((tag >> 2)&7); offset = (Int(tag&224)<<3)|Int(b[i]); i += 1
                } else {
                    let size = kind == 2 ? 2 : 4; guard i+size <= b.count else { return nil }
                    n = 1+Int(tag >> 2); offset = Int(little(b,i,size)); i += size
                }
                guard offset > 0, offset <= out.count, n <= Int(expected)-out.count else { return nil }
                for _ in 0..<n { out.append(out[out.count-offset]) }
            }
        }
        return out.count == Int(expected) ? out : nil
    }
    static func entries(_ data: Data) -> [Entry] {
        let b = Array(data)
        if b.count >= 48 && Array(b.suffix(8)) == [0x57,0xfb,0x80,0x8b,0x24,0x75,0x47,0xdb] { return sst(b) }
        var result: [Entry] = []; var assembling: [UInt8]? = nil
        for block in stride(from: 0,to:b.count,by:32768) {
            let end = min(b.count,block+32768); var i = block
            while i+7 <= end {
                let n = Int(little(b,i+4,2)); let type = b[i+6]
                if type == 0 && n == 0 { break }
                guard i+7+n <= end else { break }
                let payload = Array(b[i+7..<i+7+n]); i += 7+n
                switch type {
                case 1: result += batch(payload)
                case 2: assembling = payload
                case 3: assembling?.append(contentsOf: payload)
                case 4:
                    if var value = assembling { value.append(contentsOf: payload); result += batch(value) }; assembling = nil
                default: assembling = nil
                }
            }
        }; return result
    }
    static func batch(_ b: [UInt8]) -> [Entry] {
        guard b.count >= 12 else { return [] }
        let count = little(b,8,4); guard count <= UInt64(b.count) else { return [] }
        var i = 12; var result: [Entry] = []; let seq = little(b,0,8)
        for index in 0..<count {
            guard i < b.count else { return [] }; let tag = b[i]; i += 1
            guard let (key,after) = vi(b,i), key <= UInt64(b.count-after) else { return [] }; i = after+Int(key)
            if tag == 0 { continue }
            guard tag == 1, let (n,start) = vi(b,i), n <= UInt64(b.count-start) else { return [] }
            result.append(Entry(sequence: seq+index, value: Data(b[start..<start+Int(n)]))); i = start+Int(n)
        }; return result
    }
    static func block(_ b: [UInt8], _ offset: UInt64, _ size: UInt64) -> [UInt8]? {
        guard offset < b.count, size <= UInt64(b.count)-offset-1 else { return nil }
        let i = Int(offset); let n = Int(size); let body = Array(b[i..<i+n])
        if b[i+n] == 0 { return body }; if b[i+n] == 1 { return snappy(body) }; return nil
    }
    static func blockEntries(_ b: [UInt8]) -> [(key:[UInt8],value:[UInt8])] {
        guard b.count >= 4 else { return [] }
        let restarts = Int(little(b,b.count-4,4)); guard restarts <= (b.count-4)/4 else { return [] }
        let end = b.count-4-restarts*4; var i = 0; var last:[UInt8] = []; var result:[([UInt8],[UInt8])] = []
        while i < end {
            guard let (shared,a) = vi(b,i), let (suffix,c) = vi(b,a), let (size,start) = vi(b,c),
                  start <= end, shared <= last.count, suffix <= UInt64(end-start), size <= UInt64(end-start)-suffix else { return [] }
            let key = Array(last.prefix(Int(shared)))+Array(b[start..<start+Int(suffix)])
            i = start+Int(suffix); let value = Array(b[i..<i+Int(size)]); i += Int(size)
            result.append((key,value)); last = key
        }; return result
    }
    static func sst(_ b: [UInt8]) -> [Entry] {
        let f = Array(b.suffix(48))
        guard let (_,a) = vi(f,0), let (_,c) = vi(f,a), let (offset,d) = vi(f,c), let (size,_) = vi(f,d),
              let index = block(b,offset,size) else { return [] }
        var result:[Entry] = []
        for entry in blockEntries(index) {
            guard let (off,a) = vi(entry.value,0), let (n,_) = vi(entry.value,a), let valueBlock = block(b,off,n) else { continue }
            for item in blockEntries(valueBlock) where item.key.count >= 8 {
                let footer = little(item.key,item.key.count-8,8)
                if footer & 255 == 1 { result.append(Entry(sequence: footer >> 8,value: Data(item.value))) }
            }
        }; return result
    }
}
