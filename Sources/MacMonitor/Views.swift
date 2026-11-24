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
    @State private var showSettings = false
    @State private var showAll = false
    @State private var showAllTips = false

    private let shortList = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showSettings {
                SettingsView(close: { showSettings = false })
            } else {
                HeaderView(openSettings: { showSettings = true })
                if let first = m.tips.first {
                    TipCard(tip: first)
                    if m.tips.count > 1 {
                        if showAllTips { ForEach(m.tips.dropFirst()) { TipCard(tip: $0) } }
                        Button(showAllTips ? "Fewer tips" : "\(m.tips.count - 1) more tip\(m.tips.count == 2 ? "" : "s")") {
                            withAnimation(.easeOut(duration: 0.15)) { showAllTips.toggle() }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                list
            }
        }
        .padding(16)
        .frame(width: 380)
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
    let openSettings: () -> Void

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
                Button(action: openSettings) { Image(systemName: "gearshape").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Settings")
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
                GroupIcon(group: group).frame(width: 22, height: 22)
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
                if hovering { actions }
                Text(fmtBytes(group.memory))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(memColor)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .padding(.leading, indent ? 22 : 0)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if group.kind == .claudeAll { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
            .help(helpText)

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
        case .app: return group.bundlePath ?? group.name
        default: return ""
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            switch group.kind {
            case .app where m.canQuit(group):
                let marked = m.expendable.contains(group.bundleID ?? "-")
                Button { m.toggleExpendable(group) } label: {
                    Image(systemName: marked ? "bolt.fill" : "bolt").foregroundStyle(marked ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(marked ? "Will be auto-quit when memory is critical (if Auto-free is on). Click to unmark."
                             : "Allow Mac Monitor to auto-quit this app when memory is critical")
                Button("Relaunch") { m.relaunch(group) }.controlSize(.small)
                    .help("Quit and reopen — gives back memory the app has leaked over time")
                Button("Quit") { m.quit(group) }.controlSize(.small)
                    .contextMenu { Button("Force Quit") { m.forceQuit(group) } }
            case .claudeSession:
                ConfirmButton(title: "Pause") { m.endSession(group) }
                    .help("Stops this session to free its memory. The conversation stays saved — reopen it from the Claude sidebar to pick up where you left off. Don't pause a session that's mid-task.")
            case .script where group.id.hasPrefix("vm"):
                Image(systemName: "info.circle").foregroundStyle(.secondary)
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
            setting("Pause idle Claude sessions",
                    "Conversations stay saved. Sessions running something are never paused.",
                    isOn: $m.autoPauseEnabled) {
                Picker("", selection: $m.autoPauseMinutes) {
                    ForEach(Config.autoPauseChoices, id: \.self) { Text("after \($0) min").tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(width: 110).disabled(!m.autoPauseEnabled)
            }
            setting("Free memory automatically",
                    m.expendable.isEmpty ? "When memory is critical, quits apps you mark with ⚡ (hover an app row)."
                                         : "When memory is critical, quits your ⚡ apps, biggest first.",
                    isOn: $m.guardEnabled) { EmptyView() }
            setting("Warn me when memory runs out", nil, isOn: $m.alertsEnabled) { EmptyView() }
            setting("Open at login", nil, isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 })) { EmptyView() }

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
