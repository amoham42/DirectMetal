import Darwin
import Foundation

// MARK: - Runtime & dual update status types

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

// MARK: - Release checks, edition/asset resolution, URL & checksum policy

extension AppUpdater {
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

    static func envFlag(_ name: String) -> Bool {
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
}
