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
    static let serviceStatus = "serviceStatus"
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
    private(set) var status: ServiceStatus?

    @ObservationIgnored private let scanner = TranscriptScanner()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var nextAllowedFetch = Date.distantPast

    private static let apiInterval: Duration = .seconds(180)
    private static let localInterval: Duration = .seconds(60)
    private static let statusInterval: Duration = .seconds(300)

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
        Task {
            while !Task.isCancelled {
                await refreshStatus()
                try? await Task.sleep(for: Self.statusInterval)
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
            await refreshStatus()
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
            // The first local scan may have run before the session window was known.
            if local?.window?.isApproximate ?? false { await refreshLocal() }
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
        let windowStart = sessionLimit?.resetsAt.map { $0.addingTimeInterval(-(sessionLimit?.windowLength ?? 0)) }
        local = await scanner.scan(windowStart: windowStart)
    }

    func refreshStatus() async {
        guard UserDefaults.standard.object(forKey: Prefs.serviceStatus) as? Bool ?? true else {
            status = nil
            return
        }
        // Keep the last known status on failure; the status page being down isn't news on its own.
        if let fresh = try? await ServiceStatus.fetch() { status = fresh }
    }

    /// Replaces live data with fixed values; used for screenshots.
    func show(usage: UsageSnapshot, local: LocalSnapshot, status: ServiceStatus?, plan: String?, orgName: String?) {
        self.usage = usage
        self.status = status
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
