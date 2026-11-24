import AppKit

struct DiskItem: Identifiable { let url: URL; let size: UInt64; var id: String { url.path } }

/// Finds big things in the usual places (Downloads, Movies, developer caches). Runs only when you open the Disk screen.
enum DiskScanner {
    static func scan() -> [DiskItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [DiskItem] = []
        for rel in Config.diskScanFolders {
            let dir = home.appendingPathComponent(rel)
            guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles]) else { continue }
            for k in kids {
                let s = size(of: k)
                if Double(s) >= Config.diskMinItem { items.append(DiskItem(url: k, size: s)) }
            }
        }
        return items.sorted { $0.size > $1.size }.prefix(25).map { $0 }
    }

    static func size(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true {
            return UInt64(v.totalFileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += UInt64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Moves to the Trash (recoverable) — never deletes outright.
    static func trash(_ item: DiskItem, done: @escaping (Bool) -> Void) {
        NSWorkspace.shared.recycle([item.url]) { _, err in DispatchQueue.main.async { done(err == nil) } }
    }
}
