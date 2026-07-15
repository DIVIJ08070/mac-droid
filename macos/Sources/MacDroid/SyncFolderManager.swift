import Foundation

/// P2P folder sync ("personal Dropbox"): a folder on the Mac auto-mirrors a
/// folder on the phone. Both sides periodically exchange manifests (relative
/// path + size + mtime) over the encrypted control channel; whichever side is
/// missing a file — or has an older copy — pulls it over the (encrypted) file
/// channel. Newest mtime wins; received files are stamped with the sender's
/// mtime so an incoming write never echoes back. v1 mirrors adds & updates;
/// deletions are NOT propagated (nothing is ever removed by sync).
@MainActor
final class SyncFolderManager: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "syncEnabled") }
    }
    @Published var folderPath: String {
        didSet { UserDefaults.standard.set(folderPath, forKey: "syncFolder") }
    }
    @Published var status = ""
    @Published var lastSync: Date?

    /// Send a packet on the control channel (wired by ServerManager).
    var sendManifestPacket: (([[String: Any]]) -> Void)?
    /// Ask the peer for a file (wired by ServerManager).
    var requestPull: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private var timer: Timer?
    private var pulling = Set<String>()

    static let mtimeToleranceMs: Int64 = 2000   // FAT/MediaStore granularity
    static let maxFiles = 1000

    init() {
        enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
        folderPath = UserDefaults.standard.string(forKey: "syncFolder")
            ?? (NSHomeDirectory() + "/Bifrost Sync")
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    func ensureFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    // MARK: lifecycle

    /// Start periodic manifest broadcasts (call when paired; stops on disconnect).
    func start() {
        stop()
        guard enabled else { return }
        ensureFolder()
        broadcast()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcast() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pulling.removeAll()
    }

    /// Send our current manifest to the phone.
    func broadcast() {
        guard enabled else { return }
        sendManifestPacket?(manifest())
    }

    // MARK: manifest

    /// [{p: relative path, s: size, m: mtime ms}] for every regular file.
    func manifest() -> [[String: Any]] {
        ensureFolder()
        var out: [[String: Any]] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return out }
        let rootPath = folderURL.standardizedFileURL.path
        for case let url as URL in walker {
            guard out.count < Self.maxFiles else {
                onLog?("Sync: folder has over \(Self.maxFiles) files — extra files are skipped")
                break
            }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true,
                let size = values.fileSize,
                let mtime = values.contentModificationDate
            else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let rel = String(full.dropFirst(rootPath.count + 1))
            if rel.hasSuffix(".part") { continue }   // in-flight temp files
            out.append(["p": rel, "s": size, "m": Int64(mtime.timeIntervalSince1970 * 1000)])
        }
        return out
    }

    /// Compare the phone's manifest with ours; pull anything missing or newer.
    func applyRemoteManifest(_ files: [[String: Any]]) {
        guard enabled else { return }
        ensureFolder()
        var pulled = 0
        for entry in files {
            guard
                let rel = entry["p"] as? String,
                let remoteM = (entry["m"] as? NSNumber)?.int64Value,
                let local = Self.sanitize(rel, under: folderURL)
            else { continue }
            let localM = Self.mtimeMs(of: local)
            if localM == nil || remoteM > localM! + Self.mtimeToleranceMs {
                guard !pulling.contains(rel) else { continue }
                pulling.insert(rel)
                pulled += 1
                requestPull?(rel)
            }
        }
        if pulled > 0 {
            status = "Syncing \(pulled) file\(pulled == 1 ? "" : "s")…"
            onLog?("Sync: pulling \(pulled) file(s) from the phone")
        } else if pulling.isEmpty {
            status = "Up to date"
            lastSync = Date()
        }
    }

    /// A sync transfer finished (or failed) — clear its in-flight marker.
    func pullFinished(_ rel: String, success: Bool) {
        pulling.remove(rel)
        if pulling.isEmpty {
            status = success ? "Up to date" : status
            lastSync = Date()
            // Our folder changed — let the phone know so it stays a mirror.
            broadcast()
        }
    }

    // MARK: helpers

    /// Resolve a RELATIVE manifest path under `root`, refusing traversal
    /// ("../", absolute paths, empty/hidden components) AND symlink escapes
    /// (resolve symlinks in existing components before the containment check).
    static func sanitize(_ rel: String, under root: URL) -> URL? {
        guard !rel.isEmpty, !rel.hasPrefix("/"), rel.count < 1024 else { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            if part == ".." || part == "." || part.isEmpty || part.hasPrefix(".") { return nil }
        }
        let rootResolved = root.resolvingSymlinksInPath()
        let dest = parts.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard dest.path.hasPrefix(rootResolved.path + "/") else { return nil }
        return dest
    }

    /// Keep a recoverable copy of a file about to be overwritten in a hidden
    /// ".bifrost-trash" (excluded from the manifest) so a newest-wins clobber is
    /// never unrecoverable.
    func backupBeforeOverwrite(_ dest: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else { return }
        let trash = folderURL.appendingPathComponent(".bifrost-trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let rel = dest.path.replacingOccurrences(of: folderURL.standardizedFileURL.path + "/", with: "")
            .replacingOccurrences(of: "/", with: "_")
        let bak = trash.appendingPathComponent("\(rel).\(Self.mtimeMs(of: dest) ?? 0)")
        try? fm.removeItem(at: bak)
        try? fm.moveItem(at: dest, to: bak)
    }

    static func mtimeMs(of url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
