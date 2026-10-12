import AppKit
import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var store = UsageStore.shared

    init() {
        if let path = Snapshot.outputPath {
            Snapshot.run(to: path)
        } else {
            UsageStore.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.menuBarMode) private var mode: MenuBarMode = .session

    var body: some View {
        let session = store.sessionLimit?.percent
        let weekly = store.weeklyLimit?.percent
        let text: String? = switch mode {
        case .icon: nil
        case .session: session.map { "\(Int($0))%" } ?? "–"
        case .both: "\(session.map { "\(Int($0))%" } ?? "–") · \(weekly.map { "\(Int($0))%" } ?? "–")"
        }
        let worst = max(session ?? 0, weekly ?? 0)
        Image(nsImage: StatusImage.render(
            outer: session.map { $0 / 100 },
            inner: mode == .both ? weekly.map { $0 / 100 } : nil,
            text: text,
            alert: worst >= 90
        ))
    }
}

/// Draws the menu bar item (ring gauge + percentage) as a single template image, so it
/// renders crisply and follows the menu bar's light/dark appearance.
enum StatusImage {
    static func render(outer: Double?, inner: Double?, text: String?, alert: Bool) -> NSImage {
        let color: NSColor = alert ? .systemRed : .black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let ring: CGFloat = 15, height: CGFloat = 18
        let gap: CGFloat = text == nil ? 0 : 4
        let size = NSSize(width: ring + gap + ceil(textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            let center = CGPoint(x: ring / 2, y: height / 2)

            func gauge(radius: CGFloat, width: CGFloat, fraction: Double?) {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = width
                color.withAlphaComponent(0.28).setStroke()
                track.stroke()

                guard let fraction, fraction > 0 else { return }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * min(fraction, 1), clockwise: true)
                arc.lineWidth = width
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }

            if inner != nil {
                gauge(radius: 6.3, width: 2, fraction: outer)
                gauge(radius: 2.9, width: 1.8, fraction: inner)
            } else {
                gauge(radius: 6, width: 2.4, fraction: outer)
            }
            if let text {
                (text as NSString).draw(
                    at: CGPoint(x: ring + gap, y: (height - textSize.height) / 2),
                    withAttributes: attributes
                )
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }
}
