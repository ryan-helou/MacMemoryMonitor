import Foundation
import Darwin

enum GroupKind: Hashable {
    case app             // a regular app (Chrome, Spotify, Teams…) incl. all its helper processes
    case claudeSession   // one Claude Code session incl. its MCP servers and anything it spawned
    case claudeAll       // synthetic parent row holding every session
    case script          // a background process/script not belonging to an app
    case system          // macOS itself — shown, never acted on
}

struct ProcGroup: Identifiable {
    let id: String
    var kind: GroupKind
    var name: String
    var detail: String = ""
    var memory: UInt64 = 0
    var cpu: Double = 0
    var pids: [pid_t] = []
    var rootPid: pid_t = 0
    var bundlePath: String?
    var bundleID: String?
    var started: Date?
    var cwd: String?
    var children: [ProcGroup] = []
    var fromDesktop = false        // session started by the Claude desktop app (resumable from its sidebar)
    var runningTask: String?       // a command/background job the session started after launch → never auto-pause
    var processCount: Int { pids.count }
}

struct Hog { let pid: pid_t; let name: String; let cpu: Double }

struct ScanResult {
    var groups: [ProcGroup] = []
    var hogs: [Hog] = []
    var spotlightCPU: Double = 0
}

private struct RawProc {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let footprint: UInt64
    let cpu: Double
    let start: Date
}

/// Path marker for Claude Code session binaries. Overridable only so tests can use a fake session
/// (the Claude app kills stray processes at the real path).
private let sessionMarker = ProcessInfo.processInfo.environment["MACMON_SESSION_MARKER"] ?? "/claude-code/"
private let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "sudo", "caffeinate"]
private let terminalApps: Set<String> = ["Terminal.app", "iTerm.app", "Warp.app", "Ghostty.app", "kitty.app", "Alacritty.app", "WezTerm.app"]
private let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "java", "Python"]

/// Walks every process, measures its real memory cost (physical footprint, which includes
/// what has been compressed — plain RSS hides most of it on a swapping Mac) and folds
/// helpers into the thing a person would recognise: an app, a Claude Code session, a script.
/// Not thread-safe: call from one serial queue.
final class ProcessScanner {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime: UInt64 = 0
    private var argsCache: [pid_t: String] = [:]
    private var cwdCache: [pid_t: String] = [:]
    private var bundleIDCache: [String: String] = [:]
    private let timebase: mach_timebase_info_data_t
    private let myPid = getpid()

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
    }

    private func ticksToNs(_ t: UInt64) -> UInt64 {
        t &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    func scan() -> ScanResult {
        let now = mach_absolute_time()
        let dtNs = prevTime == 0 ? 0 : ticksToNs(now - prevTime)
        prevTime = now

        var procs: [pid_t: RawProc] = [:]
        var newCPU: [pid_t: UInt64] = [:]
        for pid in listPids() where pid > 0 {
            var bsd = proc_bsdinfo()
            let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            let path = pidPath(pid)
            var footprint: UInt64 = 0
            var cpu = 0.0
            if let ru = rusage(pid) {
                footprint = ru.ri_phys_footprint
                let ns = ticksToNs(ru.ri_user_time &+ ru.ri_system_time)
                newCPU[pid] = ns
                if dtNs > 0, let prev = prevCPU[pid], ns >= prev {
                    cpu = Double(ns - prev) / Double(dtNs) * 100
                }
            }
            let name = path.isEmpty ? cString(bsd.pbi_name) : (path as NSString).lastPathComponent
            procs[pid] = RawProc(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path,
                                 footprint: footprint, cpu: cpu,
                                 start: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)))
        }
        prevCPU = newCPU
        argsCache = argsCache.filter { procs[$0.key] != nil }
        cwdCache = cwdCache.filter { procs[$0.key] != nil }

        var children: [pid_t: [pid_t]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }

        var assigned: [pid_t: String] = [:]   // pid -> group id
        var groups: [String: ProcGroup] = [:]

        func add(_ p: RawProc, to id: String) {
            assigned[p.pid] = id
            groups[id]!.memory += p.footprint
            groups[id]!.cpu += p.cpu
            groups[id]!.pids.append(p.pid)
        }
        func addSubtree(_ pid: pid_t, to id: String) {
            var stack = [pid]
            while let cur = stack.popLast() {
                guard let p = procs[cur], assigned[cur] == nil else { continue }
                add(p, to: id)
                stack.append(contentsOf: children[cur] ?? [])
            }
        }

        // 1. Claude Code sessions (+ every MCP server / tool they spawned).
        let isClaudeCode: (RawProc) -> Bool = { $0.path.contains(sessionMarker) && $0.name == "claude" }
        for p in procs.values where isClaudeCode(p) && p.pid != myPid {
            if let parent = procs[p.ppid], isClaudeCode(parent) { continue } // nested → belongs to parent session
            let id = "s\(p.pid)"
            let cwd = cwdCache[p.pid] ?? pidCwd(p.pid)
            cwdCache[p.pid] = cwd
            let folder = cwd.isEmpty ? "Session \(p.pid)" : (cwd as NSString).lastPathComponent
            groups[id] = ProcGroup(id: id, kind: .claudeSession, name: folder, rootPid: p.pid, started: p.start, cwd: cwd)
            addSubtree(p.pid, to: id)
            // Desktop sessions run as Claude.app → disclaimer → claude; terminal ones have a shell as parent.
            groups[id]!.fromDesktop = (procs[p.ppid]?.path.contains("/Claude.app/") ?? false)
            // MCP servers start with the session; anything started later is real work (a command, a Monitor, a build).
            let late = groups[id]!.pids.compactMap { procs[$0] }
                .filter { $0.pid != p.pid && $0.start.timeIntervalSince(p.start) > 60 }
            if let task = late.max(by: { $0.start < $1.start }) { groups[id]!.runningTask = task.name }
        }

        // 2. Apps (everything inside one .app bundle) and macOS itself.
        groups["system"] = ProcGroup(id: "system", kind: .system, name: "macOS & system services")
        for p in procs.values where assigned[p.pid] == nil && p.pid != myPid {
            // Virtual machines live under /System but are started by apps (e.g. Claude's sandbox VM) and can hold GBs.
            if p.name.hasPrefix("com.apple.Virtualization.VirtualMachine") && p.uid >= 500 {
                let id = "vm\(p.pid)"
                let owner = vmOwner(p.pid)
                groups[id] = ProcGroup(id: id, kind: .script, name: "Virtual machine" + (owner.isEmpty ? "" : " · \(owner)"),
                                       rootPid: p.pid, started: p.start)
                add(p, to: id)
                continue
            }
            if isSystem(p) { add(p, to: "system"); continue }
            if let bundle = outerBundle(p.path), p.path.contains("/Applications/") {
                if groups[bundle] == nil {
                    let display = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                    groups[bundle] = ProcGroup(id: bundle, kind: .app, name: display, bundlePath: bundle,
                                               bundleID: bundleID(bundle))
                }
                add(p, to: bundle)
            }
        }

        // 3. Loose processes: attach to the app that launched them (not terminals), else stand alone.
        let loose = procs.values.filter { assigned[$0.pid] == nil && $0.pid != myPid }
        for p in loose.sorted(by: { $0.pid < $1.pid }) where assigned[p.pid] == nil {
            if shellNames.contains(p.name) { add(p, to: "system"); continue }
            // climb to the top-most loose, non-shell ancestor
            var root = p
            while let parent = procs[root.ppid], assigned[parent.pid] == nil,
                  !shellNames.contains(parent.name), !isSystem(parent), parent.pid != 1 {
                root = parent
            }
            if let parent = procs[root.ppid], let gid = assigned[parent.pid],
               let g = groups[gid], g.kind == .app || g.kind == .claudeSession,
               !terminalApps.contains((g.bundlePath as NSString?)?.lastPathComponent ?? "") {
                addSubtree(root.pid, to: gid)
                continue
            }
            let id = "p\(root.pid)"
            groups[id] = ProcGroup(id: id, kind: .script, name: describe(root), rootPid: root.pid, started: root.start)
            addSubtree(root.pid, to: id)
        }

        var result = ScanResult()
        result.groups = groups.values.filter { $0.memory > 0 || $0.kind == .claudeSession }
        result.hogs = procs.values
            .filter { $0.cpu > 60 && $0.pid != myPid && !isSystem($0) }
            .sorted { $0.cpu > $1.cpu }
            .prefix(3)
            .map { Hog(pid: $0.pid, name: describe($0), cpu: $0.cpu) }
        result.spotlightCPU = procs.values
            .filter { $0.name.hasPrefix("mds") || $0.name.hasPrefix("mdworker") || $0.name == "corespotlightd" }
            .reduce(0) { $0 + $1.cpu }
        return result
    }

    // MARK: helpers

    private func isSystem(_ p: RawProc) -> Bool {
        if p.uid < 500 { return true }
        if p.path.isEmpty { return true }
        if p.path.contains("/Applications/") && !p.path.hasPrefix("/System/Library/") { return false }
        for prefix in ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/", "/Library/Developer/CommandLineTools/"]
        where p.path.hasPrefix(prefix) {
            // /usr/local and homebrew-style user tools are not "macOS"
            if prefix == "/usr/" && (p.path.hasPrefix("/usr/local/")) { return false }
            return true
        }
        return false
    }

    private func describe(_ p: RawProc) -> String {
        guard interpreters.contains(p.name) else { return p.name }
        let script = argsCache[p.pid] ?? scriptArg(p.pid)
        argsCache[p.pid] = script
        return script.isEmpty ? p.name : "\(p.name) · \(script)"
    }

    private func scriptArg(_ pid: pid_t) -> String {
        let args = processArgs(pid)
        guard args.count > 1 else { return "" }
        for a in args.dropFirst() where !a.hasPrefix("-") {
            let comps = (a as NSString).pathComponents.filter { $0 != "/" }
            if comps.count >= 2 { return comps.suffix(2).joined(separator: "/") }
            return a
        }
        return ""
    }

    private var vmOwnerCache: [pid_t: String] = [:]
    /// Best guess at which app a VM belongs to, from the disk images it has open.
    private func vmOwner(_ pid: pid_t) -> String {
        if let c = vmOwnerCache[pid] { return c }
        var owner = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-Fn", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if out.contains("/Claude.app/") || out.contains("Application Support/Claude") { owner = "Claude sandbox" }
            else if out.contains("Docker") { owner = "Docker" }
            else if out.contains("UTM") { owner = "UTM" }
        }
        vmOwnerCache[pid] = owner
        return owner
    }

    private func bundleID(_ bundle: String) -> String? {
        if let c = bundleIDCache[bundle] { return c }
        let id = Bundle(path: bundle)?.bundleIdentifier
        bundleIDCache[bundle] = id ?? ""
        return id
    }
}

// MARK: - libproc wrappers

func outerBundle(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return nil }
    return String(path[..<r.lowerBound]) + ".app"
}

private func listPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 128)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(0, got))))
}

private func pidPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

private func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var ru = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ru) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return r == 0 ? ru : nil
}

private func pidCwd(_ pid: pid_t) -> String {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
    return cString(info.pvi_cdir.vip_path)
}

private func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

/// argv via KERN_PROCARGS2 (only works for our own user's processes, which is all we need).
private func processArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // exec path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < Int(argc) && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}
