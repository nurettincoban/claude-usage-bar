import Foundation
import Testing
@testable import ClaudeBar

@Suite("Usage response parsing")
struct UsageAPITests {
    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    @Test func parsesLimitsList() throws {
        let snapshot = try UsageAPI.parseUsage(json("""
        {"limits": [
          {"kind": "session", "group": "session", "percent": 6, "severity": "normal",
           "resets_at": "2026-10-12T16:10:00.047401+00:00", "scope": null, "is_active": true},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 12.5, "severity": "normal",
           "resets_at": "2026-10-19T08:00:00+00:00",
           "scope": {"model": {"id": null, "display_name": "Opus"}, "surface": null}}
        ]}
        """))

        #expect(snapshot.limits.count == 2)
        let session = snapshot.limits[0]
        #expect(session.title == "Session")
        #expect(session.percent == 6)
        #expect(session.windowLength == 5 * 3600)
        #expect(session.resetsAt == UsageAPI.date("2026-10-12T16:10:00Z"))

        let weekly = snapshot.limits[1]
        #expect(weekly.title == "Weekly · Opus")
        #expect(weekly.percent == 12.5)
        #expect(weekly.windowLength == 7 * 86400)
    }

    @Test func fallsBackToLegacyShape() throws {
        let snapshot = try UsageAPI.parseUsage(json("""
        {"five_hour": {"utilization": 30.0, "resets_at": "2026-10-12T16:10:00.123+00:00"},
         "seven_day": {"utilization": 10.0, "resets_at": "2026-10-19T08:00:00+00:00"},
         "seven_day_opus": null}
        """))
        #expect(snapshot.limits.map(\.kind) == ["session", "weekly_all"])
        #expect(snapshot.limits.map(\.percent) == [30, 10])
    }

    @Test func rejectsResponseWithoutLimits() {
        #expect(throws: UsageError.decoding) { try UsageAPI.parseUsage(json(#"{"foo": 1}"#)) }
    }

    @Test func parsesSpendInMinorUnits() throws {
        let snapshot = try UsageAPI.parseUsage(json("""
        {"limits": [{"kind": "session", "group": "session", "percent": 1}],
         "spend": {"used": {"amount_minor": 1240, "currency": "EUR", "exponent": 2},
                   "limit": {"amount_minor": 5000, "currency": "EUR", "exponent": 2},
                   "enabled": true}}
        """))
        #expect(snapshot.spend == Spend(used: 12.4, limit: 50, currency: "EUR", enabled: true))
    }

    @Test func parsesLegacyExtraUsage() throws {
        let snapshot = try UsageAPI.parseUsage(json("""
        {"limits": [{"kind": "session", "group": "session", "percent": 1}],
         "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 250,
                         "currency": "USD", "decimal_places": 2}}
        """))
        #expect(snapshot.spend == Spend(used: 2.5, limit: 50, currency: "USD", enabled: true))
    }

    @Test(arguments: [
        ("2026-10-12T16:10:00.047401+00:00", 1_791_821_400.0),
        ("2026-10-12T16:10:00+00:00", 1_791_821_400.0),
        ("2026-10-12T16:10:00Z", 1_791_821_400.0),
    ])
    func parsesDatesWithAnyPrecision(input: String, epoch: Double) {
        #expect(UsageAPI.date(input)?.timeIntervalSince1970 == epoch)
    }
}

@Suite("Credentials")
struct CredentialsTests {
    @Test func readsClaudeCodeCredentialJSON() throws {
        let data = Data(#"{"claudeAiOauth": {"accessToken": "tok", "subscriptionType": "team", "rateLimitTier": "default_claude_max_5x"}}"#.utf8)
        let creds = try #require(CredentialStore.parse(data))
        #expect(creds.accessToken == "tok")
        #expect(creds.planName == "Team · Max 5x")
    }

    @Test(arguments: [
        ("max", "default_claude_max_20x", "Max 20x"),
        ("pro", nil, "Pro"),
        (nil, "default_claude_max_5x", "Max 5x"),
    ] as [(String?, String?, String)])
    func formatsPlanName(subscription: String?, tier: String?, expected: String) {
        let creds = Credentials(accessToken: "", subscriptionType: subscription, rateLimitTier: tier)
        #expect(creds.planName == expected)
    }

    @Test func ignoresUnrelatedJSON() {
        #expect(CredentialStore.parse(Data(#"{"mcpOAuth": {}}"#.utf8)) == nil)
    }
}
