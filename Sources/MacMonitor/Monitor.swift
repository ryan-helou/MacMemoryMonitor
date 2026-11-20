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
    @Published private(set) var history: [Double] = []
    @Published private(set) var rows: [ProcGroup] = []
    @Published private(set) var tips: [Tip] = []
    @Published private(set) var actionLog: [String] = []

    @Published var guardEnabled: Bool { didSet { UserDefaults.standard.set(guardEnabled, forKey: "guardEnabled") } }
    @Published var expendable: Set<String> { didSet { UserDefaults.standard.set(Array(expendable), forKey: "expendable") } }
    @Published var alertsEnabled: Bool { didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") } }

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
    private let launched = Date()

    init() {
        let d = UserDefaults.standard
        guardEnabled = d.bool(forKey: "guardEnabled")
        expendable = Set(d.stringArray(forKey: "expendable") ?? [])
        alertsEnabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        sampleMemory()
        scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        sampleMemory()
        tick += 1
        // Scan processes often while you're looking, rarely while you're not — the monitor must stay cheap.
        let every = visible ? 1 : (mem.health == .healthy ? 8 : 3)
        if tick % every == 0 { scanNow() }
        evaluate()
    }

    private func sampleMemory() {
        mem = sampler.sample()
        history.append(Double(mem.pressurePercent))
        if history.count > 90 { history.removeFirst(history.count - 90) }
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

    private func apply(_ r: ScanResult) {
        lastScan = r
        let now = Date()
        var sessions: [ProcGroup] = []
        var others: [ProcGroup] = []
        var system: ProcGroup?

        for var g in r.groups {
            switch g.kind {
            case .claudeSession:
                if g.cpu > 3 { sessionLastBusy[g.rootPid] = now }
                let idle = now.timeIntervalSince(sessionLastBusy[g.rootPid] ?? launched)
                let state = idle < 120 ? "working" : "idle \(idle >= now.timeIntervalSince(launched) - 5 ? "≥ " : "")\(fmtDuration(idle))"
                let helpers = g.processCount - 1
                g.detail = "\(state) · \(helpers) helper\(helpers == 1 ? "" : "s")"
                if let s = g.started { g.detail += " · open \(fmtDuration(now.timeIntervalSince(s)))" }
                sessions.append(g)
            case .system:
                g.detail = "Can't be quit — shown for context"
                system = g
            case .app:
                g.detail = "\(g.processCount) process\(g.processCount == 1 ? "" : "es")" + cpuText(g.cpu)
                others.append(g)
            case .script:
                var d = "background process"
                if g.processCount > 1 { d = "\(g.processCount) processes" }
                if let s = g.started { d += " · running \(fmtDuration(now.timeIntervalSince(s)))" }
                g.detail = d + cpuText(g.cpu)
                others.append(g)
            case .claudeAll: break
            }
        }
        let live = Set(sessions.map(\.rootPid))
        sessionLastBusy = sessionLastBusy.filter { live.contains($0.key) }

        if !sessions.isEmpty {
            sessions.sort { $0.memory > $1.memory }
            var all = ProcGroup(id: "claude-all", kind: .claudeAll, name: "Claude Code")
            all.memory = sessions.reduce(0) { $0 + $1.memory }
            all.cpu = sessions.reduce(0) { $0 + $1.cpu }
            all.pids = sessions.flatMap(\.pids)
            all.children = sessions
            all.detail = "\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(all.processCount) processes" + cpuText(all.cpu)
            others.append(all)
        }
        others.sort { $0.memory > $1.memory }
        others = others.filter { $0.memory >= 15 * 1_048_576 || $0.kind == .claudeAll }
        if let system { others.append(system) }
        rows = others
        tips = buildTips(sessions: sessions)
    }

    private func cpuText(_ cpu: Double) -> String { cpu >= 5 ? " · \(Int(cpu))% CPU" : "" }

    private func buildTips(sessions: [ProcGroup]) -> [Tip] {
        var t: [Tip] = []
        let gb = 1_073_741_824.0
        let apps = rows.filter { $0.kind == .app }

        if Double(mem.swapUsed) > 2 * gb {
            let text = mem.health == .healthy
                ? "\(fmtBytes(mem.swapUsed)) is parked in swap on disk. It's harmless while nothing reads it back, but it means RAM is full — the next app you open will cause lag."
                : "\(fmtBytes(mem.swapUsed)) has spilled to disk (swap) and macOS is reading it back — that's the lag. Close or pause the biggest items below."
            t.append(Tip(id: "swap", icon: "exclamationmark.triangle.fill", text: text))
        }
        if sessions.count >= 3 {
            let total = sessions.reduce(0) { $0 + $1.memory }
            let helpers = sessions.reduce(0) { $0 + $1.processCount - 1 }
            var tip = Tip(id: "claude", icon: "sparkles",
                          text: "\(sessions.count) Claude Code sessions are open, using \(fmtBytes(total)) with \(helpers) helper processes. Idle sessions still hold all of it — pause them; the conversation stays saved and reopens from the Claude sidebar.")
            let idle = idleSessions(olderThan: 3600)
            if !idle.isEmpty {
                tip = Tip(id: "claude", icon: "sparkles", text: tip.text,
                          actionTitle: "Pause \(idle.count) idle 1h+", confirm: true,
                          action: { [weak self] in idle.forEach { self?.endSession($0) } })
            }
            t.append(tip)
        }
        if let chrome = apps.first(where: { $0.bundleID == "com.google.Chrome" }), Double(chrome.memory) > 1.2 * gb {
            t.append(Tip(id: "chrome", icon: "globe",
                         text: "Chrome is using \(fmtBytes(chrome.memory)) across \(chrome.processCount) processes. Memory Saver unloads tabs you aren't looking at.",
                         actionTitle: "Open setting", action: {
                             let p = Process()
                             p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                             p.arguments = ["-a", "Google Chrome", "chrome://settings/performance"]
                             try? p.run()
                         }))
        }
        let webAppIDs: Set<String> = ["com.spotify.client", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
                                       "com.tinyspeck.slackmacgap", "notion.id", "com.figma.Desktop", "com.microsoft.VSCode"]
        let webApps = apps.filter { webAppIDs.contains($0.bundleID ?? "") }
        if webApps.count >= 2 {
            let total = webApps.reduce(0) { $0 + $1.memory }
            t.append(Tip(id: "electron", icon: "square.stack.3d.up",
                         text: "\(webApps.map(\.name).joined(separator: ", ")) each run a full browser engine (\(fmtBytes(total)) together). Quit the ones you aren't actively using — or use their web versions in a Chrome tab."))
        }
        for h in lastScan.hogs.prefix(2) {
            let pid = h.pid
            t.append(Tip(id: "hog\(pid)", icon: "flame.fill",
                         text: "\(h.name) is using \(Int(h.cpu))% CPU.",
                         actionTitle: "Stop it", confirm: true,
                         action: { [weak self] in self?.terminate(pids: [pid], label: h.name) }))
        }
        if lastScan.spotlightCPU > 40 {
            t.append(Tip(id: "spotlight", icon: "magnifyingglass",
                         text: "Spotlight is indexing (\(Int(lastScan.spotlightCPU))% CPU). It settles on its own — exclude big code/video folders in System Settings › Spotlight to stop it coming back."))
        }
        if mem.diskFree > 0 && Double(mem.diskFree) < 15 * gb {
            t.append(Tip(id: "disk", icon: "internaldrive",
                         text: "Only \(fmtBytes(mem.diskFree)) of disk free. Swap lives on disk, so a full disk makes memory pressure much worse."))
        }
        return t
    }

    private func idleSessions(olderThan secs: TimeInterval) -> [ProcGroup] {
        guard Date().timeIntervalSince(launched) >= secs else { return [] }
        let now = Date()
        return (rows.first { $0.kind == .claudeAll }?.children ?? []).filter {
            now.timeIntervalSince(sessionLastBusy[$0.rootPid] ?? launched) >= secs
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
        guard let since = criticalSince, now.timeIntervalSince(since) >= 15 else { return }

        if guardEnabled, now.timeIntervalSince(lastGuardAction) > 30, autoFree() {
            lastGuardAction = now
            return
        }
        if alertsEnabled, now.timeIntervalSince(lastAlert) > 15 * 60 {
            lastAlert = now
            let top = rows.filter { $0.kind != .system }.prefix(2)
                .map { "\($0.name) (\(fmtBytes($0.memory)))" }.joined(separator: ", ")
            notify(title: "Your Mac is out of memory",
                   body: "This is what makes it lag. Biggest: \(top). Click the menu bar monitor to free some.")
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

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        actionLog.insert("\(f.string(from: Date()))  \(s)", at: 0)
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
