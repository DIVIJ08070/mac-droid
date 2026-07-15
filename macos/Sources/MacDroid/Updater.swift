import Foundation

/// Lightweight update check: fetches version.json from the site and compares it
/// with the bundled version. No framework — just a banner + a download link.
@MainActor
final class Updater: ObservableObject {
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var updateAvailable = false

    private let manifestURL = URL(string: "https://mac-droid.vercel.app/version.json")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func check() {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let mac = json["mac"] as? [String: Any],
                let version = mac["version"] as? String
            else { return }
            let urlString = mac["url"] as? String
            Task { @MainActor in
                guard let self else { return }
                self.latestVersion = version
                self.downloadURL = urlString.flatMap(URL.init(string:))
                self.updateAvailable = Self.isNewer(version, than: self.currentVersion)
            }
        }.resume()
    }

    /// True if `remote` is a higher dotted version than `local` (e.g. 1.2 > 1.0).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
