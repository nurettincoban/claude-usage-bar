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
        #expect(snapshot.topProjects.first?.name == "demo")
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
        #expect(TranscriptScanner.modelName(id) == expected)
    }
}
