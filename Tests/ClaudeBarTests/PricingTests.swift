import Foundation
import Testing
@testable import ClaudeBar

@Suite("API cost estimate")
struct PricingTests {
    @Test func pricesEveryTokenType() throws {
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, $5 / $8 cache writes (5 m / 1 h), per million.
        let usage = ModelCatalog.Usage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                                       cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let cost = try #require(ModelCatalog.cost(model: "claude-opus-5-5", usage: usage))
        #expect(abs(cost - (4 + 20 + 0.2 + 5 + 8)) < 1e-9)
    }

    @Test func doublesFastMode() throws {
        let usage = ModelCatalog.Usage(output: 1_000_000, fast: true)
        #expect(try #require(ModelCatalog.cost(model: "claude-opus-5-5", usage: usage)) == 40)
    }

    @Test func usesHaikuLongContextRates() throws {
        let short = ModelCatalog.Usage(input: 100_000, output: 0)
        let long = ModelCatalog.Usage(input: 100_001, output: 0)
        #expect(abs(try #require(ModelCatalog.cost(model: "claude-haiku-5-5", usage: short)) - 0.01) < 1e-9)
        #expect(abs(try #require(ModelCatalog.cost(model: "claude-haiku-5-5", usage: long)) - 0.0500005) < 1e-9)
    }

    @Test(arguments: [
        ("claude-sonnet-4-5-20250929", 3.0),
        ("claude-opus-4-20250514", 15.0),
        ("claude-3-5-haiku-20241022", 0.8),
        ("claude-fable-5-1", 10.0),
        ("claude-opus-5", 5.0),
    ])
    func resolvesDatedAndLegacyIDs(id: String, input: Double) {
        #expect(ModelCatalog.price(for: id)?.input == input)
    }

    @Test func unknownModelsHaveNoPrice() {
        #expect(ModelCatalog.cost(model: "claude-future-9", usage: .init(input: 1)) == nil)
    }

    @Test func splitsCacheWritesByTTL() {
        let usage = TranscriptScanner.usage(from: [
            "input_tokens": 1, "output_tokens": 2, "cache_read_input_tokens": 3,
            "cache_creation_input_tokens": 10,
            "cache_creation": ["ephemeral_1h_input_tokens": 7, "ephemeral_5m_input_tokens": 3],
            "speed": "fast",
        ])
        #expect(usage.cacheWrite1h == 7)
        #expect(usage.cacheWrite5m == 3)
        #expect(usage.total == 16)
        #expect(usage.fast)
    }

    @Test func treatsUnsplitCacheWritesAsFiveMinute() {
        let usage = TranscriptScanner.usage(from: ["cache_creation_input_tokens": 10])
        #expect(usage.cacheWrite5m == 10)
        #expect(usage.cacheWrite1h == 0)
    }
}

@Suite("Service status")
struct ServiceStatusTests {
    private func parse(_ text: String) throws -> ServiceStatus {
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        return try #require(ServiceStatus.parse(json))
    }

    @Test func operational() throws {
        let status = try parse("""
        {"status": {"indicator": "none", "description": "All Systems Operational"},
         "components": [{"name": "Claude Code", "status": "operational"}], "incidents": []}
        """)
        #expect(status.isOperational)
        #expect(!status.deservesBanner)
    }

    @Test func consoleOnlyIncidentStaysQuiet() throws {
        let status = try parse("""
        {"status": {"indicator": "minor", "description": "Partially Degraded Service"},
         "components": [{"name": "Claude Console (platform.claude.com)", "status": "degraded_performance"},
                        {"name": "Claude Code", "status": "operational"}],
         "incidents": [{"id": "x", "name": "Elevated errors on platform.claude.com", "impact": "major",
                        "status": "monitoring", "shortlink": "https://stspg.io/x",
                        "components": [{"name": "Claude Console (platform.claude.com)"}]}]}
        """)
        #expect(!status.isOperational)
        #expect(!status.affectsClaudeCode)
        #expect(!status.deservesBanner)
        #expect(status.incidents.first?.url == URL(string: "https://stspg.io/x"))
    }

    @Test func claudeCodeOutageIsFlagged() throws {
        let status = try parse("""
        {"status": {"indicator": "minor", "description": "Partially Degraded Service"},
         "components": [{"name": "Claude API (api.anthropic.com)", "status": "partial_outage"},
                        {"name": "Claude Code", "status": "degraded_performance"}],
         "incidents": []}
        """)
        #expect(status.degraded == ["Claude API (api.anthropic.com)", "Claude Code"])
        #expect(status.affectsClaudeCode)
        #expect(status.deservesBanner)
    }
}
