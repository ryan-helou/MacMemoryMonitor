import AppKit
import SwiftUI

extension MemorySnapshot.Health {
    var color: Color {
        switch self { case .healthy: .green; case .strained: .orange; case .critical: .red }
    }
    var title: String {
        switch self { case .healthy: "Running smoothly"; case .strained: "Under strain"; case .critical: "Out of memory — lagging" }
    }
}

struct PopoverView: View {
    @EnvironmentObject var m: Monitor
    @State private var screen: Screen = {
        switch CommandLine.arguments.first(where: { $0.hasPrefix("--screen=") })?.dropFirst(9) {
        case "history": .history
        case "disk": .disk
        case "settings": .settings
        case "tips": .tips
        default: .main
        }
    }()
    @State private var showAll = false

    private let shortList = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !m.onboarded && !Demo.on && !CommandLine.arguments.contains(where: { $0.hasPrefix("--screen=") }) {
                OnboardingView()
            } else if screen == .settings {
                SettingsView(close: { screen = .main })
            } else if screen == .history {
                HistoryView(close: { screen = .main })
            } else if screen == .tips {
                VStack(alignment: .leading, spacing: 10) {
                    ScreenHeader(title: "Tips", close: { screen = .main })
                    ScrollView {
                        VStack(spacing: 8) { ForEach(m.tips) { TipCard(tip: $0) } }
                    }
                    .frame(maxHeight: 430)
                }
            } else if screen == .disk {
                DiskView(close: { screen = .main })
            } else {
                HeaderView(go: { screen = $0 })
                if let first = m.tips.first {
                    TipCard(tip: first)
                    if m.tips.count > 1 {
                        Button { screen = .tips } label: {
                            Label("\(m.tips.count - 1) more tip\(m.tips.count == 2 ? "" : "s")", systemImage: "chevron.right")
                                .labelStyle(TrailingIcon())
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                list
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Demo.on ? Color(nsColor: .windowBackgroundColor) : .clear)
    }

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Using the most memory").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            let rows = showAll ? m.rows : Array(m.rows.filter { $0.kind != .system }.prefix(shortList))
            if showAll {
                ScrollView { LazyVStack(spacing: 1) { ForEach(rows) { GroupRow(group: $0) } } }.frame(height: 300)
            } else {
                VStack(spacing: 1) { ForEach(rows) { GroupRow(group: $0) } }
            }
            if m.rows.count > shortList {
                Button(showAll ? "Show less" : "Show all \(m.rows.count)") {
                    withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                }
                .buttonStyle(.link).font(.caption)
            }
            Text("Hover a row to quit, restart or pause it.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var m: Monitor
    let go: (Screen) -> Void

    var body: some View {
        let s = m.mem
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(s.pressurePercent)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(s.health.color)
                    .help("Memory pressure: how hard macOS is working to find free memory")
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.health.title).font(.headline)
                    Text(subtitle(s)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    IconButton(icon: "clock.arrow.circlepath", label: "History") { go(.history) }
                    IconButton(icon: "internaldrive", label: "Disk") { go(.disk) }
                    IconButton(icon: "gearshape", label: "Settings") { go(.settings) }
                }
                .font(.title3)
            }
            MemoryBar(s: s).frame(height: 8)
                .help("Apps \(fmtBytes(s.app)) · System \(fmtBytes(s.wired)) · Compressed \(fmtBytes(s.compressed)) of \(fmtBytes(s.total))")
        }
    }

    private func subtitle(_ s: MemorySnapshot) -> String {
        var parts = ["\(fmtBytes(s.used)) of \(fmtBytes(s.total)) used"]
        if Double(s.swapUsed) > Config.tipSwapUsed { parts.append("\(fmtBytes(s.swapUsed)) on disk") }
        if s.cpuUsage > 70 { parts.append("CPU \(Int(s.cpuUsage))%") }
        return parts.joined(separator: " · ")
    }
}

struct MemoryBar: View {
    let s: MemorySnapshot
    var body: some View {
        GeometryReader { geo in
            let total = max(Double(s.total), 1)
            let used = min(1, Double(s.used) / total)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(s.health.color.gradient).frame(width: geo.size.width * used)
            }
        }
    }
}

// MARK: - Tips

struct TipCard: View {
    let tip: Tip
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tip.icon).foregroundStyle(.orange).frame(width: 16).padding(.top, 1)
            Text(tip.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = tip.actionTitle, let action = tip.action {
                if tip.confirm { ConfirmButton(title: title, action: action) }
                else { Button(title, action: action).controlSize(.small) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }
}

// MARK: - Rows

struct GroupRow: View {
    @EnvironmentObject var m: Monitor
    let group: ProcGroup
    var indent = false
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                GroupIcon(group: group).frame(width: 22, height: 22).help(helpText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(group.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if group.kind == .claudeAll {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                // On hover the buttons take the memory number's place, so the name never gets squeezed.
                ZStack(alignment: .trailing) {
                    Text(fmtBytes(group.memory))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(memColor)
                        .opacity(hovering && hasActions ? 0 : 1)
                    if hovering { actions }
                }
                .frame(minWidth: 92, alignment: .trailing)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .padding(.leading, indent ? 22 : 0)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if group.kind == .claudeAll { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }

            if group.kind == .claudeAll && expanded {
                ForEach(group.children) { GroupRow(group: $0, indent: true) }
            }
        }
    }

    private var memColor: Color {
        let m = Double(group.memory)
        return m >= Config.rowAlarmMemory ? .red : m >= Config.rowWarnMemory ? .orange : .primary
    }

    private var helpText: String {
        switch group.kind {
        case .claudeSession: return group.cwd ?? group.name
        case .script: return "PID \(group.rootPid)"
        case .app: return Config.explanations[group.bundleID ?? ""] ?? group.bundlePath ?? group.name
        default: return ""
        }
    }

    private var hasActions: Bool {
        switch group.kind {
        case .app: return m.canQuit(group)
        case .claudeSession, .script: return true
        default: return false
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch group.kind {
            case .app where m.canQuit(group):
                let marked = m.expendable.contains(group.bundleID ?? "-")
                IconButton(icon: marked ? "bolt.fill" : "bolt", label: marked ? "Auto-quit on" : "Auto-quit",
                           tint: marked ? .yellow : .secondary) { m.toggleExpendable(group) }
                IconButton(icon: "arrow.clockwise", label: "Relaunch") { m.relaunch(group) }
                IconButton(icon: "xmark.circle.fill", label: "Quit") { m.quit(group) }
                    .contextMenu { Button("Force Quit") { m.forceQuit(group) } }
            case .claudeSession:
                ConfirmButton(title: "Pause") { m.endSession(group) }
                    .help("Stops this session to free its memory. The conversation stays saved — reopen it from the Claude sidebar to pick up where you left off. Don't pause a session that's mid-task.")
            case .script where group.id.hasPrefix("vm"):
                IconButton(icon: "info.circle", label: "Can't stop") {}
                    .help("A virtual machine started by an app. Quit or idle that app's feature to free it — stopping it directly can break the app.")
            case .script:
                ConfirmButton(title: "Stop") { m.killScript(group) }
            default:
                EmptyView()
            }
        }
    }
}

struct GroupIcon: View {
    let group: ProcGroup
    var body: some View {
        switch group.kind {
        case .app:
            if let p = group.bundlePath { Image(nsImage: IconCache.icon(p)).resizable() }
        case .claudeAll:
            Image(systemName: "sparkles").foregroundStyle(.orange).font(.title3)
        case .claudeSession:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        case .script:
            Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .system:
            Image(systemName: "apple.logo").foregroundStyle(.secondary).font(.title3)
        }
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 44, height: 44)
        cache[path] = i
        return i
    }
}

/// Destructive actions need a second click within 3 seconds — no modal dialogs stealing focus.
struct ConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button(armed ? "Sure?" : title) {
            if armed { armed = false; action() } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        }
        .controlSize(.small)
        .tint(armed ? .red : nil)
        .buttonStyle(.bordered)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            setting("Pause unused Claude sessions",
                    "Conversations stay saved. Sessions running something are never paused.",
                    isOn: $m.autoPauseEnabled) {
                HStack(spacing: 6) {
                    Picker("", selection: $m.smartPause) {
                        Text("after").tag(false)
                        Text("only when memory is tight").tag(true)
                    }
                    .labelsHidden().frame(width: m.smartPause ? 190 : 70)
                    if !m.smartPause {
                        Picker("", selection: $m.autoPauseMinutes) {
                            ForEach(Config.autoPauseChoices, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden().frame(width: 80)
                    }
                }
                .controlSize(.small).disabled(!m.autoPauseEnabled)
                Stepper("Always keep my \(m.keepRecentSessions) newest", value: $m.keepRecentSessions, in: 0...5)
                    .font(.caption).controlSize(.small).disabled(!m.autoPauseEnabled)
            }
            setting("Restart Claude when I step away",
                    "After 15 min without keyboard or mouse, if Claude has grown past 1.5 GB and no session is busy. Sessions stay in the sidebar.",
                    isOn: $m.nightlyClaudeRestart) { EmptyView() }
            setting("Free memory automatically",
                    m.expendable.isEmpty ? "When memory is critical, quits apps you mark with ⚡ (hover an app row)."
                                         : "When memory is critical, quits your ⚡ apps, biggest first.",
                    isOn: $m.guardEnabled) { EmptyView() }
            setting("Warn me when memory runs out", nil, isOn: $m.alertsEnabled) { EmptyView() }
            setting("Open at login", nil, isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 })) { EmptyView() }
            HStack {
                Text("Menu bar shows").font(.callout)
                Spacer()
                Picker("", selection: $m.menuBarStyle) {
                    Text("Pressure %").tag("percent")
                    Text("Memory free").tag("free")
                    Text("Lag (disk reads)").tag("lag")
                    Text("Dot only").tag("dot")
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            setting("Check for updates weekly", m.updateStatus ?? "Asks GitHub once a week. Off = the app never goes online.",
                    isOn: $m.weeklyUpdateCheck) {
                Button("Check now") { m.checkForUpdates(manual: true) }.controlSize(.small)
            }
            Text("Tip: press ⌥⌘M anywhere to open this panel.").font(.caption).foregroundStyle(.secondary)

            if !m.actionLog.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(m.actionLog, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            Divider()
            HStack {
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit Mac Memory Monitor") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private func setting<Extra: View>(_ title: String, _ detail: String?, isOn: Binding<Bool>,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

enum Screen { case main, history, disk, settings, tips }

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

struct ScreenHeader: View {
    let title: String; let close: () -> Void
    var body: some View {
        HStack {
            Button(action: close) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Spacer(); Text(title).font(.headline); Spacer()
            Color.clear.frame(width: 50, height: 1)
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var m: Monitor
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Last 24 hours", close: close)
            let pts = m.history.points
            if pts.count < 2 {
                Text("Collecting — the graph fills in over the next hour.").font(.callout).foregroundStyle(.secondary)
            } else {
                HistoryChart(points: pts).frame(height: 110)
                HStack {
                    Text(pts.first!.t, style: .time); Spacer(); Text("now")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Text("What happened").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            let events = m.history.events.reversed().prefix(40)
            if events.isEmpty {
                Text("Nothing notable yet. Lag, big jumps and actions show up here.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events)) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(e.kind)).foregroundStyle(color(e.kind)).frame(width: 14)
                                Text(e.t, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                                Text(e.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }
    private func icon(_ k: String) -> String { ["lag": "tortoise.fill", "ok": "checkmark.circle", "jump": "arrow.up.right", "action": "hand.tap"][k] ?? "circle" }
    private func color(_ k: String) -> Color { ["lag": .red, "ok": .green, "jump": .orange][k] ?? .secondary }
}

struct HistoryChart: View {
    let points: [HistoryPoint]
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let t0 = points.first!.t.timeIntervalSince1970, span = max(points.last!.t.timeIntervalSince1970 - t0, 1)
            let xy = points.map { CGPoint(x: w * CGFloat(($0.t.timeIntervalSince1970 - t0) / span), y: h * (1 - CGFloat($0.pressure) / 100)) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    if p.swapIn > Config.thrashingSwapReadRate {
                        Rectangle().fill(Color.red.opacity(0.18)).frame(width: max(2, w / CGFloat(points.count)), height: h).offset(x: xy[i].x)
                    }
                }
                Path { path in path.move(to: CGPoint(x: 0, y: h)); xy.forEach { path.addLine(to: $0) }; path.addLine(to: CGPoint(x: w, y: h)) }
                    .fill(Color.accentColor.opacity(0.15))
                Path { path in path.move(to: xy[0]); xy.dropFirst().forEach { path.addLine(to: $0) } }
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .help("Memory pressure. Red bands = lag (reading lots back from disk).")
    }
}

// MARK: - Disk

struct DiskView: View {
    let close: () -> Void
    @State private var items: [DiskItem]?
    @State private var trashed: Set<String> = []
    @State private var freed: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Free up disk space", close: close)
            Text("Swap lives on disk, so a nearly full disk makes lag worse. These are the biggest items in Downloads, Movies, Desktop and developer caches. Removing moves them to the Trash.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let items {
                if items.isEmpty { Text("Nothing big found. 👍").font(.callout) }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items.filter { !trashed.contains($0.id) }) { item in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(fmtBytes(item.size)).font(.callout.monospacedDigit())
                                IconButton(icon: "magnifyingglass", label: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                ConfirmButton(title: "Trash") {
                                    DiskScanner.trash(item) { ok in if ok { trashed.insert(item.id); freed += item.size } }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 320)
                if freed > 0 { Text("\(fmtBytes(freed)) moved to the Trash — empty it to get the space back.").font(.caption).foregroundStyle(.green) }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Looking for big files…").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task {
            guard items == nil else { return }
            items = Demo.on ? Demo.diskItems : await Task.detached(priority: .utility) { DiskScanner.scan() }.value
        }
    }
}

// MARK: - First run

struct OnboardingView: View {
    @EnvironmentObject var m: Monitor
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0:
                Text("Welcome to Mac Memory Monitor").font(.title3.weight(.semibold))
                Text("It shows how close your Mac is to running out of memory, which is what makes it lag, and helps you fix it.").font(.callout)
                legend(.green, "Plenty of memory")
                legend(.orange, "Under strain — closing something will help")
                legend(.red, "Out of memory — this is the lag you feel")
            case 1:
                Text("Let it help automatically?").font(.title3.weight(.semibold))
                Toggle("Pause Claude Code sessions I haven't used in 15 min (conversations stay saved)", isOn: $m.autoPauseEnabled)
                Toggle("Warn me when memory runs out", isOn: $m.alertsEnabled)
                Text("You can mark apps that are OK to quit automatically later by hovering them and clicking ⚡.").font(.caption).foregroundStyle(.secondary)
            default:
                Text("Start it automatically?").font(.title3.weight(.semibold))
                Toggle("Open at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                Text("Press ⌥⌘M anywhere to open this panel. Everything stays on your Mac; the app never goes online unless you turn on update checks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step < 2 ? "Next" : "Done") { if step < 2 { step += 1 } else { m.onboarded = true } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 8) { Circle().fill(c).frame(width: 10, height: 10); Text(t).font(.callout) }
    }
}

/// A symbol that shows its name in a floating pill while you point at it. The pill floats over the content,
/// so nothing moves and the panel never changes size.
struct IconButton: View {
    let icon: String; let label: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).padding(2).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hover ? Color.primary : tint)
        .overlay(alignment: .trailing) {
            if hover {
                Text(label)
                    .font(.caption.weight(.medium)).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .alignmentGuide(.trailing) { d in d[.leading] - 4 }   // sits just left of the symbol
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(hover ? 1 : 0)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}
