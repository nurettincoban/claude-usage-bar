import Foundation
import Testing
@testable import ClaudeBar

@Suite("Pace projection")
struct PaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(percent: Double, hoursLeft: Double) -> UsageLimit {
        UsageLimit(kind: "session", group: "session", percent: percent, severity: "normal",
                   resetsAt: now.addingTimeInterval(hoursLeft * 3600), scopeName: nil)
    }

    @Test func projectsUsageAtReset() throws {
        // Halfway through the 5 h window at 20 % → heading for 40 %.
        let pace = session(percent: 20, hoursLeft: 2.5).pace(at: now)
        #expect(pace.elapsed == 0.5)
        #expect(try #require(pace.projected) == 40)
        #expect(pace.hitsAt == nil)
    }

    @Test func predictsWhenLimitIsHit() throws {
        // 1 h into the window at 50 % → 100 % after 2 h, i.e. one hour from now.
        let pace = session(percent: 50, hoursLeft: 4).pace(at: now)
        #expect(try #require(pace.hitsAt) == now.addingTimeInterval(3600))
    }

    @Test func staysQuietEarlyInTheWindow() {
        let pace = session(percent: 5, hoursLeft: 4.9).pace(at: now)
        #expect(pace.projected == nil)
    }

    @Test func noPredictionOnceLimitIsReached() {
        #expect(session(percent: 100, hoursLeft: 1).pace(at: now).hitsAt == nil)
    }

    static let durations: [(Double, String)] = [
        (59, "0m"), (600, "10m"), (10_920, "3h 2m"), (176_400, "2d 1h"), (-30, "0m"),
    ]

    @Test(arguments: durations)
    func formatsDurations(seconds: Double, expected: String) {
        #expect(Fmt.duration(seconds) == expected)
    }
}
