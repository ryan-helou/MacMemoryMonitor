import AppKit
import Combine
import SwiftUI

@main
struct MacMonitorMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") { dump(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private var sub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        let host = NSHostingController(rootView: PopoverView().environmentObject(monitor))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        sub = monitor.$mem.sink { [weak self] in self?.render($0) }
        monitor.start()
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggle() }
        }
    }

    private func render(_ s: MemorySnapshot) {
        let dot: NSColor = switch s.health {
        case .healthy: .systemGreen
        case .strained: .systemOrange
        case .critical: .systemRed
        }
        let title = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: dot, .font: NSFont.systemFont(ofSize: 10),
            .baselineOffset: 1,
        ])
        title.append(NSAttributedString(string: "\(s.pressurePercent)%", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ]))
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "Memory \(fmtBytes(s.used)) / \(fmtBytes(s.total)) · Swap \(fmtBytes(s.swapUsed))"
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.visible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.visible = false
    }
}

/// `MacMonitor --dump` prints one reading to the terminal (for checking the numbers).
private func dump() {
    let sampler = SystemSampler(), scanner = ProcessScanner()
    _ = sampler.sample(); _ = scanner.scan()
    Thread.sleep(forTimeInterval: 2)
    let s = sampler.sample(), r = scanner.scan()
    print("pressure \(s.pressurePercent)% level \(s.pressureLevel) health \(s.health)")
    print("apps \(fmtBytes(s.app)) wired \(fmtBytes(s.wired)) compressed \(fmtBytes(s.compressed)) (holding \(fmtBytes(s.compressedOriginal))) of \(fmtBytes(s.total))")
    print("swap \(fmtBytes(s.swapUsed))/\(fmtBytes(s.swapTotal)) in \(fmtRate(s.swapInRate)) out \(fmtRate(s.swapOutRate)) cpu \(Int(s.cpuUsage))% disk free \(fmtBytes(s.diskFree))")
    for g in r.groups.sorted(by: { $0.memory > $1.memory }).prefix(25) {
        print(String(format: "%9@ %5.0f%%  %3d  %@  %@", fmtBytes(g.memory), g.cpu, g.processCount, "\(g.kind)", g.name))
    }
    for h in r.hogs { print("HOG \(h.name) \(Int(h.cpu))%") }
    print("spotlight cpu \(Int(r.spotlightCPU))%")
}
