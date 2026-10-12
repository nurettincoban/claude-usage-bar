import Foundation
import Observation
import UserNotifications

enum MenuBarMode: String, CaseIterable, Identifiable {
    case session, both, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "Session %"
        case .both: return "Session + weekly %"
        case .icon: return "Icon only"
        }
    }
}

enum Prefs {
    static let menuBarMode = "menuBarMode"
    static let notifications = "notifications"
    static let sentAlerts = "sentAlerts"
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var usage: UsageSnapshot?
    private(set) var local: LocalSnapshot?
    private(set) var profile: Profile?
    private(set) var plan: String?
    private(set) var error: UsageError?
    private(set) var isLoading = false

    @ObservationIgnored private let scanner = TranscriptScanner()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var nextAllowedFetch = Date.distantPast

    private static let apiInterval: Duration = .seconds(180)
    private static let localInterval: Duration = .seconds(60)

    var sessionLimit: UsageLimit? { usage?.limits.first { $0.group == "session" } }
    var weeklyLimit: UsageLimit? {
        usage?.limits.filter { $0.group == "weekly" }.max { $0.percent < $1.percent }
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await refreshUsage()
                try? await Task.sleep(for: Self.apiInterval)
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshLocal()
                try? await Task.sleep(for: Self.localInterval)
            }
        }
        if notificationsEnabled, Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Called when the popover opens.
    func refreshIfStale() {
        if let usage, Date().timeIntervalSince(usage.fetchedAt) < 30 { return }
        Task {
            await refreshUsage()
            await refreshLocal()
        }
    }

    func refreshNow() {
        Task {
            await refreshUsage(force: true)
            await refreshLocal()
        }
    }

    func refreshUsage(force: Bool = false) async {
        guard !isLoading, force || Date() >= nextAllowedFetch else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let creds = try await Task.detached { try CredentialStore.load() }.value
            plan = creds.planName
            let snapshot = try await UsageAPI.fetchUsage(token: creds.accessToken)
            usage = snapshot
            error = nil
            notifyIfNeeded(snapshot)
            if profile == nil {
                profile = try? await UsageAPI.fetchProfile(token: creds.accessToken)
            }
        } catch let failure as UsageError {
            error = failure
            if case .rateLimited(let retryAfter) = failure {
                nextAllowedFetch = Date().addingTimeInterval(retryAfter ?? 300)
            }
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    func refreshLocal() async {
        local = await scanner.scan()
    }

    /// Replaces live data with fixed values; used for screenshots.
    func show(usage: UsageSnapshot, local: LocalSnapshot, plan: String?, orgName: String?) {
        self.usage = usage
        self.local = local
        self.plan = plan
        self.profile = Profile(orgName: orgName, displayName: nil)
        self.error = nil
    }

    // MARK: - Notifications

    private var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: Prefs.notifications) as? Bool ?? true
    }

    /// One alert per limit, threshold and reset window.
    private func notifyIfNeeded(_ snapshot: UsageSnapshot) {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let defaults = UserDefaults.standard
        var sent = defaults.stringArray(forKey: Prefs.sentAlerts) ?? []

        for limit in snapshot.limits {
            let window = Int((limit.resetsAt?.timeIntervalSince1970 ?? 0) / 60)
            let thresholds = [95, 80]
            guard let crossed = thresholds.first(where: { limit.percent >= Double($0) }) else { continue }
            let key = "\(limit.id)|\(window)|\(crossed)"
            guard !sent.contains(key) else { continue }
            // Crossing 95 implies 80 was crossed too; don't send that one later.
            sent += thresholds.filter { $0 <= crossed }.map { "\(limit.id)|\(window)|\($0)" }

            let content = UNMutableNotificationContent()
            content.title = "\(limit.title) at \(Int(limit.percent))%"
            if let resetsAt = limit.resetsAt {
                content.body = "Resets in \(Fmt.duration(resetsAt.timeIntervalSinceNow)) (\(Fmt.clock(resetsAt)))."
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        defaults.set(Array(sent.suffix(60)), forKey: Prefs.sentAlerts)
    }
}
