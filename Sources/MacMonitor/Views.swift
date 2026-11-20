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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView()
            if !m.tips.isEmpty { TipsView() }
            Divider()
            HStack {
                Text("What's using memory").font(.headline)
                Spacer()
                Text("real footprint").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(m.rows) { g in GroupRow(group: g) }
                }
            }
            .frame(height: 300)
            Divider()
            FooterView()
        }
        .padding(14)
        .frame(width: 440)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let s = m.mem
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(s.health.color).frame(width: 10, height: 10)
                Text(s.health.title).font(.title3.weight(.semibold))
                Spacer()
                Text("\(s.pressurePercent)%").font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(s.health.color)
                    .help("Memory pressure: how hard macOS is working to find free RAM")
            }
            MemoryBar(s: s).frame(height: 12)
            HStack(spacing: 10) {
                Legend(color: .blue, label: "Apps", value: s.app)
                Legend(color: .orange, label: "System", value: s.wired)
                Legend(color: .purple, label: "Compressed", value: s.compressed)
                Spacer()
                Text("of \(fmtBytes(s.total))").font(.caption).foregroundStyle(.secondary)
            }
            Sparkline(values: m.history, color: s.health.color).frame(height: 28)
            HStack(spacing: 14) {
                Stat(label: "Swap used", value: fmtBytes(s.swapUsed), warn: Double(s.swapUsed) > 2 * 1_073_741_824)
                Stat(label: "Swap reads", value: fmtRate(s.swapInRate), warn: s.isThrashing)
                Stat(label: "CPU", value: "\(Int(s.cpuUsage))%", warn: s.cpuUsage > 85)
                Stat(label: "Squeezed", value: fmtBytes(s.compressedOriginal), warn: false)
                    .help("Data macOS has compressed to fit in RAM. Compressing/decompressing costs CPU.")
            }
        }
    }
}

struct MemoryBar: View {
    let s: MemorySnapshot
    var body: some View {
        GeometryReader { geo in
            let total = max(Double(s.total), 1)
            let w = geo.size.width
            HStack(spacing: 1) {
                Rectangle().fill(.blue).frame(width: w * min(1, Double(s.app) / total))
                Rectangle().fill(.orange).frame(width: w * min(1, Double(s.wired) / total))
                Rectangle().fill(.purple).frame(width: w * min(1, Double(s.compressed) / total))
                Rectangle().fill(.quaternary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

struct Legend: View {
    let color: Color; let label: String; let value: UInt64
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(fmtBytes(value))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let label: String; let value: String; let warn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(warn ? .red : .primary)
        }
    }
}

struct Sparkline: View {
    let values: [Double]; let color: Color
    var body: some View {
        GeometryReader { geo in
            let n = max(values.count - 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(n), y: geo.size.height * (1 - CGFloat(min(v, 100)) / 100))
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                }.fill(color.opacity(0.15))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(color, lineWidth: 1.5)
            }
        }
        .help("Memory pressure over the last 3 minutes")
    }
}

// MARK: - Tips

struct TipsView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(m.tips) { tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tip.icon).foregroundStyle(.orange).frame(width: 16)
                    Text(tip.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let title = tip.actionTitle, let action = tip.action {
                        if tip.confirm {
                            ConfirmButton(title: title, action: action)
                        } else {
                            Button(title, action: action).controlSize(.small)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }
        }
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
                if group.kind == .claudeAll {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 10)
                }
                GroupIcon(group: group).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(group.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering || group.kind == .claudeAll { actions }
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
        let gb = Double(group.memory) / 1_073_741_824
        return gb >= 1.5 ? .red : gb >= 0.7 ? .orange : .primary
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

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $m.guardEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-free memory when critical").font(.callout)
                    Text(m.expendable.isEmpty
                         ? "Mark apps with ⚡︎ (hover a row) to allow auto-quit. Nothing else is ever touched."
                         : "Will quit ⚡︎ apps, biggest first, when your Mac is about to freeze.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            Toggle("Warn me when memory runs out", isOn: $m.alertsEnabled).toggleStyle(.switch).controlSize(.small).font(.callout)
            Toggle("Open at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                .toggleStyle(.switch).controlSize(.small).font(.callout)

            if !m.actionLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(m.actionLog, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit Mac Monitor") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}
