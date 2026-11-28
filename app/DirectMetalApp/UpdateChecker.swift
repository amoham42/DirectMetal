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

// MARK: - GitHub Releases update checker

struct UpdateCheckResult: Codable, Equatable {
    var currentVersion: String
    var latestVersion: String?
    var updateAvailable: Bool
    var releaseURL: String?
    var publishedAt: String?
    var error: String?
    var checkedURL: String
    var disabled: Bool
    /// Edition of the running bundle (`lite` / `offline`) used to pick the release asset.
    var edition: String? = nil
    /// Release `.dmg` matching `edition` (e.g. `DirectMetal-Lite-macOS-arm64.dmg`) and its `.sha256` sidecar.
    var assetName: String? = nil
    var dmgURL: String? = nil
    var sha256URL: String? = nil
    var assetSize: Int64? = nil
}

/// Non-blocking GitHub Releases update check (`DIRECTMETAL_UPDATE_URL` overrides the endpoint;
/// `DIRECTMETAL_DISABLE_UPDATE_CHECK=1` turns it off). Accepts `https://` and `file://` endpoints only.
/// Installing a found update is `AppUpdater.applyAppUpdate` (DMG) / `AppUpdater.updateRuntime` (runtime).
enum UpdateChecker {
    static let defaultURL = "https://api.github.com/repos/amoham42/DirectMetal/releases/latest"
    static let timeout: TimeInterval = 5

    static var endpoint: String {
        let env = ProcessInfo.processInfo.environment["DIRECTMETAL_UPDATE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (env?.isEmpty == false) ? env! : defaultURL
    }

    static var isDisabled: Bool {
        let v = ProcessInfo.processInfo.environment["DIRECTMETAL_DISABLE_UPDATE_CHECK"]?.lowercased() ?? ""
        return ["1", "true", "yes", "on"].contains(v)
    }

    /// Runs the check on a background queue and calls `completion` on the main queue.
    static func checkAsync(currentVersion: String = RuntimeLauncher.appVersion(),
                           completion: @escaping @MainActor @Sendable (UpdateCheckResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = check(currentVersion: currentVersion)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Synchronous check (CLI / background threads only; never call on the GUI main thread).
    static func check(currentVersion: String = RuntimeLauncher.appVersion()) -> UpdateCheckResult {
        let urlString = endpoint
        var result = UpdateCheckResult(currentVersion: currentVersion, latestVersion: nil, updateAvailable: false,
                                       releaseURL: nil, publishedAt: nil, error: nil, checkedURL: urlString, disabled: false)
        if isDisabled {
            result.disabled = true
            result.error = "update check disabled (DIRECTMETAL_DISABLE_UPDATE_CHECK=1)"
            return result
        }
        let lookup = latestRelease(endpoint: urlString, productName: "DirectMetal")
        guard let rel = lookup.release, let tag = rel["tag_name"] as? String else {
            result.error = lookup.error ?? "no release tag found at \(urlString)"
            return result
        }
        result.latestVersion = normalizedVersion(tag)
        result.releaseURL = rel["html_url"] as? String
        result.publishedAt = rel["published_at"] as? String
        result.updateAvailable = compareVersions(tag, currentVersion) == .orderedDescending

        let edition = AppUpdater.runningEdition()
        result.edition = edition.rawValue
        if let asset = AppUpdater.resolveAppAsset(in: rel, edition: edition) {
            result.assetName = asset.name
            result.dmgURL = asset.dmgURL
            result.sha256URL = asset.sha256URL
            result.assetSize = asset.size
        }
        return result
    }

    /// Highest semantic-version, non-draft, non-prerelease release at a GitHub Releases endpoint (`/releases/latest`
    /// or a release list). Shared by the DirectMetal app and the MetalSharp-Wine runtime checks.
    static func latestRelease(endpoint urlString: String, productName: String) -> (release: [String: Any]?, error: String?) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["https", "file"].contains(scheme) else {
            return (nil, "refusing update URL \(urlString) (only https:// and file:// are allowed)")
        }

        var json: Any
        switch fetchJSON(url) {
        case .success(let obj): json = obj
        case .failure(let err): return (nil, err.description)
        }

        // `/releases/latest` may point at a non-app tag (e.g. `conformance-bins-v0.2`): fall back to the
        // release list and pick the highest semantic version.
        if let obj = json as? [String: Any], let tag = obj["tag_name"] as? String, !isVersionTag(tag),
           urlString.hasSuffix("/releases/latest"),
           let listURL = URL(string: String(urlString.dropLast("/latest".count)) + "?per_page=30"),
           case .success(let list) = fetchJSON(listURL), list is [[String: Any]] {
            json = list
        }

        let candidates: [[String: Any]]
        if let obj = json as? [String: Any] {
            guard obj["tag_name"] != nil else {
                let message = obj["message"] as? String
                return (nil, message.map { "GitHub: \($0)" } ?? "no release tag found at \(urlString)")
            }
            candidates = [obj]
        } else if let list = json as? [[String: Any]] {
            candidates = list.filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }
        } else {
            return (nil, "unexpected JSON from \(urlString)")
        }
        let versioned = candidates.filter { isVersionTag(($0["tag_name"] as? String) ?? "") }
        guard let rel = versioned.max(by: {
            compareVersions(($0["tag_name"] as? String) ?? "", ($1["tag_name"] as? String) ?? "") == .orderedAscending
        }) else {
            let seen = candidates.compactMap { $0["tag_name"] as? String }.prefix(3).joined(separator: ", ")
            return (nil, "no versioned \(productName) release published yet" + (seen.isEmpty ? "" : " (found tags: \(seen))"))
        }
        return (rel, nil)
    }

    /// `v1.2.0`, `1.2`, `v1.0.0-beta.1` => true; `conformance-bins-v0.2` => false.
    static func isVersionTag(_ tag: String) -> Bool {
        tag.range(of: #"^[vV]?\d+(\.\d+){0,3}([-+][0-9A-Za-z.\-+]*)?$"#, options: .regularExpression) != nil
    }

    private static func fetchJSON(_ url: URL) -> Result<Any, FetchError> {
        switch fetch(url) {
        case .failure(let message): return .failure(FetchError(message))
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(FetchError("invalid JSON from \(url.absoluteString)"))
            }
            return .success(obj)
        }
    }

    private struct FetchError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    enum FetchResult {
        case success(Data)
        case failure(String)
    }

    private final class FetchBox: @unchecked Sendable {
        var result: FetchResult = .failure("update check timed out after 5 s")
    }

    /// Small bounded fetch (`file://` or `http(s)://`, `timeout` seconds, at most `maxBytes`). Callers apply
    /// their own URL scheme policy first.
    static func fetch(_ url: URL, accept: String = "application/vnd.github+json", maxBytes: Int = 4 << 20) -> FetchResult {
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url), d.count <= maxBytes else {
                return .failure("could not read \(url.path)")
            }
            return .success(d)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("DirectMetal/\(RuntimeLauncher.appVersion())", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let box = FetchBox()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            if let error {
                box.result = .failure("network error: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.result = .failure("HTTP \(http.statusCode) from \(url.absoluteString)")
            } else if let data, !data.isEmpty, data.count <= maxBytes {
                box.result = .success(data)
            } else {
                box.result = .failure("empty response from \(url.absoluteString)")
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            return .failure("update check timed out after \(Int(timeout)) s")
        }
        return box.result
    }

    /// "v1.2.0" -> "1.2.0"
    static func normalizedVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        return s
    }

    /// Semantic-version comparison: numeric core (missing parts == 0), then a pre-release sorts before its release.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ raw: String) -> (core: [Int], pre: String?) {
            let s = normalizedVersion(raw).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
            let core = (parts.first ?? "").split(separator: ".").map { comp -> Int in
                Int(comp.prefix(while: { $0.isNumber })) ?? 0
            }
            return (core, parts.count > 1 ? parts[1] : nil)
        }
        let (ca, pa) = split(a)
        let (cb, pb) = split(b)
        for i in 0..<max(3, max(ca.count, cb.count)) {
            let x = i < ca.count ? ca[i] : 0
            let y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?):
            let r = x.compare(y, options: .numeric)
            return r
        }
    }
}
