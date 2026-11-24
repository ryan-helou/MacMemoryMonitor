import Foundation

/// Asks GitHub for the latest release. Only runs when you click "Check for updates" or turn on weekly checks —
/// the app makes no other network requests.
enum Updates {
    static let repo = "ryan-helou/MacMemoryMonitor"
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func check(_ done: @escaping (_ latest: String?, _ url: URL?) -> Void) {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        URLSession.shared.dataTask(with: api) { data, _, _ in
            var tag: String?, link: URL?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tag = (j["tag_name"] as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
                link = (j["html_url"] as? String).flatMap(URL.init(string:))
            }
            DispatchQueue.main.async { done(tag, link) }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
