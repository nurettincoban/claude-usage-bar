import Foundation

/// Model id → display name and API list prices, used to estimate what Claude Code usage
/// would have cost at pay-as-you-go API rates.
enum ModelCatalog {
    struct Price: Equatable, Sendable {
        let input: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let output: Double
    }

    /// Token counts from one response's `usage` block.
    struct Usage: Sendable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        var fast = false

        var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
        var prompt: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }
    }

    /// USD per million tokens, from https://platform.claude.com/docs/en/about-claude/pricing (2026-10-12).
    /// Keyed by "family version" as produced by `key(for:)`.
    private static let prices: [String: Price] = [
        "fable 5.1": Price(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "mythos 5.1": Price(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "fable 5": Price(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "mythos 5": Price(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "opus 5.5": Price(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20),
        "opus 5": opus45,
        "opus 4.8": opus45,
        "opus 4.7": opus45,
        "opus 4.6": opus45,
        "opus 4.5": opus45,
        "opus 4.1": opus4,
        "opus 4": opus4,
        "sonnet 5.5": Price(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.1, output: 10),
        "sonnet 5": Price(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10),
        "sonnet 4.6": sonnet4,
        "sonnet 4.5": sonnet4,
        "sonnet 4": sonnet4,
        "haiku 5.5": Price(input: 0.1, cacheWrite5m: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01, output: 0.5),
        "haiku 4.5": Price(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5),
        "haiku 3.5": Price(input: 0.8, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08, output: 4),
    ]
    private static let opus45 = Price(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25)
    private static let opus4 = Price(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5, output: 75)
    private static let sonnet4 = Price(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3, output: 15)

    /// Haiku 5.5 prompts over 100K tokens are billed at higher rates.
    private static let haiku55Long = Price(input: 0.5, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05, output: 2.5)

    /// "claude-opus-5-5" → ("opus", "5.5"), "claude-3-5-haiku-20241022" → ("haiku", "3.5").
    static func parse(_ id: String) -> (family: String, version: String) {
        let parts = id.lowercased().replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        let family = parts.first { $0.contains(where: \.isLetter) }.map(String.init) ?? id
        let version = parts.filter { $0.allSatisfy(\.isNumber) && $0.count < 4 }.joined(separator: ".")
        return (family, version)
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func displayName(_ id: String) -> String {
        let (family, version) = parse(id)
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    static func price(for id: String, promptTokens: Int = 0) -> Price? {
        let (family, version) = parse(id)
        let key = "\(family) \(version)"
        if key == "haiku 5.5", promptTokens > 100_000 { return haiku55Long }
        return prices[key]
    }

    /// Estimated USD cost, or nil for models without a known price.
    static func cost(model: String, usage: Usage) -> Double? {
        guard let p = price(for: model, promptTokens: usage.prompt) else { return nil }
        let dollars = (Double(usage.input) * p.input
            + Double(usage.output) * p.output
            + Double(usage.cacheRead) * p.cacheRead
            + Double(usage.cacheWrite5m) * p.cacheWrite5m
            + Double(usage.cacheWrite1h) * p.cacheWrite1h) / 1_000_000
        // Fast mode is billed at twice the standard rates.
        return usage.fast ? dollars * 2 : dollars
    }
}
