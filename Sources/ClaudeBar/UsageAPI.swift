import Foundation

// MARK: - Models

struct UsageLimit: Identifiable, Hashable, Sendable {
    let kind: String
    let group: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    let scopeName: String?

    var id: String { kind + "|" + (scopeName ?? "") }

    var title: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Weekly · all models"
        case "weekly_scoped": return "Weekly · \(scopeName ?? "scoped")"
        default:
            let base = kind.replacingOccurrences(of: "_", with: " ").capitalized
            return scopeName.map { "\(base) · \($0)" } ?? base
        }
    }

    var windowLength: TimeInterval { group == "session" ? 5 * 3600 : 7 * 86400 }

    /// How far through the current window we are, and where usage is heading at the current rate.
    func pace(at now: Date) -> (elapsed: Double, projected: Double?, hitsAt: Date?) {
        guard let resetsAt else { return (0, nil, nil) }
        let start = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = now.timeIntervalSince(start)
        let fraction = min(max(elapsed / windowLength, 0), 1)
        // Too early in the window to extrapolate meaningfully.
        guard fraction > 0.08, percent > 0 else { return (fraction, nil, nil) }
        let projected = percent / fraction
        let hitsAt = projected > 100 && percent < 100
            ? start.addingTimeInterval(elapsed * 100 / percent)
            : nil
        return (fraction, projected, hitsAt)
    }
}

struct Spend: Hashable, Sendable {
    let used: Double
    let limit: Double?
    let currency: String
    let enabled: Bool
}

struct UsageSnapshot: Sendable {
    let limits: [UsageLimit]
    let spend: Spend?
    let fetchedAt: Date
}

struct Profile: Sendable {
    let orgName: String?
    let displayName: String?
}

struct Credentials: Sendable {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?

    /// "max" + "default_claude_max_20x" → "Max 20x"; "team" + "…_max_5x" → "Team · Max 5x".
    var planName: String? {
        let plan = subscriptionType.flatMap { $0.isEmpty ? nil : $0.capitalized }
        let tier: String? = switch rateLimitTier {
        case let t? where t.contains("max_20x"): "Max 20x"
        case let t? where t.contains("max_5x"): "Max 5x"
        default: nil
        }
        guard let tier else { return plan }
        guard let plan, plan != "Max" else { return tier }
        return "\(plan) · \(tier)"
    }
}

enum UsageError: Error, Equatable {
    case notSignedIn
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case decoding

    var title: String {
        switch self {
        case .notSignedIn: return "Not signed in to Claude Code"
        case .unauthorized: return "Login token expired"
        case .rateLimited: return "Rate limited by Anthropic"
        case .http(let code): return "Usage request failed (\(code))"
        case .network: return "Can't reach Anthropic"
        case .decoding: return "Unexpected usage response"
        }
    }

    var hint: String {
        switch self {
        case .notSignedIn: return "Run `claude` and use /login. ClaudeBar reuses that login."
        case .unauthorized: return "Run any Claude Code command so it refreshes the token, then refresh here."
        case .rateLimited: return "Backing off for a few minutes."
        case .http: return "Will retry automatically."
        case .network(let message): return message
        case .decoding: return "The API shape may have changed."
        }
    }
}

// MARK: - Credentials

/// Reads the OAuth login that Claude Code stores. We never refresh the token ourselves:
/// rotating the refresh token here would log Claude Code out.
enum CredentialStore {
    static func load() throws -> Credentials {
        if let data = keychainData() ?? fileData(), let creds = parse(data) {
            return creds
        }
        throw UsageError.notSignedIn
    }

    // `security` created the item, so reading through it does not trigger a keychain prompt.
    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func fileData() -> Data? {
        try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"))
    }

    static func parse(_ data: Data) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return Credentials(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

// MARK: - API

enum UsageAPI {
    private static let base = URL(string: "https://api.anthropic.com/api/oauth/")!

    static func fetchUsage(token: String) async throws -> UsageSnapshot {
        try parseUsage(try await get("usage", token: token))
    }

    static func parseUsage(_ json: [String: Any], fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let limits = parseLimits(json)
        guard !limits.isEmpty else { throw UsageError.decoding }
        return UsageSnapshot(limits: limits, spend: parseSpend(json), fetchedAt: fetchedAt)
    }

    static func fetchProfile(token: String) async throws -> Profile {
        let json = try await get("profile", token: token)
        let org = json["organization"] as? [String: Any]
        let account = json["account"] as? [String: Any]
        return Profile(orgName: org?["name"] as? String, displayName: account?["display_name"] as? String)
    }

    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeBar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.decoding }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retry)
        default: throw UsageError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding
        }
        return json
    }

    private static func parseLimits(_ json: [String: Any]) -> [UsageLimit] {
        if let list = json["limits"] as? [[String: Any]], !list.isEmpty {
            return list.map { item in
                let scope = item["scope"] as? [String: Any]
                let scopeName = displayName(scope?["model"]) ?? displayName(scope?["surface"])
                return UsageLimit(
                    kind: item["kind"] as? String ?? "limit",
                    group: item["group"] as? String ?? "weekly",
                    percent: number(item["percent"]),
                    severity: item["severity"] as? String ?? "normal",
                    resetsAt: date(item["resets_at"]),
                    scopeName: scopeName
                )
            }
        }
        // Older response shape.
        let legacy: [(key: String, kind: String, group: String, scope: String?)] = [
            ("five_hour", "session", "session", nil),
            ("seven_day", "weekly_all", "weekly", nil),
            ("seven_day_opus", "weekly_scoped", "weekly", "Opus"),
            ("seven_day_sonnet", "weekly_scoped", "weekly", "Sonnet"),
        ]
        return legacy.compactMap { entry in
            guard let window = json[entry.key] as? [String: Any] else { return nil }
            return UsageLimit(
                kind: entry.kind, group: entry.group,
                percent: number(window["utilization"]), severity: "normal",
                resetsAt: date(window["resets_at"]), scopeName: entry.scope
            )
        }
    }

    private static func parseSpend(_ json: [String: Any]) -> Spend? {
        if let spend = json["spend"] as? [String: Any], let used = money(spend["used"]) {
            return Spend(
                used: used.value,
                limit: money(spend["limit"])?.value,
                currency: used.currency,
                enabled: spend["enabled"] as? Bool ?? false
            )
        }
        if let extra = json["extra_usage"] as? [String: Any] {
            let scale = pow(10, number(extra["decimal_places"]))
            return Spend(
                used: number(extra["used_credits"]) / scale,
                limit: (extra["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale },
                currency: extra["currency"] as? String ?? "USD",
                enabled: extra["is_enabled"] as? Bool ?? false
            )
        }
        return nil
    }

    private static func money(_ any: Any?) -> (value: Double, currency: String)? {
        guard let dict = any as? [String: Any], let minor = dict["amount_minor"] as? NSNumber else { return nil }
        let exponent = number(dict["exponent"])
        return (minor.doubleValue / pow(10, exponent), dict["currency"] as? String ?? "USD")
    }

    private static func displayName(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let dict = any as? [String: Any] { return (dict["display_name"] ?? dict["id"]) as? String }
        return nil
    }

    private static func number(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? 0 }

    static func date(_ any: Any?) -> Date? {
        guard var string = any as? String else { return nil }
        // ISO8601DateFormatter rejects microsecond precision, so drop the fraction.
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
            string.removeSubrange(range)
        }
        return ISO8601DateFormatter().date(from: string)
    }
}
