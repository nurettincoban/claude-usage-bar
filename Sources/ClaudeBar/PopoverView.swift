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
}

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.menuBarMode) private var mode: MenuBarMode = .session
    @AppStorage(Prefs.notifications) private var notifications = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = store.error {
                    ErrorBanner(error: error)
                }
                limits(now: context.date)
                if let local = store.local {
                    Divider().opacity(0.6)
                    LocalSection(local: local)
                }
                footer(now: context.date)
            }
            .padding(16)
        }
        .frame(width: 332)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refreshIfStale()
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
        HStack {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Claude Code today · this Mac")
                Spacer()
                if local.activeSessions > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(local.activeSessions) active")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                StatTile(value: Fmt.compact(local.todayTokens), label: "tokens")
                StatTile(value: Fmt.compact(local.todayOutput), label: "output")
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

            if !local.topProjects.isEmpty {
                VStack(spacing: 6) {
                    let top = local.topProjects.prefix(3)
                    ForEach(top) { ProjectRow(item: $0, peak: top.first?.value ?? 1) }
                }
            }
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
        let active = days.filter { $0.tokens > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.tokens } / active.count
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
                Text("avg \(Fmt.compact(average)) tokens / active day")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }
}

struct ProjectRow: View {
    let item: NamedCount
    let peak: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.accent.opacity(0.45))
                    .frame(width: max(3, geo.size.width * Double(item.value) / Double(max(peak, 1))))
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 4)
            Text(Fmt.compact(item.value))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
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
