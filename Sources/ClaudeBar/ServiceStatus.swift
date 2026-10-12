import Foundation

/// Anthropic's public status page (status.claude.com). No credentials are sent.
struct ServiceStatus: Sendable, Equatable {
    struct Incident: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let impact: String
        let status: String
        let url: URL?
        let components: [String]
    }

    /// Statuspage's overall indicator: none, minor, major, critical or maintenance.
    let indicator: String
    let summary: String
    let incidents: [Incident]
    /// Components Claude Code users depend on that are not fully operational.
    let degraded: [String]

    var isOperational: Bool { indicator == "none" && incidents.isEmpty }

    /// Worth flagging in the menu bar: something ClaudeBar's users actually rely on is affected.
    var affectsClaudeCode: Bool { !degraded.isEmpty }

    /// Full banner for incidents that matter here; anything else (e.g. only the Console) gets a footer dot.
    var deservesBanner: Bool { affectsClaudeCode || indicator == "major" || indicator == "critical" }

    static let pageURL = URL(string: "https://status.claude.com")!
    private static let summaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    /// Matched case-insensitively against component names.
    private static let relevantComponents = ["claude.ai", "claude api", "claude code"]

    static func fetch() async throws -> ServiceStatus {
        var request = URLRequest(url: summaryURL, timeoutInterval: 15)
        request.setValue("ClaudeBar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = parse(json) else { throw UsageError.decoding }
        return status
    }

    static func parse(_ json: [String: Any]) -> ServiceStatus? {
        guard let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String else { return nil }

        let incidents = (json["incidents"] as? [[String: Any]] ?? []).map { item in
            Incident(
                id: item["id"] as? String ?? UUID().uuidString,
                name: item["name"] as? String ?? "Incident",
                impact: item["impact"] as? String ?? "none",
                status: item["status"] as? String ?? "",
                url: (item["shortlink"] as? String).flatMap(URL.init(string:)),
                components: (item["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            )
        }
        let degraded = (json["components"] as? [[String: Any]] ?? []).compactMap { component -> String? in
            guard let name = component["name"] as? String,
                  let state = component["status"] as? String, state != "operational",
                  relevantComponents.contains(where: { name.lowercased().hasPrefix($0) }) else { return nil }
            return name
        }
        return ServiceStatus(
            indicator: indicator,
            summary: status["description"] as? String ?? "",
            incidents: incidents,
            degraded: degraded
        )
    }
}
