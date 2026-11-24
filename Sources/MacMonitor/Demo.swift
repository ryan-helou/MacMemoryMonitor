import Foundation

/// `--demo` shows made-up data, for screenshots and trying the app without touching anything real.
enum Demo {
    static let on = CommandLine.arguments.contains("--demo")

    static var snapshot: MemorySnapshot {
        var s = MemorySnapshot()
        let gb: UInt64 = 1_073_741_824
        s.total = 8 * gb; s.app = 3 * gb; s.wired = 2 * gb; s.compressed = 2 * gb
        s.swapUsed = 3 * gb + gb / 2; s.swapTotal = 4 * gb; s.pressureLevel = 2; s.freePercent = 28
        s.swapInRate = 9 * 1_048_576; s.cpuUsage = 34; s.diskFree = 60 * gb
        return s
    }

    static func scan() -> ScanResult {
        let mb: UInt64 = 1_048_576
        func app(_ name: String, _ path: String, _ id: String, _ m: UInt64, _ n: Int) -> ProcGroup {
            ProcGroup(id: path, kind: .app, name: name, memory: m * mb, pids: Array(repeating: 1, count: n), bundlePath: path, bundleID: id)
        }
        func session(_ pid: pid_t, _ title: String, _ folder: String, _ m: UInt64, _ minsAgo: Double) -> ProcGroup {
            var g = ProcGroup(id: "s\(pid)", kind: .claudeSession, name: folder, memory: m * mb, pids: [pid, pid + 1], rootPid: pid,
                              started: Date().addingTimeInterval(-7200), cwd: "/Users/demo/\(folder)")
            g.fromDesktop = true; g.sessionTitle = title; g.lastActivity = Date().addingTimeInterval(-minsAgo * 60)
            return g
        }
        var r = ScanResult()
        r.groups = [
            app("Google Chrome", "/Applications/Google Chrome.app", "com.google.Chrome", 2150, 19),
            app("Claude", "/Applications/Claude.app", "com.anthropic.claudefordesktop", 1700, 16),
            app("Spotify", "/Applications/Spotify.app", "com.spotify.client", 820, 7),
            app("Slack", "/Applications/Slack.app", "com.tinyspeck.slackmacgap", 560, 6),
            app("Messages", "/System/Applications/Messages.app", "com.apple.MobileSMS", 180, 2),
            session(90001, "Fix checkout flow", "shop-app", 420, 1),
            session(90011, "Write launch blog post", "website", 310, 48),
            session(90021, "Refactor auth", "api", 290, 160),
            ProcGroup(id: "system", kind: .system, name: "macOS & system services", memory: 2300 * mb),
        ]
        return r
    }

    static var diskItems: [DiskItem] {
        let gb: UInt64 = 1_073_741_824
        return [("~/Downloads/Vacation footage", 18 * gb), ("~/Movies/Old project exports", 9 * gb),
                ("~/Library/Developer/Xcode/DerivedData/MyApp", 4 * gb), ("~/Downloads/installer.dmg", gb)]
            .map { DiskItem(url: URL(fileURLWithPath: NSString(string: $0.0).expandingTildeInPath), size: $0.1) }
    }
}
