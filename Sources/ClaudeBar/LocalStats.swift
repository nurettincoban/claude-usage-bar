import Foundation

struct DayBucket: Identifiable, Sendable {
    let date: Date
    let tokens: Int
    let cost: Double
    var id: Date { date }
}

struct NamedCount: Identifiable, Sendable {
    let name: String
    let value: Int
    var id: String { name }
}

/// One project's slice of the current session window.
struct WindowShare: Identifiable, Sendable {
    let name: String
    let tokens: Int
    let cost: Double
    /// Fraction of the window's usage, weighted by cost when every model is priced.
    let share: Double
    var id: String { name }
}

/// Claude Code usage since the current 5-hour session window opened.
struct SessionWindow: Sendable {
    let start: Date
    /// True when the window start is a guess (now − 5 h) because plan limits are unavailable.
    let isApproximate: Bool
    var tokens = 0
    var cost = 0.0
    var replies = 0
    var projects: [WindowShare] = []
}

/// Claude Code activity on this Mac, read from the session transcripts in ~/.claude/projects.
struct LocalSnapshot: Sendable {
    var todayTokens = 0
    var todayOutput = 0
    var todayMessages = 0
    var todaySessions = 0
    var todayCost = 0.0
    /// Some of today's usage came from models without a known price.
    var todayCostIsPartial = false
    var activeSessions = 0
    var daily: [DayBucket] = []
    var models: [NamedCount] = []
    var window: SessionWindow?
}

/// Incrementally tails transcript files: each scan only parses bytes appended since the last one.
actor TranscriptScanner {
    private struct Record {
        let date: Date
        let model: String
        let project: String
        let session: String
        let output: Int
        let total: Int
        let cost: Double?
    }

    static let horizonDays = 14

    private var offsets: [URL: UInt64] = [:]
    private var seen = Set<String>()
    private var records: [Record] = []
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()
    private let usageMarker = Data("\"usage\"".utf8)

    private let roots: [URL]

    init(roots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [".claude/projects", ".config/claude/projects"].map { home.appendingPathComponent($0) }
    }

    /// - Parameter windowStart: when the current session window opened, if known from the usage API.
    func scan(now: Date = Date(), windowStart: Date? = nil) -> LocalSnapshot {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(Self.horizonDays - 1), to: calendar.startOfDay(for: now))!
        let fm = FileManager.default

        for root in roots where fm.fileExists(atPath: root.path) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                ingest(url, size: UInt64(values.fileSize ?? 0), cutoff: cutoff)
            }
        }
        records.removeAll { $0.date < cutoff }
        return summarize(now: now, windowStart: windowStart)
    }

    private func ingest(_ url: URL, size: UInt64, cutoff: Date) {
        var offset = offsets[url] ?? 0
        if size < offset { offset = 0 } // file was rewritten
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A) else { return }

        let complete = data[data.startIndex...lastNewline] // leave a partially written line for next time
        offsets[url] = offset + UInt64(complete.count)
        let fallbackProject = Self.projectName(fromDirectory: url.deletingLastPathComponent().lastPathComponent)

        for line in complete.split(separator: 0x0A) where line.range(of: usageMarker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let stamp = obj["timestamp"] as? String,
                  let date = fractional.date(from: stamp) ?? plain.date(from: stamp),
                  date >= cutoff else { continue }

            // A response is logged once per content block, all with the same usage; count it once.
            let key = "\(message["id"] as? String ?? stamp)|\(obj["requestId"] as? String ?? "")"
            guard seen.insert(key).inserted else { continue }

            let tokens = Self.usage(from: usage)
            let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject
            records.append(Record(
                date: date,
                model: model,
                project: project,
                session: obj["sessionId"] as? String ?? url.lastPathComponent,
                output: tokens.output,
                total: tokens.total,
                cost: ModelCatalog.cost(model: model, usage: tokens)
            ))
        }
    }

    static func usage(from usage: [String: Any]) -> ModelCatalog.Usage {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let cacheWrite = int(usage["cache_creation_input_tokens"])
        // Claude Code splits cache writes by TTL; older transcripts don't, so treat those as 5-minute writes.
        let split = usage["cache_creation"] as? [String: Any]
        let write1h = min(int(split?["ephemeral_1h_input_tokens"]), cacheWrite)
        return ModelCatalog.Usage(
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]),
            cacheWrite5m: cacheWrite - write1h,
            cacheWrite1h: write1h,
            fast: usage["speed"] as? String == "fast"
        )
    }

    private func summarize(now: Date, windowStart: Date?) -> LocalSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let activeSince = now.addingTimeInterval(-10 * 60)
        var window = SessionWindow(start: windowStart ?? now.addingTimeInterval(-5 * 3600), isApproximate: windowStart == nil)

        var snapshot = LocalSnapshot()
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        var todaySessions = Set<String>(), active = Set<String>()
        var models: [String: Int] = [:]
        var windowProjects: [String: (tokens: Int, cost: Double)] = [:]
        var windowFullyPriced = true

        for r in records {
            let day = calendar.startOfDay(for: r.date)
            byDay[day, default: (0, 0)].tokens += r.total
            byDay[day, default: (0, 0)].cost += r.cost ?? 0
            if r.date >= activeSince { active.insert(r.session) }

            if r.date >= window.start {
                window.tokens += r.total
                window.cost += r.cost ?? 0
                window.replies += 1
                windowProjects[r.project, default: (0, 0)].tokens += r.total
                windowProjects[r.project, default: (0, 0)].cost += r.cost ?? 0
                if r.cost == nil { windowFullyPriced = false }
            }

            guard r.date >= today else { continue }
            snapshot.todayTokens += r.total
            snapshot.todayOutput += r.output
            snapshot.todayMessages += 1
            snapshot.todayCost += r.cost ?? 0
            if r.cost == nil { snapshot.todayCostIsPartial = true }
            todaySessions.insert(r.session)
            models[ModelCatalog.displayName(r.model), default: 0] += r.total
        }

        snapshot.todaySessions = todaySessions.count
        snapshot.activeSessions = active.count
        snapshot.daily = (0..<Self.horizonDays).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            return DayBucket(date: day, tokens: byDay[day]?.tokens ?? 0, cost: byDay[day]?.cost ?? 0)
        }
        snapshot.models = models.map { NamedCount(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }

        // Plan limits track compute rather than raw tokens (cache reads are cheap), so cost is the
        // better weight. Fall back to tokens if an unpriced model would distort the split.
        let byCost = windowFullyPriced && window.cost > 0
        let totalWeight = byCost ? window.cost : Double(max(window.tokens, 1))
        window.projects = windowProjects.map { name, usage in
            WindowShare(name: name, tokens: usage.tokens, cost: usage.cost,
                        share: (byCost ? usage.cost : Double(usage.tokens)) / totalWeight)
        }
        .sorted { $0.share > $1.share }
        snapshot.window = window
        return snapshot
    }

    /// "-Users-me-code-my-app" can't be split unambiguously; the last segment is a fair guess.
    private static func projectName(fromDirectory name: String) -> String {
        name.split(separator: "-").last.map(String.init) ?? name
    }
}
