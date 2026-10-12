import Charts
import ServiceManagement
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341) // Claude coral

    static func tint(for percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 75 ? .orange : accent
    }
}

enum Fmt {
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
    }

    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func money(_ value: Double, _ currency: String) -> String {
        value.formatted(.currency(code: currency))
    }

    /// API cost estimates: cents below $100, whole dollars above.
    static func usd(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").presentation(.narrow)
        if value > 0, value < 0.01 { return "<" + 0.01.formatted(style) }
        return value.formatted(style.precision(.fractionLength(value >= 100 ? 0 : 2)))
    }
}

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.menuBarMode) private var mode: MenuBarMode = .session
    @AppStorage(Prefs.notifications) private var notifications = true
    @AppStorage(Prefs.serviceStatus) private var showStatus = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 16) {
                header
                if let status = store.status, status.deservesBanner {
                    StatusBanner(status: status)
                }
                if let error = store.error {
                    ErrorBanner(error: error)
                }
                limits(now: context.date)
                if let local = store.local {
                    Divider().opacity(0.6)
                    LocalSection(local: local, showsWindow: store.usage != nil || store.error != nil)
                }
                footer(now: context.date)
            }
            .padding(16)
        }
        .frame(width: 332)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refreshIfStale()
        }
        .onChange(of: showStatus) {
            Task { await store.refreshStatus() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Usage")
                    .font(.system(size: 13, weight: .semibold))
                Text([store.plan, store.profile?.orgName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: store.refreshNow) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: store.isLoading)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh")
            if Snapshot.isActive {
                // ImageRenderer can't draw AppKit-backed menus.
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            } else {
                settingsMenu
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Menu bar shows", selection: $mode) {
                ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Alerts at 80% and 95%", isOn: $notifications)
            Toggle("Show Anthropic status", isOn: $showStatus)
            Toggle("Launch at login", isOn: launchAtLogin)
            Divider()
            Button("Quit ClaudeBar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        )
    }

    // MARK: Limits

    @ViewBuilder
    private func limits(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Plan limits")
            if let usage = store.usage {
                ForEach(usage.limits) { LimitRow(limit: $0, now: now) }
                if let spend = usage.spend, spend.enabled {
                    SpendRow(spend: spend)
                }
            } else if store.error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Footer

    private func footer(now: Date) -> some View {
        HStack(spacing: 6) {
            if let status = store.status, !status.deservesBanner {
                let count = status.incidents.count
                Link(destination: ServiceStatus.pageURL) {
                    HStack(spacing: 4) {
                        Circle().fill(status.isOperational ? .green : .yellow).frame(width: 6, height: 6)
                        Text(status.isOperational ? "Operational" : count == 1 ? "1 incident" : "\(max(count, 1)) incidents")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(status.isOperational
                    ? "All Claude systems operational: status.claude.com"
                    : status.incidents.map(\.name).joined(separator: "\n"))
                Text("·")
            }
            if let fetched = store.usage?.fetchedAt {
                let age = now.timeIntervalSince(fetched)
                Text(age < 60 ? "Updated just now" : "Updated \(Fmt.duration(age)) ago")
            }
            Spacer()
            Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                HStack(spacing: 3) {
                    Text("claude.ai usage")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Limits

struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        let pace = limit.pace(at: now)
        let tint = Theme.tint(for: limit.percent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(limit.percent))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(limit.percent >= 75 ? tint : .primary)
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: limit.percent / 100, marker: limit.resetsAt == nil ? nil : pace.elapsed, tint: tint)
            HStack {
                if let resetsAt = limit.resetsAt {
                    Text("Resets in \(Fmt.duration(resetsAt.timeIntervalSince(now)))")
                        .help(Fmt.clock(resetsAt))
                }
                Spacer()
                paceText(pace)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func paceText(_ pace: (elapsed: Double, projected: Double?, hitsAt: Date?)) -> some View {
        if limit.percent >= 100 {
            Text("Limit reached").foregroundStyle(.red)
        } else if let hitsAt = pace.hitsAt {
            Text("At this pace: limit ~\(Fmt.clock(hitsAt))").foregroundStyle(.orange)
        } else if let projected = pace.projected {
            Text("On pace for ~\(Int(projected))%")
        }
    }
}

/// Capsule progress bar. The thin tick marks how much of the window has elapsed, so usage
/// to the right of it means you're spending faster than an even pace.
struct UsageBar: View {
    let fraction: Double
    let marker: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if fraction > 0 {
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(6, geo.size.width * min(fraction, 1)))
                }
                if let marker, marker > 0, marker < 1 {
                    Capsule()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * marker - 1)
                }
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

struct SpendRow: View {
    let spend: Spend

    var body: some View {
        HStack {
            Text("Extra usage")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Group {
                Text(Fmt.money(spend.used, spend.currency))
                    .foregroundStyle(.primary)
                if let limit = spend.limit {
                    Text("/ \(Fmt.money(limit, spend.currency))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, design: .rounded))
            .monospacedDigit()
        }
    }
}

// MARK: - Local stats

struct LocalSection: View {
    let local: LocalSnapshot
    /// Hidden until we know whether plan limits are available, to avoid flashing the approximate window.
    let showsWindow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsWindow, let window = local.window {
                WindowSection(window: window, activeSessions: local.activeSessions)
            }
            today
        }
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Claude Code today · this Mac")

            HStack(spacing: 6) {
                StatTile(value: Fmt.compact(local.todayTokens), label: "tokens")
                StatTile(value: Fmt.usd(local.todayCost), label: local.todayCostIsPartial ? "API value*" : "API value")
                    .help("What today's Claude Code usage would cost at pay-as-you-go API prices."
                        + (local.todayCostIsPartial ? " *Excludes models without a known price." : ""))
                StatTile(value: "\(local.todayMessages)", label: "replies")
                StatTile(value: "\(local.todaySessions)", label: "sessions")
            }

            if !local.models.isEmpty {
                let total = max(1, local.models.reduce(0) { $0 + $1.value })
                Text(local.models.prefix(3).map { "\($0.name) \(Int((Double($0.value) / Double(total) * 100).rounded()))%" }
                    .joined(separator: "  ·  "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            DailyChart(days: local.daily)
        }
    }
}

/// "What's eating your limit": this Mac's Claude Code usage since the session window opened.
struct WindowSection: View {
    let window: SessionWindow
    let activeSessions: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(window.isApproximate ? "Last 5 hours · this Mac" : "Using this session · this Mac")
                Spacer()
                if activeSessions > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(activeSessions) active")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            if window.replies == 0 {
                Text("No Claude Code usage in this window yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(window.projects.prefix(4)) { ShareRow(item: $0) }
                }
                HStack {
                    Text("≈ \(Fmt.usd(window.cost)) at API rates")
                    Spacer()
                    if window.projects.count > 4 {
                        Text("+\(window.projects.count - 4) more")
                    }
                    Text("since \(Fmt.clock(window.start))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .help("Each project's share of Claude Code usage on this Mac since the session window opened, "
            + "weighted by API cost. Usage on claude.ai or other devices counts toward the limit too, but isn't visible here.")
    }
}

struct ShareRow: View {
    let item: WindowShare

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule()
                        .fill(Theme.accent.opacity(0.7))
                        .frame(width: max(3, geo.size.width * min(item.share, 1)))
                }
            }
            .frame(height: 4)
            Text("\(Int((item.share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            Text(Fmt.usd(item.cost))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DailyChart: View {
    let days: [DayBucket]

    var body: some View {
        let cost = days.reduce(0) { $0 + $1.cost }
        VStack(alignment: .leading, spacing: 4) {
            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Tokens", day.tokens),
                    width: .ratio(0.65)
                )
                .cornerRadius(2)
                .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Theme.accent : Theme.accent.opacity(0.3))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
            HStack {
                Text("Last \(days.count) days")
                Spacer()
                Text("\(Fmt.compact(days.reduce(0) { $0 + $1.tokens })) tokens · ≈ \(Fmt.usd(cost)) at API rates")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }
}

struct StatusBanner: View {
    let status: ServiceStatus

    private var color: Color {
        let level = status.indicator == "none" ? (status.incidents.first?.impact ?? "minor") : status.indicator
        switch level {
        case "critical": return .red
        case "major": return .orange
        case "maintenance": return .blue
        default: return .yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status.summary.isEmpty ? "Service incident" : status.summary)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Link(destination: ServiceStatus.pageURL) {
                    HStack(spacing: 3) {
                        Text("Status")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            ForEach(status.incidents.prefix(2)) { incident in
                Text("\(incident.name) · \(incident.status.capitalized)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.degraded.isEmpty {
                Text("Affected: \(status.degraded.joined(separator: ", "))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color == .yellow ? .orange : color)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Small pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

struct ErrorBanner: View {
    let error: UsageError

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(error.hint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}
