import Foundation

struct DayBucket: Identifiable, Sendable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

struct NamedCount: Identifiable, Sendable {
    let name: String
    let value: Int
    var id: String { name }
}

/// Claude Code activity on this Mac, read from the session transcripts in ~/.claude/projects.
struct LocalSnapshot: Sendable {
    var todayTokens = 0
    var todayOutput = 0
    var todayMessages = 0
    var todaySessions = 0
    var activeSessions = 0
    var daily: [DayBucket] = []
    var topProjects: [NamedCount] = []
    var models: [NamedCount] = []
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

    func scan(now: Date = Date()) -> LocalSnapshot {
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
        return summarize(now: now, cutoff: cutoff)
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

            func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let output = int("output_tokens")
            let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackProject
            records.append(Record(
                date: date,
                model: model,
                project: project,
                session: obj["sessionId"] as? String ?? url.lastPathComponent,
                output: output,
                total: int("input_tokens") + output + int("cache_read_input_tokens") + int("cache_creation_input_tokens")
            ))
        }
    }

    private func summarize(now: Date, cutoff: Date) -> LocalSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let activeSince = now.addingTimeInterval(-10 * 60)

        var snapshot = LocalSnapshot()
        var byDay: [Date: Int] = [:]
        var todaySessions = Set<String>(), active = Set<String>()
        var projects: [String: Int] = [:], models: [String: Int] = [:]

        for r in records {
            byDay[calendar.startOfDay(for: r.date), default: 0] += r.total
            if r.date >= activeSince { active.insert(r.session) }
            guard r.date >= today else { continue }
            snapshot.todayTokens += r.total
            snapshot.todayOutput += r.output
            snapshot.todayMessages += 1
            todaySessions.insert(r.session)
            projects[r.project, default: 0] += r.total
            models[Self.modelName(r.model), default: 0] += r.total
        }

        snapshot.todaySessions = todaySessions.count
        snapshot.activeSessions = active.count
        snapshot.daily = (0..<Self.horizonDays).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            return DayBucket(date: day, tokens: byDay[day] ?? 0)
        }
        snapshot.topProjects = projects.map { NamedCount(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
        snapshot.models = models.map { NamedCount(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
        return snapshot
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-haiku-20241022" → "Haiku 3.5".
    static func modelName(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        let family = parts.first { $0.contains(where: \.isLetter) }.map { $0.capitalized } ?? id
        let version = parts.filter { $0.allSatisfy(\.isNumber) && $0.count < 4 }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// "-Users-me-code-my-app" can't be split unambiguously; the last segment is a fair guess.
    private static func projectName(fromDirectory name: String) -> String {
        name.split(separator: "-").last.map(String.init) ?? name
    }
}
