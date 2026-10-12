import AppKit
import SwiftUI

/// Renders the popover to a PNG and exits, without touching the menu bar:
///
///     ClaudeBar --snapshot out.png [--dark] [--demo]
///
/// `--demo` swaps in made-up data and frames the popover under a menu bar item,
/// which is how the README screenshots are produced (`make screenshots`).
enum Snapshot {
    static var outputPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isActive: Bool { outputPath != nil }

    @MainActor
    static func run(to path: String) {
        let args = CommandLine.arguments
        let dark = args.contains("--dark"), demo = args.contains("--demo")
        Task { @MainActor in
            let store = UsageStore.shared
            if demo {
                store.show(usage: DemoData.usage, local: DemoData.local, plan: "Max 20x", orgName: nil)
            } else {
                await store.refreshUsage(force: true)
                await store.refreshLocal()
            }
            let popover = PopoverView()
                .environment(store)
                .background(Color(nsColor: .windowBackgroundColor))
            let content = Group {
                if demo { Hero(popover: popover, dark: dark) } else { popover }
            }
            .environment(\.colorScheme, dark ? .dark : .light)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

private struct Hero<Popover: View>: View {
    let popover: Popover
    let dark: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(nsImage: StatusImage.render(outer: 0.42, inner: nil, text: "42%", alert: false))
                    .renderingMode(.template)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 26)

            popover
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 24, y: 10)
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
        .padding(.bottom, 48)
        .background(
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.16, green: 0.12, blue: 0.13), Color(red: 0.08, green: 0.08, blue: 0.10)]
                    : [Color(red: 0.99, green: 0.93, blue: 0.89), Color(red: 0.93, green: 0.92, blue: 0.96)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

private enum DemoData {
    static var usage: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(
            limits: [
                UsageLimit(kind: "session", group: "session", percent: 42, severity: "normal",
                           resetsAt: now.addingTimeInterval(2 * 3600 + 5 * 60), scopeName: nil),
                UsageLimit(kind: "weekly_all", group: "weekly", percent: 58, severity: "normal",
                           resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600), scopeName: nil),
                UsageLimit(kind: "weekly_scoped", group: "weekly", percent: 81, severity: "warning",
                           resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600), scopeName: "Opus"),
            ],
            spend: Spend(used: 12.4, limit: 50, currency: "USD", enabled: true),
            fetchedAt: now
        )
    }

    static var local: LocalSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let millions = [18, 32, 0, 41, 27, 55, 12, 0, 0, 36, 61, 44, 29, 48.6]
        var snapshot = LocalSnapshot()
        snapshot.todayTokens = 48_600_000
        snapshot.todayOutput = 412_000
        snapshot.todayMessages = 386
        snapshot.todaySessions = 7
        snapshot.activeSessions = 2
        snapshot.daily = millions.enumerated().map { i, m in
            DayBucket(date: calendar.date(byAdding: .day, value: i - (millions.count - 1), to: today)!,
                      tokens: Int(m * 1_000_000))
        }
        snapshot.models = [
            NamedCount(name: "Opus 5.5", value: 78), NamedCount(name: "Sonnet 5.5", value: 15),
            NamedCount(name: "Haiku 5.5", value: 7),
        ]
        snapshot.topProjects = [
            NamedCount(name: "menubar-app", value: 21_400_000),
            NamedCount(name: "api-gateway", value: 15_900_000),
            NamedCount(name: "dotfiles", value: 4_200_000),
        ]
        return snapshot
    }
}
