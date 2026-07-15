import Foundation
import AppKit
import Security

/// Update check + one-click in-app self-update. No Apple Developer account or
/// notarization needed: we download the signed zip, verify it carries the SAME
/// code signature as the running app (so a tampered or foreign build is refused),
/// stage it NEXT TO the installed app while we can still report errors, then a
/// small detached helper re-verifies with codesign and swaps atomically
/// (move-aside + rollback — the old app is never deleted before the new one is
/// in place), and relaunches.
@MainActor
final class Updater: NSObject, ObservableObject {
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var updateAvailable = false
    @Published var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0…1
        case installing
        case failed(String)
    }

    private let manifestURL = URL(string: "https://mac-droid.vercel.app/version.json")!
    /// Only download update payloads from our own origin, over HTTPS.
    private let allowedHost = "mac-droid.vercel.app"
    private var downloadSession: URLSession?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: - Manifest check

    func check() {
        sweepLeftovers()
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

    /// True if `remote` is a higher dotted version than `local` (e.g. 1.2 > 1.0,
    /// 1.10 > 1.9). Tolerates a leading "v" and trailing junk in a segment
    /// ("2-beta" → 2) instead of silently treating the whole segment as 0.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { seg in
                Int(seg.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - Self update

    /// Open the plain download page — fallback when self-update can't run.
    func openInBrowser() {
        NSWorkspace.shared.open(downloadURL ?? URL(string: "https://mac-droid.vercel.app/")!)
    }

    func installUpdate() {
        switch phase {
        case .downloading, .installing: return   // already in progress
        default: break
        }
        // Only fetch our own origin over HTTPS; anything else goes to the browser.
        guard let url = downloadURL, url.scheme == "https", url.host == allowedHost else {
            openInBrowser(); return
        }
        // Fail fast (with a real explanation) if we can't swap the bundle later:
        // translocated app (running quarantined from Downloads) or unwritable dir.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") {
            phase = .failed("macOS is running Bifrost from a temporary quarantined location — move Bifrost.app into Applications, relaunch it from there, then update.")
            return
        }
        let parentDir = (bundlePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundlePath), fm.isWritableFile(atPath: parentDir) else {
            phase = .failed("No permission to replace the app in \(parentDir) — use the browser download instead.")
            return
        }

        phase = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadSession = session
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 120
        session.downloadTask(with: req).resume()
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        // A delegate-backed session strongly retains its delegate until
        // invalidated — dropping the reference alone would leak it every retry.
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
    }

    /// Runs after the zip is on disk: unzip, verify, stage next to the app, hand off.
    private func beginInstall(zipURL: URL, staging: URL) {
        phase = .installing
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        let current = currentVersion
        let installPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .userInitiated) {
            do {
                try Updater.unpackVerifyAndSwap(
                    zipURL: zipURL, staging: staging,
                    currentVersion: current, installPath: installPath, pid: pid
                )
                // The helper is now waiting for us to quit before it swaps + relaunches.
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                let msg = (error as NSError).localizedDescription
                await MainActor.run { self.fail(msg) }
            }
        }
    }

    /// Delete leftovers a previous (possibly interrupted) update may have left:
    /// temp staging dirs, helper scripts, and stale .new/.bak siblings of the app.
    private func sweepLeftovers() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix("BifrostUpdate-") || name.hasPrefix("bifrost-update-") {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        let bundlePath = Bundle.main.bundlePath
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let appName = (bundlePath as NSString).lastPathComponent
        try? fm.removeItem(atPath: bundlePath + ".new")
        if let siblings = try? fm.contentsOfDirectory(atPath: parent) {
            for name in siblings where name.hasPrefix(appName + ".bak.") {
                try? fm.removeItem(atPath: (parent as NSString).appendingPathComponent(name))
            }
        }
    }

    // MARK: - Heavy lifting (off the main actor)

    nonisolated private static func err(_ m: String) -> NSError {
        NSError(domain: "Bifrost.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    nonisolated static func unpackVerifyAndSwap(
        zipURL: URL, staging: URL,
        currentVersion: String, installPath: String, pid: Int32
    ) throws {
        let fm = FileManager.default
        // Everything we extract lives inside `staging`; it is no longer needed once
        // we've copied the app next to the install path, and must not linger on
        // failure either — so it's cleaned up unconditionally.
        defer { try? fm.removeItem(at: staging) }

        // 1) Unzip with ditto (the zip was made with `ditto -c -k --keepParent`).
        let extractDir = staging.appendingPathComponent("x", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw err("Couldn’t unpack the update.") }

        // 2) Find the .app inside.
        let apps = (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let newApp = apps.first else { throw err("The update didn’t contain an app.") }

        // 3) Anti-downgrade, fail-closed: refuse unless we can READ a version and
        //    it is strictly newer than what we're running.
        guard let newVersion = Bundle(url: newApp)?
                .infoDictionary?["CFBundleShortVersionString"] as? String,
              isNewer(newVersion, than: currentVersion) else {
            throw err("Downloaded build isn’t newer than \(currentVersion) — not installing.")
        }

        // 4) Security gate: the download must carry the SAME code signature as us.
        guard matchesOurSignature(newApp) else {
            throw err("The update’s signature didn’t match this app — refusing to install it.")
        }

        // 5) Stage the verified app NEXT TO the installed one (same volume, so the
        //    final swap is an atomic rename) while we're still alive to report
        //    errors, then verify AGAIN at the final staging path.
        let stagePath = installPath + ".new"
        try? fm.removeItem(atPath: stagePath)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [newApp.path, stagePath]
        try copy.run(); copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            try? fm.removeItem(atPath: stagePath)
            throw err("Couldn’t stage the update next to the app — check that \((installPath as NSString).deletingLastPathComponent) is writable.")
        }
        guard matchesOurSignature(URL(fileURLWithPath: stagePath)) else {
            try? fm.removeItem(atPath: stagePath)
            throw err("The staged update failed signature verification — not installing.")
        }

        // 6) Hand off to a detached helper that waits for us to quit, re-verifies
        //    with codesign (pinned to our designated requirement), and swaps with
        //    move-aside + rollback so an app always exists at the install path.
        guard let requirementText = ourRequirementText() else {
            try? fm.removeItem(atPath: stagePath)
            throw err("Couldn’t read this app’s code-signing requirement.")
        }
        try spawnSwapHelper(installPath: installPath, pid: pid, requirement: requirementText)
    }

    /// The running app's designated code requirement, or nil.
    nonisolated static func ourDesignatedRequirement() -> SecRequirement? {
        let flags = SecCSFlags(rawValue: 0)
        var selfCode: SecCode?
        guard SecCodeCopySelf(flags, &selfCode) == errSecSuccess, let selfCode else { return nil }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, flags, &selfStatic) == errSecSuccess,
              let selfStatic else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, flags, &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    /// Our designated requirement as codesign-compatible text (for `codesign -R`).
    nonisolated static func ourRequirementText() -> String? {
        guard let requirement = ourDesignatedRequirement() else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }

    /// True iff `appURL` satisfies the running app’s designated code requirement.
    /// The bundle being checked is UNTRUSTED (it came off the network), so validate
    /// strictly: all architecture slices, nested code, and strict resource rules —
    /// default flags would only check the native slice.
    nonisolated static func matchesOurSignature(_ appURL: URL) -> Bool {
        guard let requirement = ourDesignatedRequirement() else { return false }
        var newStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &newStatic) == errSecSuccess,
              let newStatic else { return false }
        let checkFlags = SecCSFlags(
            rawValue: SecCSFlags.RawValue(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        )
        return SecStaticCodeCheckValidity(newStatic, checkFlags, requirement) == errSecSuccess
    }

    nonisolated static func spawnSwapHelper(installPath: String, pid: Int32, requirement: String) throws {
        // Values arrive as $1/$2/$3 (no interpolation into the script) so paths and
        // the requirement text can never break out of their quoting.
        // Invariants: the old app is moved aside, never deleted, until the new one
        // is in place; every mv is checked; any failure rolls back and reopens the
        // old app; the staged bundle is re-verified by codesign before the swap.
        let script = """
        #!/bin/bash
        OLD_PID="$1"; DEST="$2"; REQ="$3"
        STAGE="${DEST}.new"
        abort() { /bin/rm -rf "$STAGE"; /usr/bin/open "$DEST" 2>/dev/null; /bin/rm -f "$0"; exit 0; }
        # Wait (max ~30s) for the old app to quit so its bundle isn't in use.
        for i in $(seq 1 60); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.5; done
        [ -d "$STAGE/Contents/MacOS" ] || abort
        # Final gate: the staged bundle must still satisfy our designated requirement.
        /usr/bin/codesign --verify --strict --test-requirement "=$REQ" "$STAGE" 2>/dev/null || abort
        BAK="${DEST}.bak.$$"
        if /bin/mv "$DEST" "$BAK" 2>/dev/null || [ ! -e "$DEST" ]; then
          if /bin/mv "$STAGE" "$DEST"; then
            /bin/rm -rf "$BAK"
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            /usr/bin/open "$DEST"
          else
            [ -e "$BAK" ] && /bin/mv "$BAK" "$DEST" 2>/dev/null
            /bin/rm -rf "$STAGE"
            /usr/bin/open "$DEST" 2>/dev/null
          fi
        else
          /bin/rm -rf "$STAGE"
          /usr/bin/open "$DEST" 2>/dev/null
        fi
        /bin/rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bifrost-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, String(pid), installPath, requirement]
        try p.run()   // detached on purpose: it must outlive us to do the swap
    }
}

extension Updater: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading = self.phase { self.phase = .downloading(p) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // A 404/500 still "finishes" the download with the error page as the body —
        // catch it here instead of letting ditto choke on HTML and misreport.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor in self.fail("Update download failed — server returned HTTP \(code).") }
            return
        }
        // `location` is deleted as soon as this returns — move it out synchronously.
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("BifrostUpdate-\(UUID().uuidString)", isDirectory: true)
        let zipURL = staging.appendingPathComponent("Bifrost.app.zip")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: zipURL)
        } catch {
            try? fm.removeItem(at: staging)
            Task { @MainActor in self.fail("Couldn’t save the download.") }
            return
        }
        Task { @MainActor in self.beginInstall(zipURL: zipURL, staging: staging) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }   // nil == success; handled in didFinishDownloadingTo
        Task { @MainActor in
            if case .installing = self.phase { return }   // already downloaded ok
            self.fail("Download failed: \(error.localizedDescription)")
        }
    }
}
