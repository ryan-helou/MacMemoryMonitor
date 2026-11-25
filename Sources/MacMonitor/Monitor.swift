import AppKit
import Combine
import ServiceManagement
import UserNotifications

struct Tip: Identifiable {
    let id: String
    let icon: String
    let text: String
    var actionTitle: String? = nil
    var confirm = false
    var action: (() -> Void)? = nil
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var mem = MemorySnapshot()
    @Published private(set) var recent: [Double] = []
    @Published private(set) var rows: [ProcGroup] = []
    @Published private(set) var tips: [Tip] = []
    @Published private(set) var actionLog: [String] = []
    @Published private(set) var updateAvailable: (String, URL)?
    @Published var updateStatus: String?
    @Published var smartPause: Bool { didSet { UserDefaults.standard.set(smartPause, forKey: "smartPause") } }
    @Published var keepRecentSessions: Int { didSet { UserDefaults.standard.set(keepRecentSessions, forKey: "keepRecentSessions") } }
    @Published var nightlyClaudeRestart: Bool { didSet { UserDefaults.standard.set(nightlyClaudeRestart, forKey: "nightlyClaudeRestart") } }
    @Published var weeklyUpdateCheck: Bool { didSet { UserDefaults.standard.set(weeklyUpdateCheck, forKey: "weeklyUpdateCheck") } }
    @Published var menuBarStyle: String { didSet { UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle") } }
    @Published var onboarded: Bool { didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") } }
    let history = History()
    private var lastFront: [String: Date] = [:]
    private var lastNightlyRestart = Date.distantPast
    private lazy var mcpAudit = MCPAudit.read()

    @Published var guardEnabled: Bool { didSet { UserDefaults.standard.set(guardEnabled, forKey: "guardEnabled") } }
    @Published var expendable: Set<String> { didSet { UserDefaults.standard.set(Array(expendable), forKey: "expendable") } }
    @Published var alertsEnabled: Bool { didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var autoPauseEnabled: Bool { didSet { UserDefaults.standard.set(autoPauseEnabled, forKey: "autoPauseEnabled") } }
    @Published var autoPauseMinutes: Int { didSet { UserDefaults.standard.set(autoPauseMinutes, forKey: "autoPauseMinutes") } }

    var visible = false { didSet { if visible && !oldValue { scanNow() } } }

    private let sampler = SystemSampler()
    private let scanner = ProcessScanner()
    private let queue = DispatchQueue(label: "mac-monitor.scan", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var scanning = false
    private var lastScan = ScanResult()
    private var criticalSince: Date?
    private var lastGuardAction = Date.distantPast
    private var lastAlert = Date.distantPast
    private var sessionLastBusy: [pid_t: Date] = [:]
    private var pausing: Set<pid_t> = []
    private let launched = Date()

    init() {
        let d = UserDefaults.standard
        guardEnabled = d.bool(forKey: "guardEnabled")
        expendable = Set(d.stringArray(forKey: "expendable") ?? [])
        alertsEnabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
        autoPauseEnabled = d.object(forKey: "autoPauseEnabled") as? Bool ?? Config.autoPauseOnByDefault
        autoPauseMinutes = d.object(forKey: "autoPauseMinutes") as? Int ?? Config.autoPauseDefaultMinutes
        smartPause = d.bool(forKey: "smartPause")
        keepRecentSessions = d.object(forKey: "keepRecentSessions") as? Int ?? 1
        nightlyClaudeRestart = d.bool(forKey: "nightlyClaudeRestart")
        weeklyUpdateCheck = d.bool(forKey: "weeklyUpdateCheck")
        menuBarStyle = d.string(forKey: "menuBarStyle") ?? "percent"
        onboarded = d.bool(forKey: "onboarded")
    }

    func start() {
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        sampleMemory()
        scanNow()
        let ws = NSWorkspace.shared
        if let id = ws.frontmostApplication?.bundleIdentifier { lastFront[id] = Date() }
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in if let id { self?.lastFront[id] = Date() } }
        }
        if weeklyUpdateCheck, Date().timeIntervalSince(UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast) > 7 * 86_400 {
            checkForUpdates(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Config.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        sampleMemory()
        tick += 1
        // Scan processes often while you're looking, rarely while you're not — the monitor must stay cheap.
        let every = visible ? Config.scanEverySamplesVisible : (mem.health == .healthy ? Config.scanEverySamplesHealthy : Config.scanEverySamplesStrained)
        if tick % every == 0 { scanNow() }
        evaluate()
    }

    private func sampleMemory() {
        mem = Demo.on ? Demo.snapshot : sampler.sample()
        history.record(mem, rows: rows)
        recent.append(Double(mem.pressurePercent))
        if recent.count > Config.historyLength { recent.removeFirst(recent.count - Config.historyLength) }
    }

    func scanNow() {
        guard !scanning else { return }
        scanning = true
        let scanner = self.scanner
        queue.async {
            let r = scanner.scan()
            DispatchQueue.main.async { [weak self] in
                self?.scanning = false
                self?.apply(r)
            }
        }
    }

    // MARK: - Turning raw groups into rows + advice

    private func apply(_ raw: ScanResult) {
        let r = Demo.on ? Demo.scan() : raw
        lastScan = r
        let now = Date()
        var sessions: [ProcGroup] = []
        var others: [ProcGroup] = []
        var system: ProcGroup?

        for var g in r.groups {
            switch g.kind {
            case .claudeSession:
                if g.cpu > Config.sessionBusyCPU || g.runningTask != nil { sessionLastBusy[g.rootPid] = now }
                let idle = idleTime(g, now: now)
                let folder = g.name
                if let title = g.sessionTitle { g.name = title }
                var state: String
                if let task = g.runningTask { state = "running \(task)" }
                else if idle < 120 { state = "active now" }
                else { state = "last used \(fmtDuration(idle)) ago" }
                if pausing.contains(g.rootPid) { state = "pausing…" }
                g.detail = g.sessionTitle != nil ? "\(folder) · \(state)" : state
                sessions.append(g)
            case .system:
                g.detail = "Can't be quit — shown for context"
                system = g
            case .app:
                g.detail = "\(g.processCount) process\(g.processCount == 1 ? "" : "es")" + cpuText(g.cpu)
                if let id = g.bundleID, let seen = lastFront[id], now.timeIntervalSince(seen) > 3600 {
                    g.detail += " · unused \(fmtDuration(now.timeIntervalSince(seen)))"
                }
                others.append(g)
            case .script:
                var d = g.id.hasPrefix("vm") ? "virtual machine started by an app" : "background process"
                if g.processCount > 1 { d = "\(g.processCount) processes" }
                if let s = g.started { d += " · running \(fmtDuration(now.timeIntervalSince(s)))" }
                g.detail = d + cpuText(g.cpu)
                others.append(g)
            case .claudeAll: break
            }
        }
        let live = Set(sessions.map(\.rootPid))
        sessionLastBusy = sessionLastBusy.filter { live.contains($0.key) }
        pausing = pausing.intersection(live)
        autoPause(sessions, now: now)
        nightlyRestart(sessions, now: now)

        if !sessions.isEmpty {
            sessions.sort { $0.memory > $1.memory }
            var all = ProcGroup(id: "claude-all", kind: .claudeAll, name: "Claude Code")
            all.memory = sessions.reduce(0) { $0 + $1.memory }
            all.cpu = sessions.reduce(0) { $0 + $1.cpu }
            all.pids = sessions.flatMap(\.pids)
            all.children = sessions
            all.detail = "\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(roomText(sessions))"
            others.append(all)
        }
        others.sort { $0.memory > $1.memory }
        others = others.filter { Double($0.memory) >= Config.minRowMemory || $0.kind == .claudeAll }
        if let system { others.append(system) }
        rows = others
        history.recordApps(others)
        tips = buildTips(sessions: sessions)
    }

    private func cpuText(_ cpu: Double) -> String { cpu >= Config.showCPUAbove ? " · \(Int(cpu))% CPU" : "" }

    /// How many more sessions fit before the Mac starts swapping.
    func roomForSessions(_ sessions: [ProcGroup]) -> Int {
        let avg = sessions.isEmpty ? Config.typicalSessionCost : Double(sessions.reduce(0) { $0 + $1.memory }) / Double(sessions.count)
        let headroom = Double(mem.total) * 0.92 - Double(mem.used) - (mem.health == .healthy ? 0 : Double(mem.total))
        return max(0, Int(headroom / max(avg, 1)))
    }
    private func roomText(_ sessions: [ProcGroup]) -> String {
        let n = roomForSessions(sessions)
        return n == 0 ? "no room for more" : "room for ~\(n) more"
    }

    private func buildTips(sessions: [ProcGroup]) -> [Tip] {
        var t: [Tip] = []
        let apps = rows.filter { $0.kind == .app }
        let now = Date()

        if Double(mem.swapUsed) > Config.tipSwapUsed {
            let text = mem.health == .healthy
                ? "\(fmtBytes(mem.swapUsed)) is parked on disk (swap). Harmless while nothing reads it back, but your memory is full — the next app you open will lag."
                : "\(fmtBytes(mem.swapUsed)) has spilled to disk and macOS is reading it back — that's the lag. Close or pause the biggest items below."
            t.append(Tip(id: "swap", icon: "exclamationmark.triangle.fill", text: text))
        }
        if lastScan.claudeBinaries > 0 && sessions.isEmpty {
            t.append(Tip(id: "layout", icon: "questionmark.circle",
                         text: "Claude Code is running, but its sessions weren't recognised — a Claude update may have changed how they start. Please report it on GitHub.",
                         actionTitle: "Report", action: { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updates.repo)/issues")!) }))
        }
        for leak in history.leaks().prefix(2) {
            let g = rows.first { $0.id == leak.id }
            var tip = Tip(id: "leak\(leak.id)", icon: "chart.line.uptrend.xyaxis",
                          text: "\(leak.name) grew by \(fmtBytes(leak.growth)) over \(String(format: "%.0f", leak.hours)) hours and keeps climbing. Restarting it gives that back.")
            if let g, canQuit(g) {
                tip.actionTitle = "Restart"; tip.confirm = true
                tip.action = { [weak self] in self?.relaunch(g) }
            }
            t.append(tip)
        }
        if sessions.count >= Config.tipClaudeSessions {
            let total = sessions.reduce(0) { $0 + $1.memory }
            var tip = Tip(id: "claude", icon: "sparkles",
                          text: "\(sessions.count) Claude Code sessions are open (\(fmtBytes(total))), \(roomText(sessions)). Pausing one keeps its conversation — reopen it from the Claude sidebar.")
            let idle = idleSessions(olderThan: 3600)
            if !idle.isEmpty {
                tip.actionTitle = "Pause \(idle.count) unused 1h+"; tip.confirm = true
                tip.action = { [weak self] in idle.forEach { self?.endSession($0) } }
            }
            t.append(tip)
        }
        let byFolder = Dictionary(grouping: sessions.filter { $0.cwd != nil }, by: { $0.cwd! })
        if let dup = byFolder.first(where: { $0.value.count > 1 }) {
            t.append(Tip(id: "dup", icon: "square.on.square",
                         text: "\(dup.value.count) sessions are open in \((dup.key as NSString).lastPathComponent). Finish one and pause the others to save ~\(fmtBytes(dup.value.dropFirst().reduce(0) { $0 + $1.memory }))."))
        }
        if let huge = sessions.first(where: { Double($0.memory) > Config.hugeSessionMemory || $0.transcriptBytes > Config.hugeTranscript }) {
            t.append(Tip(id: "huge", icon: "text.alignleft",
                         text: "“\(huge.name)” has a very long conversation (\(fmtBytes(huge.memory)) in memory). Run /compact in it, or start a fresh session when that task is done."))
        }
        let audit = mcpAudit
        if !sessions.isEmpty, audit.globalLocalServers.count >= 3 {
            let cost = Double(audit.globalLocalServers.count * sessions.count) * Config.mcpServerCost
            t.append(Tip(id: "mcp", icon: "puzzlepiece.extension",
                         text: "\(audit.globalLocalServers.count) MCP servers (\(audit.globalLocalServers.prefix(4).joined(separator: ", "))…) start in every Claude session — about \(fmtBytes(UInt64(cost))) right now. Add the ones you rarely use to just the projects that need them (claude mcp add -s local)."))
        }
        if let chrome = apps.first(where: { $0.bundleID == "com.google.Chrome" }), Double(chrome.memory) > Config.tipChromeMemory {
            t.append(Tip(id: "chrome", icon: "globe",
                         text: "Chrome is using \(fmtBytes(chrome.memory)). Memory Saver unloads tabs you aren't looking at; Shift+Esc in Chrome shows which tab is heaviest.",
                         actionTitle: "Open setting", action: {
                             let p = Process()
                             p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                             p.arguments = ["-a", "Google Chrome", "chrome://settings/performance"]
                             try? p.run()
                         }))
        }
        let unused = apps.filter {
            guard let id = $0.bundleID, Double($0.memory) >= Config.unusedAppMinMemory, canQuit($0) else { return false }
            return now.timeIntervalSince(lastFront[id] ?? launched) >= Config.unusedAppHours * 3600
        }
        if !unused.isEmpty {
            t.append(Tip(id: "unused", icon: "moon.zzz",
                         text: "\(unused.map(\.name).joined(separator: ", ")) \(unused.count == 1 ? "hasn't" : "haven't") been used in \(Int(Config.unusedAppHours))+ hours (\(fmtBytes(unused.reduce(0) { $0 + $1.memory }))).",
                         actionTitle: "Quit \(unused.count == 1 ? "it" : "them")", confirm: true,
                         action: { [weak self] in unused.forEach { self?.quit($0) } }))
        } else {
            let webApps = apps.filter { Config.webAppBundleIDs.contains($0.bundleID ?? "") }
            if webApps.count >= 2 {
                t.append(Tip(id: "electron", icon: "square.stack.3d.up",
                             text: "\(webApps.map(\.name).joined(separator: ", ")) each run a full browser engine (\(fmtBytes(webApps.reduce(0) { $0 + $1.memory })) together). Quit the ones you aren't using."))
            }
        }
        for h in lastScan.hogs.prefix(2) {
            let pid = h.pid
            t.append(Tip(id: "hog\(pid)", icon: "flame.fill", text: "\(h.name) is using \(Int(h.cpu))% CPU.",
                         actionTitle: "Stop it", confirm: true,
                         action: { [weak self] in self?.terminate(pids: [pid], label: h.name) }))
        }
        if lastScan.spotlightCPU > Config.tipSpotlightCPU {
            t.append(Tip(id: "spotlight", icon: "magnifyingglass",
                         text: "Spotlight is indexing (\(Int(lastScan.spotlightCPU))% CPU). It settles on its own."))
        }
        let up = uptime()
        if up > Config.restartReminderDays * 86_400 && Double(mem.swapUsed) > Config.restartReminderSwap {
            t.append(Tip(id: "restart", icon: "arrow.clockwise",
                         text: "Your Mac has been on for \(Int(up / 86_400)) days with \(fmtBytes(mem.swapUsed)) in swap. A restart clears it all."))
        }
        if mem.diskFree > 0 && Double(mem.diskFree) < Config.tipLowDisk {
            t.append(Tip(id: "disk", icon: "internaldrive",
                         text: "Only \(fmtBytes(mem.diskFree)) of disk free. Swap lives on disk, so a full disk makes lag worse. The Disk screen shows what's big."))
        }
        if let u = updateAvailable {
            t.append(Tip(id: "update", icon: "arrow.down.circle", text: "Mac Memory Monitor \(u.0) is available.",
                         actionTitle: "Download", action: { NSWorkspace.shared.open(u.1) }))
        }
        return t
    }

    /// Real "last used": the newest of the conversation's last message, a running task, or CPU activity.
    private func idleTime(_ g: ProcGroup, now: Date) -> TimeInterval {
        let baseline = max(launched, g.started ?? launched)
        var last = sessionLastBusy[g.rootPid] ?? baseline
        if let a = g.lastActivity { last = max(last == baseline ? a : last, a) }
        return max(0, now.timeIntervalSince(last))
    }

    /// Timer mode: pause sessions unused for N minutes. Smart mode: only when memory is tight, oldest first.
    /// Both keep your most recently used sessions, never touch a session that is running something,
    /// and never touch terminal sessions (they can't be reopened from the sidebar).
    private func autoPause(_ sessions: [ProcGroup], now: Date) {
        // Hidden test hook: `--test-autopause=<seconds>:<cwd substring>` only ever acts on sessions whose folder matches.
        var limit = TimeInterval(autoPauseMinutes * 60)
        var candidates = sessions
        var keep = keepRecentSessions
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-autopause=") }) {
            let parts = arg.dropFirst("--test-autopause=".count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let secs = Double(parts[0]) else { return }
            limit = secs; keep = 0
            candidates = sessions.filter { ($0.cwd ?? "").contains(String(parts[1])) }
        } else {
            guard autoPauseEnabled, !Demo.on else { return }
            if smartPause {
                guard mem.health != .healthy else { return }
                limit = min(limit, 5 * 60)
            }
        }
        let recent = Set(candidates.sorted { idleTime($0, now: now) < idleTime($1, now: now) }.prefix(keep).map(\.rootPid))
        var idle = candidates.filter {
            $0.fromDesktop && $0.runningTask == nil && $0.cpu < Config.sessionBusyCPU && !pausing.contains($0.rootPid)
                && !recent.contains($0.rootPid) && idleTime($0, now: now) >= limit
        }
        .sorted { idleTime($0, now: now) > idleTime($1, now: now) }
        if smartPause && !CommandLine.arguments.contains(where: { $0.hasPrefix("--test-autopause=") }) { idle = Array(idle.prefix(1)) }
        guard !idle.isEmpty else { return }
        for g in idle {
            pausing.insert(g.rootPid)
            terminate(pids: g.pids, label: "Claude session “\(g.name)” (unused \(fmtDuration(idleTime(g, now: now))))",
                      rootFirst: g.rootPid, verb: "Auto-paused")
        }
        let freed = idle.reduce(0) { $0 + $1.memory }
        notify(title: "Paused \(idle.count) unused Claude session\(idle.count == 1 ? "" : "s") · freed \(fmtBytes(freed))",
               body: "\(idle.map(\.name).joined(separator: ", ")). Conversations are saved; reopen them from the Claude sidebar.")
    }

    private func idleSessions(olderThan secs: TimeInterval) -> [ProcGroup] {
        let now = Date()
        return (rows.first { $0.kind == .claudeAll }?.children ?? []).filter {
            $0.fromDesktop && $0.runningTask == nil && idleTime($0, now: now) >= secs
        }
    }

    /// Pause every desktop session unused for 10+ minutes (from the notification button), keeping your newest one.
    func pauseUnusedNow() {
        let now = Date()
        let sessions = rows.first { $0.kind == .claudeAll }?.children ?? []
        let newest = sessions.min { idleTime($0, now: now) < idleTime($1, now: now) }?.rootPid
        for g in idleSessions(olderThan: 600) where g.rootPid != newest { endSession(g) }
    }

    /// Restart the Claude app while you're away from the Mac, once it has grown big and no session is doing anything.
    /// Its window only shrinks on a restart; sessions are saved and reappear in the sidebar.
    private func nightlyRestart(_ sessions: [ProcGroup], now: Date) {
        guard nightlyClaudeRestart, !Demo.on,
              userIdleSeconds() >= Config.stepAwayMinutes * 60,
              now.timeIntervalSince(lastNightlyRestart) > Config.claudeRestartCooldown,
              let app = rows.first(where: { $0.bundleID == "com.anthropic.claudefordesktop" }),
              Double(app.memory) > Config.claudeRestartAbove,
              sessions.allSatisfy({ $0.runningTask == nil && $0.cpu < Config.sessionBusyCPU && idleTime($0, now: now) > 600 })
        else { return }
        lastNightlyRestart = now
        relaunch(app)
        let text = "Restarted Claude while you were away (it was using \(fmtBytes(app.memory))). Your sessions are saved in the sidebar."
        history.add(text, kind: "action")
        notify(title: "Freed memory while you were away", body: text)
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    private func userIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func uptime() -> TimeInterval {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - TimeInterval(tv.tv_sec)
    }

    func checkForUpdates(manual: Bool) {
        Updates.check { [weak self] latest, url in
            guard let self else { return }
            if let latest, let url, Updates.isNewer(latest, than: Updates.current) {
                self.updateAvailable = (latest, url)
                self.tips = self.buildTips(sessions: self.rows.first { $0.kind == .claudeAll }?.children ?? [])
            } else if manual {
                self.updateStatus = latest == nil ? "Couldn't reach GitHub." : "You're up to date (\(Updates.current))."
            }
            if manual, self.updateAvailable != nil { self.updateStatus = "Version \(self.updateAvailable!.0) is available — see the tip." }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        }
    }

    // MARK: - Alerts + automatic guard

    private func evaluate() {
        let critical = mem.health == .critical
        let now = Date()
        if critical {
            if criticalSince == nil { criticalSince = now; scanNow() }
        } else {
            criticalSince = nil
        }
        guard let since = criticalSince, now.timeIntervalSince(since) >= Config.criticalFor else { return }

        if guardEnabled, now.timeIntervalSince(lastGuardAction) > Config.autoFreeCooldown, autoFree() {
            lastGuardAction = now
            return
        }
        if alertsEnabled, now.timeIntervalSince(lastAlert) > Config.alertCooldown {
            lastAlert = now
            let top = rows.filter { $0.kind != .system }.prefix(2)
                .map { "\($0.name) (\(fmtBytes($0.memory)))" }.joined(separator: ", ")
            notify(title: "Your Mac is out of memory",
                   body: "This is what makes it lag. Biggest: \(top).", actions: true)
        }
    }

    /// Quits the biggest app you've marked as OK to auto-quit. Never touches anything unmarked.
    @discardableResult
    private func autoFree() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let victim = rows
            .filter({ $0.kind == .app && expendable.contains($0.bundleID ?? "-") && $0.bundleID != front })
            .max(by: { $0.memory < $1.memory }) else { return false }
        quit(victim)
        log("Auto-quit \(victim.name) to free \(fmtBytes(victim.memory))")
        notify(title: "Freed \(fmtBytes(victim.memory))", body: "Memory was critical, so Mac Monitor quit \(victim.name) (you marked it OK to auto-quit).")
        return true
    }

    /// Notifications only work from inside the .app bundle (a bare binary would crash).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func notify(title: String, body: String, actions: Bool = false) {
        guard canNotify, !Demo.on else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if actions { c.categoryIdentifier = "memory" }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Buttons shown on the "out of memory" notification.
    static func registerNotificationActions() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let pause = UNNotificationAction(identifier: "pause", title: "Pause unused Claude sessions")
        let quit = UNNotificationAction(identifier: "free", title: "Quit my ⚡ apps")
        let open = UNNotificationAction(identifier: "open", title: "Open monitor", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories(
            [UNNotificationCategory(identifier: "memory", actions: [pause, quit, open], intentIdentifiers: [])])
    }

    func handleNotificationAction(_ id: String) {
        switch id {
        case "pause": pauseUnusedNow()
        case "free":
            for g in rows where g.kind == .app && expendable.contains(g.bundleID ?? "-") { quit(g) }
        default: break
        }
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        actionLog.insert("\(f.string(from: Date()))  \(s)", at: 0)
        history.add(s, kind: "action")
        if actionLog.count > 5 { actionLog.removeLast() }
    }

    // MARK: - Actions

    private func runningApps(_ g: ProcGroup) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL?.path else { return false }
            return url == g.bundlePath || (g.bundleID != nil && $0.bundleIdentifier == g.bundleID)
        }
    }

    func canQuit(_ g: ProcGroup) -> Bool { g.kind == .app && !runningApps(g).isEmpty }

    func quit(_ g: ProcGroup) {
        runningApps(g).forEach { $0.terminate() }
        log("Quit \(g.name) (\(fmtBytes(g.memory)))")
        rescanSoon()
    }

    func forceQuit(_ g: ProcGroup) {
        runningApps(g).forEach { $0.forceTerminate() }
        log("Force-quit \(g.name)")
        rescanSoon()
    }

    /// Quit + reopen. Long-running Electron/Chrome apps leak; a fresh start often hands back hundreds of MB.
    func relaunch(_ g: ProcGroup) {
        guard let path = g.bundlePath else { return }
        let apps = runningApps(g)
        apps.forEach { $0.terminate() }
        log("Relaunching \(g.name) (was \(fmtBytes(g.memory)))")
        Task { @MainActor in
            for _ in 0..<40 where !apps.allSatisfy(\.isTerminated) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
            self.rescanSoon()
        }
    }

    func endSession(_ g: ProcGroup) {
        terminate(pids: g.pids, label: "Claude session “\(g.name)”", rootFirst: g.rootPid, verb: "Paused")
    }

    func killScript(_ g: ProcGroup) {
        terminate(pids: g.pids, label: g.name, rootFirst: g.rootPid)
    }

    /// SIGTERM (polite: lets the process save/clean up), then SIGKILL whatever ignored it.
    func terminate(pids: [pid_t], label: String, rootFirst: pid_t? = nil, verb: String = "Stopped") {
        let me = getpid()
        let targets = pids.filter { $0 > 1 && $0 != me }
        if let r = rootFirst, r > 1 { kill(r, SIGTERM) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            targets.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGTERM) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            targets.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
            self.rescanSoon()
        }
        log("\(verb) \(label)")
        rescanSoon()
    }

    func toggleExpendable(_ g: ProcGroup) {
        guard let id = g.bundleID else { return }
        if expendable.contains(id) { expendable.remove(id) } else { expendable.insert(id) }
    }

    private func rescanSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.scanNow()
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { log("Launch at login failed: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }
}
