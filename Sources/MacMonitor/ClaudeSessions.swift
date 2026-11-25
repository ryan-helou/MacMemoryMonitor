import Foundation

/// What Claude Code itself knows about a running session: its title, when it was last used, how big its history is.
/// Found via the session id in the process arguments (`--resume=<id>`) → `~/.claude/projects/*/<id>.jsonl`.
struct SessionInfo {
    var title: String?
    var lastActivity: Date?      // the conversation file is written on every message → true "last used" time
    var transcriptBytes: UInt64 = 0
}

final class ClaudeSessionLookup {
    private var pathCache: [pid_t: String] = [:]          // pid → transcript path ("" = not found)
    private var titleCache: [String: (Date, String?)] = [:] // path → (mtime when read, title)
    private let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    func info(pid: pid_t, cwd: String = "", args: () -> [String]) -> SessionInfo {
        var path: String
        if let p = pathCache[pid] { path = p } else {
            path = findTranscript(args()) ?? ""
            pathCache[pid] = path
        }
        // Sessions started in a terminal usually have no id in their arguments: use the newest conversation
        // in their folder. (If two sessions share a folder this can only make one look *more* recently used.)
        if path.isEmpty, !cwd.isEmpty { path = newestTranscript(in: cwd) ?? "" }
        guard !path.isEmpty, let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return SessionInfo() }
        let mtime = attrs[.modificationDate] as? Date
        var info = SessionInfo(lastActivity: mtime, transcriptBytes: (attrs[.size] as? NSNumber)?.uint64Value ?? 0)
        if let cached = titleCache[path], cached.0 == mtime { info.title = cached.1 } else {
            let t = readTitle(path)
            titleCache[path] = (mtime ?? .distantPast, t)
            info.title = t
        }
        return info
    }

    func forget(except live: Set<pid_t>) { pathCache = pathCache.filter { live.contains($0.key) } }

    /// Claude Code stores a folder's conversations in ~/.claude/projects/<path with every non-letter/digit as "-">.
    private func newestTranscript(in cwd: String) -> String? {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = projects.appendingPathComponent(slug)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }
            .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                 < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }?
            .path
    }

    private func findTranscript(_ args: [String]) -> String? {
        var id: String?
        for (i, a) in args.enumerated() {
            if a.hasPrefix("--resume=") || a.hasPrefix("--session-id=") { id = String(a.split(separator: "=", maxSplits: 1).last ?? "") }
            else if (a == "--resume" || a == "--session-id"), i + 1 < args.count { id = args[i + 1] }
        }
        guard let id, id.count >= 32,
              let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f.path }
        }
        return nil
    }

    /// Latest `"customTitle":"…"` near the end of the file (files can be hundreds of MB — only the tail is read).
    private func readTitle(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "\"customTitle\":\"", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let title = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

/// Local (stdio) MCP servers registered for every project. Each one is started again in every session.
struct MCPAudit {
    var globalLocalServers: [String] = []

    static func read() -> MCPAudit {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return MCPAudit() }
        let local = servers.compactMap { name, v -> String? in
            guard let d = v as? [String: Any], d["command"] != nil else { return nil }   // http/sse servers cost nothing locally
            return name
        }
        return MCPAudit(globalLocalServers: local.sorted())
    }
}
