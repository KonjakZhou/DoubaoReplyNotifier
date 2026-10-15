import Foundation

private func encodeVarint(_ value: Int) -> Data {
    var result = Data()
    var remaining = value
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        result.append(byte)
    } while remaining != 0
    return result
}

private func record(conversationID: String, title: String, twoByte: Bool = true) -> Data {
    var data = Data("prefix-conversation-list-data-overall-v2-c_id".utf8)
    data.append(Data(conversationID.utf8))
    data.append(Data("-type-creator-name".utf8))
    let payload: Data
    if twoByte {
        payload = title.data(using: .utf16LittleEndian)!
        data.append(0x63)
    } else {
        payload = title.data(using: .utf8)!
        data.append(0x22)
    }
    data.append(encodeVarint(payload.count))
    data.append(payload)
    data.append(Data("-image_thumb-suffix".utf8))
    return data
}

@main
struct TitleReaderTest {
    static func main() {
        let chineseID = "38446803538321410"
        let chineseTitle = "豆包插件问题分析与改进方案"
        let englishID = "90000000000000001"
        let englishTitle = "Notifier title test"

        var data = record(conversationID: chineseID, title: "旧标题")
        data.append(record(conversationID: englishID, title: englishTitle, twoByte: false))
        data.append(record(conversationID: chineseID, title: chineseTitle))

        guard ConversationTitleReader.latestTitle(in: data, conversationID: Data(chineseID.utf8)) == chineseTitle else {
            fatalError("failed to decode latest UTF-16LE conversation title")
        }
        guard ConversationTitleReader.latestTitle(in: data, conversationID: Data(englishID.utf8)) == englishTitle else {
            fatalError("failed to decode one-byte conversation title")
        }
        guard ConversationTitleReader.latestTitle(in: data, conversationID: Data("999".utf8)) == nil else {
            fatalError("unknown conversation unexpectedly resolved")
        }

        // Exact field boundary: permission_name must never be accepted as conversation name.
        var polluted = Data("conversation-list-data-overall-v2".utf8)
        polluted.append(Data(chineseID.utf8))
        polluted.append(Data("permission_name".utf8))
        polluted.append(0x22); polluted.append(22)
        polluted.append(Data("ACCESS_COARSE_LOCATION".utf8))
        assert(ConversationTitleReader.latestTitle(in: polluted, conversationID: Data(chineseID.utf8)) == nil)
        func str(_ value: String) -> Data {
            let payload = Data(value.utf8)
            return Data([0x22]) + encodeVarint(payload.count) + payload
        }
        var object = Data([0xff,0x0f,0x6f])
        for part in [str("schema"), str("conversation-list-data-overall-v2"), str("data"), Data([0x6f]),
                     str("conversation_id"), str(chineseID), str("permission_name"), str("ACCESS_COARSE_LOCATION"),
                     str("name"), str("Correct title"), Data([0x7b,3,0x7b,2])] { object.append(part) }
        assert(ConversationTitleReader.structuredTitles(object)[chineseID] == "Correct title")
        var wrongSchema = Data([0xff,0x0f,0x6f])
        for part in [str("schema"), str("message-data"), str("data"), Data([0x6f]), str("conversation_id"),
                     str(chineseID), str("name"), str("Wrong message title"), Data([0x7b,2,0x7b,2])] { wrongSchema.append(part) }
        assert(ConversationTitleReader.structuredTitles(wrongSchema).isEmpty)

        // Serialization unit fixtures exercise headers only; real on-machine values
        // are separately read end-to-end without including their contents in Git.
        func literalSnappy(_ value: Data) -> Data {
            var result = encodeVarint(value.count)
            let n = value.count - 1
            if n < 60 { result.append(UInt8(n << 2)) }
            else {
                var length = n
                var encoded: [UInt8] = []
                repeat { encoded.append(UInt8(length & 255)); length >>= 8 } while length > 0
                result.append(UInt8((59 + encoded.count) << 2))
                result.append(contentsOf: encoded)
            }
            result.append(value)
            return result
        }
        let outerHeader = Data([0xff,0x15,0xfe,0]) + Data(repeating: 0, count: 11)
        let wrapped = encodeVarint(1715) + Data([0xff,0x11,2]) + literalSnappy(outerHeader + object)
        assert(ConversationTitleReader.structuredTitles(wrapped)[chineseID] == "Correct title")
        assert(ConversationTitleReader.structuredTitles(outerHeader + object)[chineseID] == "Correct title")
        let legacyCompressed = Data([0xff,0x15,0xfe,2]) + literalSnappy(object)
        assert(ConversationTitleReader.structuredTitles(legacyCompressed)[chineseID] == "Correct title")
        assert(ConversationTitleReader.structuredTitles(Data(wrapped.dropLast())).isEmpty)
        assert(ConversationTitleReader.structuredTitles(Data([0xff,0x11,2,0x01]) + object).isEmpty)
        assert(ConversationTitleReader.structuredTitles(Data([0xff,0x7e,0x02]) + object).isEmpty)
        assert(ConversationTitleReader.structuredTitles(Data("irrelevant field bytes".utf8) + object).isEmpty)

        if CommandLine.arguments.count == 2 {
            let value = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            assert(ConversationTitleReader.structuredTitles(value)["38447401633048578"] == "Mac上Command+M的原始功能")
        }
        if CommandLine.arguments.count == 4 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let actual = ConversationTitleReader().title(conversationID: CommandLine.arguments[2], doubaoDataRoot: root)
            guard actual == CommandLine.arguments[3] else {
                fatalError("real database title mismatch: \(actual ?? "nil")")
            }
        }

        print("{\"utf16_title\":true,\"one_byte_title\":true,\"latest_record_wins\":true,\"outer_snappy_headers\":true,\"malformed_compression_rejected\":true}")
    }
}
