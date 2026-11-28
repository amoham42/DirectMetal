import CryptoKit
import Darwin
import Foundation

// MARK: - Public types

/// Which DirectMetal bundle is running, so the updater downloads the matching release asset.
enum AppEdition: String, Codable {
    /// `DirectMetal-Lite.app` (runtime downloaded on first launch) => `DirectMetal-Lite-macOS-arm64.dmg`.
    case lite
    /// Offline `DirectMetal.app` with an embedded runtime => `DirectMetal-macOS-arm64.dmg`.
    case offline

    var assetName: String { self == .lite ? "DirectMetal-Lite-macOS-arm64.dmg" : "DirectMetal-macOS-arm64.dmg" }
    var appName: String { self == .lite ? "DirectMetal-Lite.app" : "DirectMetal.app" }
    var displayName: String { self == .lite ? "DirectMetal Lite" : "DirectMetal" }
}

struct AppUpdateProgress {
    enum Phase: String {
        case resolving
        case downloading
        case verifying
        case mounting
        case validating
        case installing
        case done
    }

    let phase: Phase
    let bytesReceived: Int64
    /// `-1` when unknown.
    let totalBytes: Int64
    /// `0...1`, or `-1` while indeterminate.
    let fraction: Double
    let message: String
}

enum AppUpdateError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case mountFailed(String)
    case bundleNotFound(String)
    case codesignFailed(String)
    case installFailed(String)
    case noTargetApp(String)

    var description: String {
        switch self {
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 mismatch: expected \(expected), got \(actual). The download was discarded; nothing was modified."
        case .invalidURL(let m), .invalidChecksum(let m), .downloadFailed(let m), .mountFailed(let m),
             .bundleNotFound(let m), .codesignFailed(let m), .installFailed(let m), .noTargetApp(let m):
            return m
        }
    }
}

// MARK: - AppUpdater

/// Real self-updater: streaming download + live SHA-256 -> read-only `hdiutil` mount -> strict `codesign`
/// verification -> `ditto` into a sibling staging folder -> atomic `replaceItemAt` swap (automatic rollback)
/// -> optional relaunch. Also drives upstream MetalSharp-Wine runtime updates through `RuntimeManager`.
enum AppUpdater {
    static let defaultRuntimeUpdateURL = "https://api.github.com/repos/metalsharp/MetalSharp-Wine/releases/latest"
    static let runtimeStateFileName = "directmetal-runtime-update.json"
    private static let chunkSize = 4 * 1024 * 1024

    // MARK: Apply app update

    /// Downloads `dmgURL`, verifies its SHA-256, mounts it read-only, verifies the contained `.app` with
    /// `codesign --verify --deep --strict`, and atomically swaps it over `targetAppURL` (default: the running
    /// `.app`). Any failure before the swap leaves the target untouched; the swap itself is a single atomic
    /// `replaceItemAt`. Returns the installed `.app` URL.
    @discardableResult
    static func applyAppUpdate(
        dmgURL: URL,
        expectedSHA256: String?,
        sha256URL: URL? = nil,
        targetAppURL: URL? = nil,
        progress: ((AppUpdateProgress) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        func report(_ phase: AppUpdateProgress.Phase, _ message: String, _ done: Int64 = 0, _ total: Int64 = -1,
                    _ fraction: Double = -1) {
            progress?(AppUpdateProgress(phase: phase, bytesReceived: done, totalBytes: total, fraction: fraction, message: message))
        }

        // 1. Policy checks before touching the network or the disk.
        try validateSourceURL(dmgURL, what: "update")
        let target: URL
        if let t = targetAppURL {
            target = t.standardizedFileURL
        } else if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            target = Bundle.main.bundleURL.standardizedFileURL
        } else {
            throw AppUpdateError.noTargetApp(
                "DirectMetal is running as a bare CLI binary (\(Bundle.main.bundleURL.path)); pass --target-app <path/to/DirectMetal.app>")
        }
        guard target.pathExtension.lowercased() == "app" else {
            throw AppUpdateError.noTargetApp("Target \(target.path) is not a .app bundle")
        }
        var isDir: ObjCBool = false
        let targetExists = fm.fileExists(atPath: target.path, isDirectory: &isDir)
        if targetExists && !isDir.boolValue {
            throw AppUpdateError.noTargetApp("Target \(target.path) is not a directory")
        }
        let parent = target.deletingLastPathComponent()
        guard access(parent.path, W_OK) == 0 else {
            throw AppUpdateError.installFailed("Cannot write to \(parent.path) (\(String(cString: strerror(errno)))); move DirectMetal to a writable folder or reinstall it manually")
        }

        let fileName = dmgURL.lastPathComponent
        let wantSHA: String?
        if let raw = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            if raw == "skip" {
                guard envFlag("DIRECTMETAL_ALLOW_UNVERIFIED_UPDATE") else {
                    throw AppUpdateError.invalidChecksum(
                        "Refusing to skip SHA-256 verification: export DIRECTMETAL_ALLOW_UNVERIFIED_UPDATE=1 explicitly (local testing only)")
                }
                wantSHA = nil
            } else {
                guard isSHA256Hex(raw) else {
                    throw AppUpdateError.invalidChecksum("Expected SHA-256 must be 64 hex characters, got \"\(raw)\"")
                }
                wantSHA = raw
            }
        } else {
            // A checksum is mandatory: explicit sidecar URL, else the conventional `<dmg>.sha256` sidecar.
            let sidecar = sha256URL ?? URL(string: dmgURL.absoluteString + ".sha256")
            guard let sidecar else {
                throw AppUpdateError.invalidChecksum("No SHA-256 provided for \(dmgURL.absoluteString)")
            }
            report(.resolving, "Fetching SHA-256 from \(sidecar.absoluteString)")
            do {
                wantSHA = try fetchChecksum(from: sidecar, fileName: fileName)
            } catch {
                throw AppUpdateError.invalidChecksum("A SHA-256 is required (pass --sha256 <hex>): \(error)")
            }
        }

        // 2. Private work area (download + mount point), removed on every exit path.
        let work = fm.temporaryDirectory.appendingPathComponent("DirectMetal-Update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mountRoot, withIntermediateDirectories: false)
        var mountPoint: URL? = nil
        defer {
            var detached = true
            if let mp = mountPoint {
                let r = RuntimeManager.spawnAndWait(["/usr/bin/hdiutil", "detach", mp.path, "-force"], captureOutput: true)
                detached = r.status == 0
            }
            // Never recurse into a still-mounted volume.
            if detached { try? fm.removeItem(at: work) } else { try? fm.removeItem(at: work.appendingPathComponent(fileName)) }
        }

        // 3. Streaming download + live SHA-256.
        let dmg = work.appendingPathComponent(fileName.isEmpty ? "update.dmg" : fileName)
        report(.downloading, "Downloading \(dmgURL.absoluteString)", 0, -1, 0)
        let acquired = try acquire(dmgURL, to: dmg) { done, total in
            let frac = total > 0 ? min(Double(done) / Double(total), 1) : -1
            report(.downloading, "Downloading \(fileName)…", done, total, frac)
        }
        report(.downloading, "Download complete", acquired.bytes, acquired.bytes, 1)

        // 4. Strict SHA-256 (no disk changes outside the private work area so far).
        if let want = wantSHA {
            guard acquired.sha256 == want else {
                throw AppUpdateError.checksumMismatch(expected: want, actual: acquired.sha256)
            }
            report(.verifying, "SHA-256 verified: \(acquired.sha256)", 0, -1, 1)
        } else {
            report(.verifying, "SHA-256 verification SKIPPED (DIRECTMETAL_ALLOW_UNVERIFIED_UPDATE=1): \(acquired.sha256)", 0, -1, 1)
        }

        // 5. Read-only mount, never shown in Finder.
        report(.mounting, "Mounting \(fileName) read-only…")
        let mp = try attach(dmg, mountRoot: mountRoot)
        mountPoint = mp
        report(.mounting, "Mounted at \(mp.path)", 0, -1, 1)

        // 6. Locate + validate the new bundle.
        report(.validating, "Validating app bundle and code signature…")
        let newApp = try locateApp(inMount: mp, target: target)
        let newInfo = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let newVersion = (newInfo["CFBundleShortVersionString"] as? String) ?? "?"
        if targetExists,
           let oldInfo = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
           let oldID = oldInfo["CFBundleIdentifier"] as? String, let newID = newInfo["CFBundleIdentifier"] as? String,
           oldID != newID {
            throw AppUpdateError.bundleNotFound("Bundle identifier mismatch: installed \(oldID), update \(newID)")
        }
        let cs = RuntimeManager.spawnAndWait(["/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path], captureOutput: true)
        guard cs.status == 0 else {
            throw AppUpdateError.codesignFailed("codesign --verify --deep --strict failed for \(newApp.lastPathComponent): \(cs.output)")
        }
        if targetExists, let oldTeam = teamIdentifier(of: target) {
            let newTeam = teamIdentifier(of: newApp)
            guard newTeam == oldTeam else {
                throw AppUpdateError.codesignFailed("Signing team mismatch: installed app is signed by \(oldTeam), update by \(newTeam ?? "ad-hoc/none")")
            }
        }
        report(.validating, "\(newApp.lastPathComponent) \(newVersion) signature verified", 0, -1, 1)

        // 7. Stage next to the target (same volume) and swap atomically.
        report(.installing, "Installing DirectMetal \(newVersion) into \(target.path)…")
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".DirectMetal-update-staging-\(token)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        let ditto = RuntimeManager.spawnAndWait(["/usr/bin/ditto", newApp.path, staged.path], captureOutput: true)
        guard ditto.status == 0 else {
            throw AppUpdateError.installFailed("ditto failed (status \(ditto.status)): \(ditto.output)")
        }
        _ = RuntimeManager.spawnAndWait(["/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path], captureOutput: true)
        let csStaged = RuntimeManager.spawnAndWait(["/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path], captureOutput: true)
        guard csStaged.status == 0 else {
            throw AppUpdateError.codesignFailed("Staged copy failed codesign verification: \(csStaged.output)")
        }
        let installed: URL
        do {
            if targetExists {
                let backupName = ".\(target.lastPathComponent).previous-\(token)"
                installed = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: backupName, options: []) ?? target
            } else {
                try fm.moveItem(at: staged, to: target)
                installed = target
            }
        } catch {
            throw AppUpdateError.installFailed("Atomic replace of \(target.path) failed (previous version kept): \(error.localizedDescription)")
        }
        report(.done, "DirectMetal \(newVersion) installed at \(installed.path)", 0, -1, 1)
        return installed
    }

    /// Relaunches `appURL` as a new, LaunchServices-owned process (`open -n`) so the caller can quit.
    static func relaunchApp(at appURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", appURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Runtime update

    /// Installs the latest upstream MetalSharp-Wine release (`SHA256SUMS` verified) or an explicit archive
    /// through `RuntimeManager.installARM64ECRuntime`. A no-op when the installed runtime is already current.
    @discardableResult
    static func updateRuntime(
        zipURL: URL? = nil,
        expectedSHA256: String? = nil,
        progress: ((RuntimeInstallProgress) -> Void)? = nil
    ) throws -> URL {
        func report(_ phase: RuntimeInstallProgress.Phase, _ fraction: Double, _ message: String) {
            progress?(RuntimeInstallProgress(phase: phase, bytesReceived: 0, totalBytes: -1, fraction: fraction, message: message))
        }
        var source = zipURL
        var sha = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sha?.isEmpty == true { sha = nil }
        var version: String? = nil

        if source == nil {
            report(.resolving, -1, "Checking \(runtimeEndpoint) for MetalSharp-Wine releases…")
            let check = checkRuntime()
            if check.disabled {
                throw RuntimeInstallError.downloadFailed("Runtime update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1); pass --url explicitly")
            }
            if let err = check.error {
                throw RuntimeInstallError.downloadFailed("Runtime update check failed: \(err)")
            }
            if check.installed && !check.updateAvailable {
                let root = RuntimeManager.installedARM64ECRuntimeRoot() ?? RuntimeManager.userARM64ECRuntimeDir()
                report(.done, 1, "MetalSharp-Wine \(check.currentVersion) is up to date (latest \(check.latestVersion ?? "?"))")
                return root
            }
            guard let z = check.zipURL, let u = URL(string: z) else {
                throw RuntimeInstallError.invalidURL("Latest MetalSharp-Wine release has no MetalSharp-Wine-*-arm64.zip asset")
            }
            source = u
            version = check.latestVersion
            if sha == nil {
                guard let sums = check.sha256SumsURL, let sumsURL = URL(string: sums) else {
                    throw RuntimeInstallError.invalidChecksum("Release \(check.latestVersion ?? "?") publishes no SHA256SUMS; pass --sha256 <hex>")
                }
                report(.resolving, -1, "Fetching \(sumsURL.lastPathComponent)…")
                do {
                    sha = try fetchChecksum(from: sumsURL, fileName: check.assetName)
                } catch {
                    throw RuntimeInstallError.invalidChecksum("\(error)")
                }
            }
        } else if sha == nil, let s = source, let sidecar = URL(string: s.absoluteString + ".sha256") {
            // Explicit archive without --sha256: `<zip>.sha256` sidecar when present, else RuntimeManager's
            // pinned official digest (the install fails cleanly on mismatch).
            sha = try? fetchChecksum(from: sidecar, fileName: s.lastPathComponent)
        }
        guard let src = source else { throw RuntimeInstallError.invalidURL("No runtime archive URL") }
        do {
            try validateSourceURL(src, what: "runtime")
        } catch {
            throw RuntimeInstallError.invalidURL("\(error)")
        }

        let root = try RuntimeManager.installARM64ECRuntime(sourceURL: src, expectedSHA256: sha, force: true, progress: progress)
        recordRuntimeState(root: root, version: version ?? runtimeVersion(fromAssetName: src.absoluteString))
        return root
    }

    private static func recordRuntimeState(root: URL, version: String?) {
        let metaURL = root.appendingPathComponent(RuntimeManager.metadataFileName)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = meta["sha256"] as? String else { return }
        let state: [String: Any] = [
            "version": version ?? RuntimeManager.arm64ecVersion,
            "sha256": sha,
            "archive_url": (meta["archive_url"] as? String) ?? "",
            "updated_utc": ISO8601DateFormatter().string(from: Date()),
        ]
        let url = RuntimeManager.userRuntimesRoot().appendingPathComponent(runtimeStateFileName)
        if let out = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: Helpers

    /// `TeamIdentifier` of a signed bundle, `nil` for ad-hoc / unsigned code.
    static func teamIdentifier(of app: URL) -> String? {
        let r = RuntimeManager.spawnAndWait(["/usr/bin/codesign", "-dv", "--verbose=2", app.path], captureOutput: true)
        guard r.status == 0 else { return nil }
        for line in r.output.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let v = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v == "not set") ? nil : v
        }
        return nil
    }

    private static func attach(_ dmg: URL, mountRoot: URL) throws -> URL {
        let r = RuntimeManager.spawnAndWait(
            ["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, "-plist", dmg.path],
            captureOutput: true
        )
        guard r.status == 0 else {
            throw AppUpdateError.mountFailed("hdiutil attach failed (status \(r.status)): \(r.output)")
        }
        // stdout + stderr are merged: isolate the XML property list.
        guard let start = r.output.range(of: "<?xml"), let end = r.output.range(of: "</plist>", options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(r.output[start.lowerBound..<end.upperBound].utf8), options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw AppUpdateError.mountFailed("Could not parse hdiutil attach -plist output")
        }
        let mounts = entities.compactMap { $0["mount-point"] as? String }.filter { !$0.isEmpty }
        guard let mp = mounts.first else {
            // Detach whatever was attached so nothing is leaked.
            for dev in entities.compactMap({ $0["dev-entry"] as? String }).prefix(1) {
                _ = RuntimeManager.spawnAndWait(["/usr/bin/hdiutil", "detach", dev, "-force"], captureOutput: true)
            }
            throw AppUpdateError.mountFailed("The disk image has no mountable volume")
        }
        return URL(fileURLWithPath: mp, isDirectory: true)
    }

    private static func locateApp(inMount mount: URL, target: URL) throws -> URL {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let apps = items.filter { $0.pathExtension.lowercased() == "app" }
        let edition = runningEdition(bundleURL: target)
        let preferred = [target.lastPathComponent, edition.appName, AppEdition.lite.appName, AppEdition.offline.appName]
        let pick = preferred.lazy.compactMap { name in apps.first { $0.lastPathComponent == name } }.first
            ?? apps.first { $0.lastPathComponent.hasPrefix("DirectMetal") }
        guard let app = pick else {
            throw AppUpdateError.bundleNotFound(
                "No DirectMetal .app found in the disk image (found: \(apps.map(\.lastPathComponent).joined(separator: ", ")))")
        }
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any],
              let exe = dict["CFBundleExecutable"] as? String,
              access(app.appendingPathComponent("Contents/MacOS/\(exe)").path, X_OK) == 0 else {
            throw AppUpdateError.bundleNotFound("\(app.lastPathComponent) is not a valid app bundle (missing Info.plist or executable)")
        }
        return app
    }

    private static func writeAll(_ fd: Int32, _ chunk: UnsafeRawBufferPointer) throws {
        guard var p = chunk.baseAddress else { return }
        var left = chunk.count
        while left > 0 {
            let w = write(fd, p, left)
            if w < 0 {
                if errno == EINTR { continue }
                throw AppUpdateError.downloadFailed("write failed: \(String(cString: strerror(errno)))")
            }
            left -= w
            p += w
        }
    }

    /// Copies (`file://`) or downloads (`http(s)://`) into `dst`, hashing every chunk as it is written.
    private static func acquire(_ url: URL, to dst: URL, progress: @escaping (Int64, Int64) -> Void) throws -> (sha256: String, bytes: Int64) {
        let fd = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw AppUpdateError.downloadFailed("open(\(dst.path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        if url.isFileURL {
            let src = open(url.path, O_RDONLY)
            guard src >= 0 else {
                throw AppUpdateError.downloadFailed("Update image not found: \(url.path)")
            }
            defer { close(src) }
            var st = stat()
            guard fstat(src, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                throw AppUpdateError.downloadFailed("Update image is not a regular file: \(url.path)")
            }
            let total = Int64(st.st_size)
            var hasher = SHA256()
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { buf.deallocate() }
            var done: Int64 = 0
            var last: UInt64 = 0
            while true {
                let n = read(src, buf, chunkSize)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AppUpdateError.downloadFailed("read(\(url.path)) failed: \(String(cString: strerror(errno)))")
                }
                if n == 0 { break }
                let chunk = UnsafeRawBufferPointer(start: buf, count: n)
                hasher.update(bufferPointer: chunk)
                try writeAll(fd, chunk)
                done += Int64(n)
                let now = DispatchTime.now().uptimeNanoseconds
                if now - last > 100_000_000 {
                    last = now
                    progress(done, total)
                }
            }
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), done)
        }

        let delegate = UpdateDownloadDelegate(fd: fd, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 2 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("DirectMetal/\(RuntimeLauncher.appVersion()) (AppUpdater)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()
        if let err = delegate.failure {
            throw AppUpdateError.downloadFailed("Download of \(url.absoluteString) failed: \(err)")
        }
        return (delegate.finalDigest().map { String(format: "%02x", $0) }.joined(), delegate.received)
    }

    /// Serial delegate queue: the waiting thread only reads state after `done` fires.
    private final class UpdateDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let fd: Int32
        let progress: (Int64, Int64) -> Void
        let done = DispatchSemaphore(value: 0)
        private var hasher = SHA256()
        private(set) var received: Int64 = 0
        private(set) var expected: Int64 = -1
        private(set) var failure: String?
        private var lastReport: UInt64 = 0

        init(fd: Int32, progress: @escaping (Int64, Int64) -> Void) {
            self.fd = fd
            self.progress = progress
        }

        func finalDigest() -> SHA256.Digest { hasher.finalize() }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "HTTP \(http.statusCode)"
                completionHandler(.cancel)
                return
            }
            expected = response.expectedContentLength
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            do {
                try data.withUnsafeBytes { raw in
                    hasher.update(bufferPointer: raw)
                    try AppUpdater.writeAll(fd, raw)
                }
            } catch {
                failure = "\(error)"
                dataTask.cancel()
                return
            }
            received += Int64(data.count)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 100_000_000 {
                lastReport = now
                progress(received, expected)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, failure == nil { failure = error.localizedDescription }
            if failure == nil, expected > 0, received != expected {
                failure = "truncated download (\(received) of \(expected) bytes)"
            }
            done.signal()
        }
    }
}
