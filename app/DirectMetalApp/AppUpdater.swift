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

/// Upstream MetalSharp-Wine runtime release status (`DIRECTMETAL_RUNTIME_UPDATE_URL` overrides the endpoint).
struct RuntimeUpdateCheckResult: Codable, Equatable {
    var currentVersion: String
    var latestVersion: String?
    var updateAvailable: Bool
    var installed: Bool
    var releaseURL: String?
    var publishedAt: String?
    var assetName: String?
    var zipURL: String?
    var sha256SumsURL: String?
    var assetSize: Int64?
    var error: String?
    var checkedURL: String
    var disabled: Bool
}

/// DirectMetal app + MetalSharp-Wine runtime update status, checked concurrently.
struct DualUpdateStatus: Codable, Equatable {
    var app: UpdateCheckResult
    var runtime: RuntimeUpdateCheckResult

    var anyUpdateAvailable: Bool { app.updateAvailable || runtime.updateAvailable }
}

// MARK: - AppUpdater

/// Real self-updater: streaming download + live SHA-256 -> read-only `hdiutil` mount -> strict `codesign`
/// verification -> `ditto` into a sibling staging folder -> atomic `replaceItemAt` swap (automatic rollback)
/// -> optional relaunch. Also drives upstream MetalSharp-Wine runtime updates through `RuntimeManager`.
enum AppUpdater {
    static let defaultRuntimeUpdateURL = "https://api.github.com/repos/metalsharp/MetalSharp-Wine/releases/latest"
    static let runtimeStateFileName = "directmetal-runtime-update.json"
    private static let chunkSize = 4 * 1024 * 1024

    // MARK: Edition / assets

    /// `DIRECTMETAL_UPDATE_EDITION=lite|offline` overrides; otherwise derived from the running bundle.
    static func runningEdition(bundleURL: URL = Bundle.main.bundleURL) -> AppEdition {
        let env = ProcessInfo.processInfo.environment["DIRECTMETAL_UPDATE_EDITION"]?.lowercased() ?? ""
        if let e = AppEdition(rawValue: env) { return e }
        if env == "full" || env == "ultra" { return .offline }
        guard bundleURL.pathExtension.lowercased() == "app" else { return .lite }
        if bundleURL.lastPathComponent.lowercased().contains("lite") { return .lite }
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        for dir in ["Runtime-ARM64EC", "Runtime"] where access(contents.appendingPathComponent(dir).path, F_OK) == 0 {
            return .offline
        }
        return .lite
    }

    /// The `.dmg` (+ `.dmg.sha256` sidecar) asset of a GitHub release matching `edition`.
    static func resolveAppAsset(in release: [String: Any], edition: AppEdition)
        -> (name: String, dmgURL: String, sha256URL: String?, size: Int64?)? {
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        func name(_ a: [String: Any]) -> String { (a["name"] as? String) ?? "" }
        func url(_ a: [String: Any]) -> String? {
            guard let s = a["browser_download_url"] as? String, !s.isEmpty else { return nil }
            return s
        }
        let dmgs = assets.filter { name($0).lowercased().hasSuffix(".dmg") && url($0) != nil }
        let pick = dmgs.first { name($0) == edition.assetName }
            ?? dmgs.first { edition == .lite ? name($0).lowercased().contains("lite") : !name($0).lowercased().contains("lite") }
        guard let asset = pick, let dmgURL = url(asset) else { return nil }
        let dmgName = name(asset)
        let sidecar = assets.first { name($0) == dmgName + ".sha256" }
            ?? assets.first { ["sha256sums", "sha256sums.txt"].contains(name($0).lowercased()) }
        let size = (asset["size"] as? NSNumber)?.int64Value
        return (dmgName, dmgURL, sidecar.flatMap(url), size)
    }

    // MARK: Checks

    static var runtimeEndpoint: String {
        let env = ProcessInfo.processInfo.environment["DIRECTMETAL_RUNTIME_UPDATE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (env?.isEmpty == false) ? env! : defaultRuntimeUpdateURL
    }

    /// Version of the installed MetalSharp-Wine runtime: the version recorded by the last `updateRuntime`
    /// (only while its SHA-256 still matches the installed archive), else the archive file name, else
    /// `RuntimeManager.arm64ecVersion`.
    static func installedRuntimeVersion() -> String {
        let fallback = RuntimeManager.arm64ecVersion
        let metaURL = RuntimeManager.userARM64ECRuntimeDir().appendingPathComponent(RuntimeManager.metadataFileName)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        let installedSHA = (meta["sha256"] as? String)?.lowercased()
        let stateURL = RuntimeManager.userRuntimesRoot().appendingPathComponent(runtimeStateFileName)
        if let sd = try? Data(contentsOf: stateURL),
           let state = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
           let v = state["version"] as? String, !v.isEmpty,
           let s = (state["sha256"] as? String)?.lowercased(), s == installedSHA {
            return v
        }
        if let archive = meta["archive_url"] as? String, let v = runtimeVersion(fromAssetName: archive) {
            return v
        }
        return fallback
    }

    /// `.../MetalSharp-Wine-10.6-arm64.zip` -> `10.6`.
    static func runtimeVersion(fromAssetName raw: String) -> String? {
        let name = URL(string: raw)?.lastPathComponent ?? (raw as NSString).lastPathComponent
        guard let r = name.range(of: #"^MetalSharp-Wine-(.+)-arm64\.zip$"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let v = String(name[r]).dropFirst("MetalSharp-Wine-".count).dropLast("-arm64.zip".count)
        let s = String(v)
        return UpdateChecker.isVersionTag(s) ? UpdateChecker.normalizedVersion(s) : nil
    }

    /// Synchronous upstream runtime check (CLI / background threads only).
    static func checkRuntime() -> RuntimeUpdateCheckResult {
        let urlString = runtimeEndpoint
        let installed = RuntimeManager.status(checkCodesign: false, measureDisk: false).installed
        var result = RuntimeUpdateCheckResult(
            currentVersion: installedRuntimeVersion(), latestVersion: nil, updateAvailable: false, installed: installed,
            releaseURL: nil, publishedAt: nil, assetName: nil, zipURL: nil, sha256SumsURL: nil, assetSize: nil,
            error: nil, checkedURL: urlString, disabled: false
        )
        if UpdateChecker.isDisabled {
            result.disabled = true
            result.error = "update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1)"
            return result
        }
        let lookup = UpdateChecker.latestRelease(endpoint: urlString, productName: "MetalSharp-Wine")
        guard let rel = lookup.release, let tag = rel["tag_name"] as? String else {
            result.error = lookup.error ?? "no MetalSharp-Wine release found at \(urlString)"
            return result
        }
        result.latestVersion = UpdateChecker.normalizedVersion(tag)
        result.releaseURL = rel["html_url"] as? String
        result.publishedAt = rel["published_at"] as? String
        result.updateAvailable = UpdateChecker.compareVersions(tag, result.currentVersion) == .orderedDescending

        let assets = (rel["assets"] as? [[String: Any]]) ?? []
        func name(_ a: [String: Any]) -> String { (a["name"] as? String) ?? "" }
        let zips = assets.filter {
            name($0).range(of: #"^MetalSharp-Wine-.+-arm64\.zip$"#, options: [.regularExpression, .caseInsensitive]) != nil
                && ($0["browser_download_url"] as? String) != nil
        }
        let version = result.latestVersion ?? ""
        if let zip = zips.first(where: { name($0).contains(version) }) ?? zips.first {
            result.assetName = name(zip)
            result.zipURL = zip["browser_download_url"] as? String
            result.assetSize = (zip["size"] as? NSNumber)?.int64Value
            let sums = assets.first { ["sha256sums", "sha256sums.txt"].contains(name($0).lowercased()) }
                ?? assets.first { name($0) == name(zip) + ".sha256" }
            result.sha256SumsURL = sums?["browser_download_url"] as? String
        } else if result.updateAvailable {
            result.error = "release \(tag) has no MetalSharp-Wine-*-arm64.zip asset"
        }
        return result
    }

    private final class DualBox: @unchecked Sendable {
        var app: UpdateCheckResult?
        var runtime: RuntimeUpdateCheckResult?
    }

    /// App + runtime checks run concurrently (each bounded by `UpdateChecker.timeout`).
    static func checkAll(currentVersion: String = RuntimeLauncher.appVersion()) -> DualUpdateStatus {
        let box = DualBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.app = UpdateChecker.check(currentVersion: currentVersion)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.runtime = checkRuntime()
            group.leave()
        }
        group.wait()
        return DualUpdateStatus(app: box.app!, runtime: box.runtime!)
    }

    static func checkAllAsync(completion: @escaping @MainActor @Sendable (DualUpdateStatus) -> Void) {
        let version = RuntimeLauncher.appVersion()
        DispatchQueue.global(qos: .utility).async {
            let status = checkAll(currentVersion: version)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(status) }
            }
        }
    }

    // MARK: URL / checksum policy

    private static func envFlag(_ name: String) -> Bool {
        ["1", "true", "yes", "on"].contains(ProcessInfo.processInfo.environment[name]?.lowercased() ?? "")
    }

    /// `https://` and `file://` only; `http://` requires `DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP=1`.
    static func validateSourceURL(_ url: URL, what: String) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "https", "file":
            return
        case "http" where envFlag("DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP"):
            return
        case "http":
            throw AppUpdateError.invalidURL(
                "Refusing insecure http:// \(what) URL \(url.absoluteString) (use https://, or export DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP=1 for local testing)")
        default:
            throw AppUpdateError.invalidURL("Unsupported \(what) URL \(url.absoluteString) (use https:// or file://)")
        }
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// Parses `shasum -a 256` output, `SHA256SUMS` files, BSD `SHA256 (file) = hash` lines or a bare digest.
    /// Multi-entry files must name `fileName`; a single-entry sidecar is accepted as-is (the digest still has
    /// to match the downloaded bytes).
    static func parseChecksum(_ text: String, fileName: String?) -> String? {
        var entries: [(hash: String, name: String?)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var hash = ""
            var name: String? = nil
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ") {
                name = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                hash = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                hash = parts.first.map(String.init) ?? ""
                if parts.count > 1 {
                    var n = parts[1].trimmingCharacters(in: .whitespaces)
                    if n.hasPrefix("*") { n.removeFirst() }
                    name = n.isEmpty ? nil : n
                }
            }
            hash = hash.lowercased()
            if isSHA256Hex(hash) { entries.append((hash, name)) }
        }
        if let fileName, !fileName.isEmpty,
           let m = entries.first(where: { e in e.name.map { ($0 as NSString).lastPathComponent == fileName } ?? false }) {
            return m.hash
        }
        return entries.count == 1 ? entries[0].hash : nil
    }

    /// Fetches a small checksum file (`https://` / `file://`, `http://` only when allowed).
    static func fetchChecksum(from url: URL, fileName: String?) throws -> String {
        try validateSourceURL(url, what: "checksum")
        let data: Data
        if url.isFileURL {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size <= 1 << 20,
                  let d = try? Data(contentsOf: url) else {
                throw AppUpdateError.invalidChecksum("SHA-256 file not found or unreadable: \(url.path)")
            }
            data = d
        } else {
            switch UpdateChecker.fetch(url, accept: "application/octet-stream", maxBytes: 1 << 20) {
            case .success(let d): data = d
            case .failure(let message):
                throw AppUpdateError.invalidChecksum("Could not fetch SHA-256 file \(url.absoluteString): \(message)")
            }
        }
        guard let hash = parseChecksum(String(decoding: data, as: UTF8.self), fileName: fileName) else {
            throw AppUpdateError.invalidChecksum("No SHA-256 digest for \(fileName ?? "the download") in \(url.absoluteString)")
        }
        return hash
    }

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
