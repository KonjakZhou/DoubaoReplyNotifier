import Foundation

@main struct NativeSourceTests {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let rows = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = rows.first { $0.contains("on_message_receiving_start") }!
        let end = rows.first { $0.contains("on_message_session_end") }!
        let product = "com.work.pc.doubao"
        let start = NativeRoundSource.signal(in: source, product: product)!
        let finish = NativeRoundSource.signal(in: end, product: product)!
        precondition(start.round.runID == finish.round.runID && !start.isEnd && finish.isEnd)
        precondition(start.localID == "local_2111801313218126")
        let other = NativeRoundSource.signal(in: source, product: "com.bot.pc.doubao")!
        precondition(other.round.runID != start.round.runID)
        precondition(NativeRoundSource.aliasKey(product: product, line: source, localID: start.localID!) != NativeRoundSource.aliasKey(product: other.round.product, line: source, localID: start.localID!))
        precondition(NativeRoundSource.signal(in: source.replacingOccurrences(of: "[office-api-logger]", with: "tool-output"), product: product) == nil)
        precondition(NativeRoundSource.signal(in: end.replacingOccurrences(of: #""agent_error":"0""#, with: #""agent_error":"1""#), product: product) == nil)
        precondition(NativeRoundSource.signal(in: end.replacingOccurrences(of: #""cancel_source":"""#, with: #""cancel_source":"user""#), product: product) == nil)
        precondition(NativeRoundSource.signal(in: source.replacingOccurrences(of: "1792573965913", with: "true"), product: product) == nil)
        precondition(NativeRoundSource.signal(in: source.replacingOccurrences(of: "mainagent", with: "subagent"), product: product) == nil)
        precondition(NativeRoundSource.signal(in: source.replacingOccurrences(of: "work_task", with: "chat"), product: product) == nil)
        precondition(NativeRoundSource.signal(in: String(source.prefix(source.count / 2)), product: product) == nil)
        precondition(NativeRoundSource.navigationAlias(in: rows[0])?.conversation == start.round.conversationID)
        print("PASS native source schema, source, failed/canceled end, mainagent, product isolation and real identity pair")
    }
}
