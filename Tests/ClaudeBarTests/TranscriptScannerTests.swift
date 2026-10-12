import Foundation
import Testing
@testable import ClaudeBar

@Suite("Transcript scanning")
struct TranscriptScannerTests {
    private let root: URL
    private let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claudebar-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-me-code-demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        file = project.appendingPathComponent("session.jsonl")
    }

    private func line(id: String, model: String = "claude-opus-5-5", input: Int = 10, output: Int = 5,
                      cacheRead: Int = 100, date: Date = Date(), session: String = "s1") -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"{"type":"assistant","timestamp":"\#(stamp)","sessionId":"\#(session)","cwd":"/Users/me/code/demo","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":0}}}"#
    }

    private func append(_ text: String) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func countsEachResponseOnce() async throws {
        try append([
            line(id: "a"), line(id: "a"), // same response logged for two content blocks
            line(id: "b", output: 7, session: "s2"),
            line(id: "c", model: "<synthetic>"),
            #"{"type":"user","message":{"content":"hi"}}"#,
        ].joined(separator: "\n") + "\n")

        let snapshot = await TranscriptScanner(roots: [root]).scan()
        #expect(snapshot.todayMessages == 2)
        #expect(snapshot.todayOutput == 12)
        #expect(snapshot.todayTokens == 115 + 117)
        #expect(snapshot.todaySessions == 2)
        #expect(snapshot.activeSessions == 2)
        #expect(snapshot.window?.projects.first?.name == "demo")
        #expect(snapshot.models.map(\.name) == ["Opus 5.5"])
        #expect(snapshot.daily.count == TranscriptScanner.horizonDays)
        #expect(snapshot.daily.last?.tokens == 232)
    }

    @Test func picksUpAppendedLinesAndWaitsForPartialOnes() async throws {
        let scanner = TranscriptScanner(roots: [root])
        try append(line(id: "a") + "\n")
        #expect(await scanner.scan().todayMessages == 1)

        let next = line(id: "b")
        let split = next.index(next.startIndex, offsetBy: 40)
        try append(String(next[..<split])) // still being written
        #expect(await scanner.scan().todayMessages == 1)

        try append(String(next[split...]) + "\n")
        #expect(await scanner.scan().todayMessages == 2)
    }

    @Test func ignoresActivityOutsideTheHorizon() async throws {
        let old = Date().addingTimeInterval(-Double(TranscriptScanner.horizonDays + 2) * 86400)
        try append(line(id: "old", date: old) + "\n" + line(id: "new") + "\n")
        let snapshot = await TranscriptScanner(roots: [root]).scan()
        #expect(snapshot.daily.reduce(0) { $0 + $1.tokens } == 115)
    }

    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-5", "Opus 5"),
    ])
    func prettifiesModelIDs(id: String, expected: String) {
        #expect(ModelCatalog.displayName(id) == expected)
    }

    @Test func attributesSessionWindowByCost() async throws {
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        try append([
            line(id: "before", output: 1_000, date: now.addingTimeInterval(-2 * 3600)),           // outside the window
            line(id: "a", model: "claude-opus-5-5", input: 0, output: 1_000, cacheRead: 0),        // $0.02
            line(id: "b", model: "claude-haiku-5-5", input: 0, output: 1_000, cacheRead: 90_000, session: "s2"), // $0.0014
        ].joined(separator: "\n") + "\n")
        // Second project for "b".
        let other = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: #""cwd":"/Users/me/code/demo","requestId":"req_b""#,
                                  with: #""cwd":"/Users/me/code/other","requestId":"req_b""#)
        try other.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = await TranscriptScanner(roots: [root]).scan(now: now, windowStart: windowStart)
        let window = try #require(snapshot.window)
        #expect(!window.isApproximate)
        #expect(window.replies == 2)
        #expect(abs(window.cost - 0.0214) < 1e-9)
        // "other" used 91× the tokens, mostly cheap cache reads; cost decides the split.
        #expect(window.projects.map(\.name) == ["demo", "other"])
        #expect(abs(window.projects[0].share - 0.02 / 0.0214) < 1e-9)
    }

    @Test func fallsBackToTokenSharesForUnpricedModels() async throws {
        try append([
            line(id: "a", model: "claude-future-9", input: 0, output: 300, cacheRead: 0),
            line(id: "b", model: "claude-opus-5-5", input: 0, output: 100, cacheRead: 0),
        ].joined(separator: "\n") + "\n")
        let snapshot = await TranscriptScanner(roots: [root]).scan()
        let window = try #require(snapshot.window)
        #expect(window.isApproximate)
        #expect(window.projects.first?.share == 1) // both in "demo"
        #expect(snapshot.todayCostIsPartial)
        #expect(abs(snapshot.todayCost - 0.002) < 1e-9)
    }
}
