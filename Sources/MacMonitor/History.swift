import Foundation

struct HistoryPoint: Codable { let t: Date; let pressure: Int; let swapIn: Double; let used: UInt64 }
struct HistoryEvent: Codable, Identifiable, Hashable {
    let t: Date; let text: String; let kind: String   // "lag", "ok", "jump", "action"
    var id: String { "\(t.timeIntervalSince1970)\(text)" }
}
struct Leak { let id: String; let name: String; let growth: UInt64; let hours: Double; let bundlePath: String? }

/// 24 h of memory readings, notable events, and per-app memory over time (for leak detection). Saved to disk.
final class History {
    private(set) var points: [HistoryPoint] = []
    private(set) var events: [HistoryEvent] = []
    private var appSeries: [String: [(Date, UInt64)]] = [:]
    private var appNames: [String: (String, String?)] = [:]
    private var lastMemory: [String: (Date, UInt64)] = [:]
    private var lastPoint = Date.distantPast, lastApps = Date.distantPast, lastSave = Date.distantPast
    private var wasLagging = false

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMemoryMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private struct Saved: Codable { var points: [HistoryPoint]; var events: [HistoryEvent] }

    init() {
        if Demo.on {   // a made-up day, for screenshots
            let now = Date()
            for i in stride(from: 1440, to: 0, by: -10) {
                let t = now.addingTimeInterval(-Double(i) * 60)
                let base = 45 + 20 * sin(Double(i) / 160) + (i % 470 < 40 ? 25 : 0)
                points.append(HistoryPoint(t: t, pressure: Int(min(95, base)), swapIn: i % 470 < 40 ? 40 * 1_048_576 : 0, used: 6 * 1_073_741_824))
            }
            events = [
                HistoryEvent(t: now.addingTimeInterval(-5 * 3600), text: "Lag started — reading 41 MB/s back from disk. Biggest: Google Chrome 2.9 GB, Claude 2.2 GB", kind: "lag"),
                HistoryEvent(t: now.addingTimeInterval(-5 * 3600 + 400), text: "Auto-paused Claude session “Refactor auth” (unused 22m)", kind: "action"),
                HistoryEvent(t: now.addingTimeInterval(-5 * 3600 + 700), text: "Back to normal", kind: "ok"),
                HistoryEvent(t: now.addingTimeInterval(-2 * 3600), text: "Google Chrome jumped by 900 MB to 2.1 GB", kind: "jump"),
                HistoryEvent(t: now.addingTimeInterval(-1800), text: "Quit Slack (560 MB)", kind: "action"),
            ]
            return
        }
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            let cutoff = Date().addingTimeInterval(-86_400)
            points = s.points.filter { $0.t > cutoff }
            events = s.events.filter { $0.t > cutoff }
        }
    }

    func record(_ m: MemorySnapshot, rows: [ProcGroup]) {
        let now = Date()
        if now.timeIntervalSince(lastPoint) >= 60 {
            lastPoint = now
            points.append(HistoryPoint(t: now, pressure: m.pressurePercent, swapIn: m.swapInRate, used: m.used))
            if points.count > 1440 { points.removeFirst(points.count - 1440) }
        }
        let lagging = m.health == .critical
        if lagging != wasLagging {
            let top = rows.filter { $0.kind != .system }.prefix(2).map { "\($0.name) \(fmtBytes($0.memory))" }.joined(separator: ", ")
            add(lagging ? "Lag started — reading \(fmtRate(m.swapInRate)) back from disk. Biggest: \(top)" : "Back to normal",
                kind: lagging ? "lag" : "ok")
            wasLagging = lagging
        }
        if now.timeIntervalSince(lastSave) > 600, !Demo.on { save() }
    }

    /// Called after every process scan.
    func recordApps(_ rows: [ProcGroup]) {
        let now = Date()
        for g in rows where g.kind != .system {
            if let (t, mem) = lastMemory[g.id], now.timeIntervalSince(t) < 300,
               g.memory > mem, Double(g.memory - mem) > Config.jumpEventSize {
                add("\(g.name) jumped by \(fmtBytes(g.memory - mem)) to \(fmtBytes(g.memory))", kind: "jump")
            }
            lastMemory[g.id] = (now, g.memory)
        }
        guard now.timeIntervalSince(lastApps) >= 300 else { return }
        lastApps = now
        for g in rows where g.kind == .app || g.kind == .claudeAll {
            appSeries[g.id, default: []].append((now, g.memory))
            if appSeries[g.id]!.count > 72 { appSeries[g.id]!.removeFirst() }
            appNames[g.id] = (g.name, g.bundlePath)
        }
    }

    func add(_ text: String, kind: String) {
        events.append(HistoryEvent(t: Date(), text: text, kind: kind))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    /// Apps whose memory climbed steadily: at least `leakGrowth` over 2+ hours, rising in most 5-minute steps.
    func leaks() -> [Leak] {
        appSeries.compactMap { id, s in
            guard s.count >= 24, let first = s.first, let last = s.last, last.1 > first.1,
                  Double(last.1 - first.1) >= Config.leakGrowth else { return nil }
            let ups = zip(s, s.dropFirst()).filter { $1.1 >= $0.1 }.count
            guard Double(ups) / Double(s.count - 1) >= 0.7 else { return nil }
            let n = appNames[id]
            return Leak(id: id, name: n?.0 ?? id, growth: last.1 - first.1,
                        hours: last.0.timeIntervalSince(first.0) / 3600, bundlePath: n?.1)
        }
        .sorted { $0.growth > $1.growth }
    }

    func save() {
        lastSave = Date()
        if let d = try? JSONEncoder().encode(Saved(points: points, events: events)) { try? d.write(to: file) }
    }
}
