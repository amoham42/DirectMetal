import CryptoKit
import Darwin
import Foundation

// MARK: - Public types

struct RuntimeInstallProgress {
    enum Phase: String {
        case resolving
        case downloading
        case copying
        case verifying
        case extracting
        case codesign
        case preparingPrefix = "preparing-prefix"
        case finalizing
        case done
    }

    let phase: Phase
    let bytesReceived: Int64
    /// `-1` when unknown (e.g. chunked HTTP responses).
    let totalBytes: Int64
    /// Phase completion in `0...1`, or `-1` while indeterminate (extraction, codesign, wineboot).
    let fraction: Double
    let message: String
}

enum RuntimeInstallError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case extractFailed(String)
    case codesignFailed(String)
    case prefixInitFailed(String)
    case installFailed(String)

    var description: String {
        switch self {
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 mismatch: expected \(expected), got \(actual). The archive was discarded."
        case .invalidURL(let m), .invalidChecksum(let m), .downloadFailed(let m), .extractFailed(let m),
             .codesignFailed(let m), .prefixInitFailed(let m), .installFailed(let m):
            return m
        }
    }
}

enum RuntimeSource: String, Codable {
    case bundled
    case userInstalled = "user-installed"
    case devBuild = "dev-build"
    case missing
}

struct RuntimeInstallStatus: Codable {
    let installed: Bool
    let source: RuntimeSource
    let version: String
    let runtimeRoot: String?
    /// `nil` when not checked (or the runtime has no `MetalSharp-Wine.app` bundle to verify).
    let codesignValid: Bool?
    let archiveURL: String
    let expectedSHA256: String
    /// `nil` when not measured.
    let diskBytes: UInt64?
    let userRuntimeDir: String
}

// MARK: - RuntimeManager

/// Manages the on-demand, user-installed ARM64EC+FEX runtime used by `DirectMetal-Lite.app` (and the CLI):
/// `~/Library/Application Support/DirectMetal/Runtimes/arm64ec-<version>/`
///   wine-dist/MetalSharp-Wine.app      untouched notarized Apple Developer ID bundle (ditto-extracted)
///   bin -> wine-dist/MetalSharp-Wine.app/Contents/MacOS
///   base-prefix-dehydrated/            copied from the Lite bundle (fast path, hydrated lazily ~120 ms)
///   base-prefix/                       or a wineboot-initialized golden prefix (standalone CLI fallback)
///   directmetal-runtime.json           install metadata (archive URL, SHA-256, timestamp)
enum RuntimeManager {
    static let arm64ecVersion = "10.5"
    static let officialArchiveURL =
        "https://github.com/metalsharp/MetalSharp-Wine/releases/download/v10.5/MetalSharp-Wine-10.5-arm64.zip"
    static let officialSHA256 = "d92b19cd4e3cdd34feaa2236bd4b7310c2b7865da1c0661e1dd1ad1f627846fa"
    static let archiveSizeLabel = "1.33 GB"
    static let metadataFileName = "directmetal-runtime.json"
    static var runtimeDirName: String { "arm64ec-\(arm64ecVersion)" }

    private static let wineAppRelPath = "wine-dist/MetalSharp-Wine.app"
    private static let binLinkTarget = "wine-dist/MetalSharp-Wine.app/Contents/MacOS"

    // MARK: Locations

    /// `DIRECTMETAL_USER_RUNTIMES_DIR` overrides the root (isolated tests / custom volumes).
    static func userRuntimesRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_USER_RUNTIMES_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("DirectMetal", isDirectory: true)
            .appendingPathComponent("Runtimes", isDirectory: true)
    }

    static func userARM64ECRuntimeDir() -> URL {
        return userRuntimesRoot().appendingPathComponent(runtimeDirName, isDirectory: true)
    }

    static func defaultArchiveURLString() -> String {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_RUNTIME_ARCHIVE_URL"], !env.isEmpty {
            return env
        }
        return officialArchiveURL
    }

    static func defaultExpectedSHA256() -> String {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_RUNTIME_SHA256"], !env.isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return officialSHA256
    }

    /// Accepts `https://…`, `http://…`, `file://…` and plain (tilde-expanded) filesystem paths.
    static func parseSourceURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
            return URL(string: s)
        }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }

    // MARK: Detection

    static func isValidRuntimeRoot(_ root: URL) -> Bool {
        guard access(root.appendingPathComponent("bin/wine").path, X_OK) == 0 else { return false }
        if access(root.appendingPathComponent("\(BasePrefixHydrator.unpackedDirName)/system.reg").path, F_OK) == 0 {
            return true
        }
        let fp = "\(BasePrefixHydrator.dehydratedDirName)/\(BasePrefixHydrator.fingerprintFileName)"
        return access(root.appendingPathComponent(fp).path, F_OK) == 0
    }

    /// The valid user-installed ARM64EC runtime root, or `nil` when not installed.
    static func installedARM64ECRuntimeRoot() -> URL? {
        let dir = userARM64ECRuntimeDir()
        return isValidRuntimeRoot(dir) ? dir : nil
    }

    static func status(checkCodesign: Bool = true, measureDisk: Bool = true) -> RuntimeInstallStatus {
        let archiveURL = defaultArchiveURLString()
        let sha = defaultExpectedSHA256()
        let userDir = userARM64ECRuntimeDir().path
        guard let arm = RuntimeLauncher.resolveARM64ECRuntime() else {
            return RuntimeInstallStatus(
                installed: false, source: .missing, version: arm64ecVersion, runtimeRoot: nil,
                codesignValid: nil, archiveURL: archiveURL, expectedSHA256: sha, diskBytes: nil,
                userRuntimeDir: userDir
            )
        }
        let rootPath = arm.root.standardizedFileURL.path
        let source: RuntimeSource
        if let user = installedARM64ECRuntimeRoot(), user.standardizedFileURL.path == rootPath {
            source = .userInstalled
        } else if rootPath.hasSuffix(".app/Contents/Runtime-ARM64EC") {
            source = .bundled
        } else {
            source = .devBuild
        }
        var codesign: Bool? = nil
        if checkCodesign {
            let app = arm.root.appendingPathComponent(wineAppRelPath, isDirectory: true)
            if access(app.path, F_OK) == 0 {
                codesign = verifyCodesign(app).ok
            }
        }
        return RuntimeInstallStatus(
            installed: true, source: source, version: arm64ecVersion, runtimeRoot: rootPath,
            codesignValid: codesign, archiveURL: archiveURL, expectedSHA256: sha,
            diskBytes: measureDisk ? allocatedBytes(of: arm.root) : nil,
            userRuntimeDir: userDir
        )
    }

    // MARK: Install

    /// Downloads (or copies), SHA-256 verifies, extracts, codesign-verifies and atomically installs the
    /// notarized MetalSharp-Wine ARM64EC+FEX runtime into `userARM64ECRuntimeDir()`. Returns the runtime root.
    @discardableResult
    static func installARM64ECRuntime(
        sourceURL: URL? = nil,
        expectedSHA256: String? = nil,
        force: Bool = false,
        progress: ((RuntimeInstallProgress) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let finalDir = userARM64ECRuntimeDir()
        func report(_ phase: RuntimeInstallProgress.Phase, _ done: Int64 = 0, _ total: Int64 = -1,
                    _ fraction: Double = -1, _ message: String) {
            progress?(RuntimeInstallProgress(phase: phase, bytesReceived: done, totalBytes: total,
                                             fraction: fraction, message: message))
        }

        if !force, isValidRuntimeRoot(finalDir) {
            report(.done, 0, -1, 1, "DirectMetal runtime \(arm64ecVersion) already installed at \(finalDir.path)")
            return finalDir
        }

        // 1. Resolve source + expected digest.
        let source: URL
        if let s = sourceURL {
            source = s
        } else {
            guard let u = parseSourceURL(defaultArchiveURLString()) else {
                throw RuntimeInstallError.invalidURL("Invalid runtime archive URL: \(defaultArchiveURLString())")
            }
            source = u
        }
        let scheme = source.scheme?.lowercased() ?? ""
        guard ["file", "http", "https"].contains(scheme) else {
            throw RuntimeInstallError.invalidURL("Unsupported runtime archive URL (use https://, http:// or file://): \(source.absoluteString)")
        }
        let wantSHA = (expectedSHA256 ?? defaultExpectedSHA256())
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skipVerify: Bool
        if wantSHA == "skip" {
            // Synthetic tests only: must be opted into explicitly through the environment.
            guard ProcessInfo.processInfo.environment["DIRECTMETAL_RUNTIME_SHA256"]?.lowercased() == "skip" else {
                throw RuntimeInstallError.invalidChecksum(
                    "Refusing to skip SHA-256 verification: export DIRECTMETAL_RUNTIME_SHA256=skip explicitly (synthetic tests only)."
                )
            }
            skipVerify = true
        } else {
            guard wantSHA.count == 64, wantSHA.allSatisfy({ $0.isHexDigit }) else {
                throw RuntimeInstallError.invalidChecksum("Expected SHA-256 must be 64 hex characters, got \"\(wantSHA)\"")
            }
            skipVerify = false
        }
        report(.resolving, 0, -1, -1, "Installing DirectMetal runtime \(arm64ecVersion) from \(source.absoluteString)")

        // 2. Stage next to the final directory (same volume => atomic rename).
        let root = finalDir.deletingLastPathComponent()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        removeStaleArtifacts(in: root)
        let token = UUID().uuidString
        let stage = root.appendingPathComponent(".\(runtimeDirName).staging-\(token)", isDirectory: true)
        let archive = root.appendingPathComponent(".\(runtimeDirName).download-\(token).zip")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var installed = false
        defer {
            try? fm.removeItem(at: archive)
            if !installed { try? fm.removeItem(at: stage) }
        }

        // 3. Acquire + streaming SHA-256.
        let digest: String
        if scheme == "file" {
            digest = try acquireLocal(source, to: archive, progress: progress)
        } else {
            digest = try download(source, to: archive, progress: progress)
        }
        if skipVerify {
            report(.verifying, 0, -1, 1, "SHA-256 verification SKIPPED (DIRECTMETAL_RUNTIME_SHA256=skip): \(digest)")
        } else {
            guard digest == wantSHA else {
                throw RuntimeInstallError.checksumMismatch(expected: wantSHA, actual: digest)
            }
            report(.verifying, 0, -1, 1, "SHA-256 verified: \(digest)")
        }

        // 4. Extract with ditto (preserves Developer ID signature + cross-arch provisioning profile).
        let wineDist = stage.appendingPathComponent("wine-dist", isDirectory: true)
        try fm.createDirectory(at: wineDist, withIntermediateDirectories: false)
        report(.extracting, 0, -1, -1, "Extracting MetalSharp-Wine \(arm64ecVersion) with ditto…")
        let tExtract = DispatchTime.now().uptimeNanoseconds
        let dittoRes = spawnAndWait(["/usr/bin/ditto", "-x", "-k", archive.path, wineDist.path], captureOutput: true)
        guard dittoRes.status == 0 else {
            throw RuntimeInstallError.extractFailed("ditto -x -k failed (status \(dittoRes.status)): \(dittoRes.output)")
        }
        try? fm.removeItem(at: archive) // free ~1.3 GB before prefix preparation
        report(.extracting, 0, -1, 1, String(format: "Extracted in %.1f s",
                                             Double(DispatchTime.now().uptimeNanoseconds - tExtract) / 1e9))

        // 5. Strip quarantine + strict deep codesign verification.
        _ = spawnAndWait(["/usr/bin/xattr", "-dr", "com.apple.quarantine", wineDist.path], captureOutput: true)
        let app = stage.appendingPathComponent(wineAppRelPath, isDirectory: true)
        guard access(app.appendingPathComponent("Contents/MacOS/wine").path, X_OK) == 0 else {
            throw RuntimeInstallError.extractFailed("Archive does not contain MetalSharp-Wine.app/Contents/MacOS/wine")
        }
        report(.codesign, 0, -1, -1, "Verifying Apple Developer ID signature (codesign --verify --strict --deep)…")
        let cs = verifyCodesign(app)
        guard cs.ok else {
            throw RuntimeInstallError.codesignFailed("codesign --verify --strict --deep failed: \(cs.output)")
        }
        report(.codesign, 0, -1, 1, "Signature & provisioning profile verified")

        // 6. bin -> wine-dist/MetalSharp-Wine.app/Contents/MacOS (relative, survives relocation).
        try fm.createSymbolicLink(atPath: stage.appendingPathComponent("bin").path, withDestinationPath: binLinkTarget)

        // 7. Golden base prefix.
        try prepareBasePrefix(stage: stage, app: app, report: { phase, fraction, message in
            report(phase, 0, -1, fraction, message)
        })

        // 8. Metadata, then atomic install.
        let meta: [String: Any] = [
            "version": arm64ecVersion,
            "archive_url": source.absoluteString,
            "sha256": digest,
            "sha256_verified": !skipVerify,
            "installed_utc": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stage.appendingPathComponent(metadataFileName))
        }
        report(.finalizing, 0, -1, -1, "Installing runtime into \(finalDir.path)")

        var trash: URL? = nil
        if access(finalDir.path, F_OK) == 0 {
            if !force, isValidRuntimeRoot(finalDir) {
                // A concurrent installer won the race.
                report(.done, 0, -1, 1, "DirectMetal runtime \(arm64ecVersion) already installed at \(finalDir.path)")
                return finalDir
            }
            let t = root.appendingPathComponent(".\(runtimeDirName).trash-\(token)", isDirectory: true)
            guard rename(finalDir.path, t.path) == 0 else {
                throw RuntimeInstallError.installFailed("Cannot move aside \(finalDir.path): \(String(cString: strerror(errno)))")
            }
            trash = t
        }
        if rename(stage.path, finalDir.path) != 0 {
            let err = errno
            if let t = trash { _ = rename(t.path, finalDir.path) }
            if isValidRuntimeRoot(finalDir) && trash == nil {
                report(.done, 0, -1, 1, "DirectMetal runtime \(arm64ecVersion) already installed at \(finalDir.path)")
                return finalDir
            }
            throw RuntimeInstallError.installFailed("Failed to install runtime at \(finalDir.path): \(String(cString: strerror(err)))")
        }
        installed = true
        if let t = trash { try? fm.removeItem(at: t) }
        report(.done, 0, -1, 1, "DirectMetal runtime \(arm64ecVersion) installed at \(finalDir.path)")
        return finalDir
    }

    /// Removes the user-installed runtime (moved aside first so a half-deleted tree is never "valid").
    static func removeUserRuntime() throws {
        let fm = FileManager.default
        let dir = userARM64ECRuntimeDir()
        guard access(dir.path, F_OK) == 0 else { return }
        let trash = dir.deletingLastPathComponent()
            .appendingPathComponent(".\(runtimeDirName).trash-\(UUID().uuidString)", isDirectory: true)
        if rename(dir.path, trash.path) == 0 {
            try fm.removeItem(at: trash)
        } else {
            try fm.removeItem(at: dir)
        }
    }

    // MARK: - Acquisition

    private static let chunkSize = 8 * 1024 * 1024

    private static func hex(_ digest: SHA256.Digest) -> String {
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `file://` source: APFS clone (instant, zero extra blocks, immune to later source mutation) then a
    /// streaming hash of the clone; streaming copy + hash when cloning is impossible (cross-volume).
    private static func acquireLocal(_ src: URL, to dst: URL, progress: ((RuntimeInstallProgress) -> Void)?) throws -> String {
        let srcPath = src.path
        var st = stat()
        guard stat(srcPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw RuntimeInstallError.downloadFailed("Runtime archive not found: \(srcPath)")
        }
        let total = Int64(st.st_size)
        if clonefile(srcPath, dst.path, 0) == 0 {
            return try streamHash(from: dst.path, copyTo: nil, total: total, phase: .verifying, progress: progress)
        }
        return try streamHash(from: srcPath, copyTo: dst.path, total: total, phase: .copying, progress: progress)
    }

    private static func streamHash(from srcPath: String, copyTo dstPath: String?, total: Int64,
                                   phase: RuntimeInstallProgress.Phase,
                                   progress: ((RuntimeInstallProgress) -> Void)?) throws -> String {
        let inFD = open(srcPath, O_RDONLY)
        guard inFD >= 0 else {
            throw RuntimeInstallError.downloadFailed("open(\(srcPath)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(inFD) }
        _ = fcntl(inFD, F_RDAHEAD, 1)
        var outFD: Int32 = -1
        if let dstPath {
            outFD = open(dstPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard outFD >= 0 else {
                throw RuntimeInstallError.downloadFailed("open(\(dstPath)) failed: \(String(cString: strerror(errno)))")
            }
        }
        defer { if outFD >= 0 { close(outFD) } }

        var hasher = SHA256()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }
        var done: Int64 = 0
        var lastReport: UInt64 = 0
        let verb = dstPath == nil ? "Verifying SHA-256" : "Copying & hashing"
        while true {
            let n = read(inFD, buf, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw RuntimeInstallError.downloadFailed("read(\(srcPath)) failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buf, count: n)
            hasher.update(bufferPointer: chunk)
            if outFD >= 0 { try writeAll(outFD, chunk) }
            done += Int64(n)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 100_000_000 {
                lastReport = now
                let frac = total > 0 ? min(Double(done) / Double(total), 1) : -1
                progress?(RuntimeInstallProgress(phase: phase, bytesReceived: done, totalBytes: total, fraction: frac,
                                                 message: "\(verb)…"))
            }
        }
        progress?(RuntimeInstallProgress(phase: phase, bytesReceived: done, totalBytes: total, fraction: 1,
                                         message: "\(verb) complete"))
        return hex(hasher.finalize())
    }

    fileprivate static func writeAll(_ fd: Int32, _ chunk: UnsafeRawBufferPointer) throws {
        guard var p = chunk.baseAddress else { return }
        var left = chunk.count
        while left > 0 {
            let w = write(fd, p, left)
            if w < 0 {
                if errno == EINTR { continue }
                throw RuntimeInstallError.downloadFailed("write failed: \(String(cString: strerror(errno)))")
            }
            left -= w
            p += w
        }
    }

    /// `http(s)://` source: streaming `URLSession` data task, writing + hashing every chunk as it arrives.
    private static func download(_ url: URL, to dst: URL, progress: ((RuntimeInstallProgress) -> Void)?) throws -> String {
        let fd = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw RuntimeInstallError.downloadFailed("open(\(dst.path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let delegate = StreamingDownloadDelegate(fd: fd, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("DirectMetal/\(arm64ecVersion) (RuntimeManager)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()
        if let err = delegate.failure {
            throw RuntimeInstallError.downloadFailed("Download of \(url.absoluteString) failed: \(err)")
        }
        progress?(RuntimeInstallProgress(phase: .downloading, bytesReceived: delegate.received,
                                         totalBytes: delegate.expected, fraction: 1, message: "Download complete"))
        return hex(delegate.finalDigest())
    }

    // MARK: - Base prefix

    private static func prepareBasePrefix(
        stage: URL,
        app: URL,
        report: (RuntimeInstallProgress.Phase, Double, String) -> Void
    ) throws {
        let fm = FileManager.default
        // Fast path: Lite bundle ships the dehydrated golden prefix => BasePrefixHydrator (~120 ms), no wineboot.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(BasePrefixHydrator.dehydratedDirName, isDirectory: true),
           BasePrefixHydrator.isDehydratedBundle(bundled) {
            report(.preparingPrefix, -1, "Installing bundled dehydrated base prefix…")
            let dst = stage.appendingPathComponent(BasePrefixHydrator.dehydratedDirName, isDirectory: true)
            try PrefixManager.cloneTree(from: bundled, to: dst)
            guard (try BasePrefixHydrator.readFingerprint(runtimeRoot: stage)) != nil else {
                throw RuntimeInstallError.prefixInitFailed("Bundled base-prefix-dehydrated has no fingerprint")
            }
            report(.preparingPrefix, 1, "Dehydrated base prefix ready (hydrates on first launch)")
            return
        }

        // Fallback (standalone CLI): initialize a golden prefix with wineboot.
        let prefix = stage.appendingPathComponent(BasePrefixHydrator.unpackedDirName, isDirectory: true)
        try fm.createDirectory(at: prefix, withIntermediateDirectories: false)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        report(.preparingPrefix, -1, "Initializing ARM64EC golden base prefix (wineboot -u -r)…")
        let t0 = DispatchTime.now().uptimeNanoseconds
        let boot = spawnAndWait([macos.appendingPathComponent("wine").path, "wineboot", "-u", "-r"], environment: env)
        _ = spawnAndWait([macos.appendingPathComponent("wineserver").path, "-w"], environment: env)
        guard access(prefix.appendingPathComponent("system.reg").path, F_OK) == 0 else {
            throw RuntimeInstallError.prefixInitFailed("wineboot did not create system.reg (status \(boot.status))")
        }

        // D3D12 Placed-Resource Alignment Guard (when bundled next to the CLI / app resources).
        if let guardDLL = Bundle.main.resourceURL?.appendingPathComponent("guards/d3d12_x64.dll"),
           access(guardDLL.path, F_OK) == 0 {
            let mullionD3D12 = app.appendingPathComponent("Contents/lib/mullion/aarch64-windows/d3d12.dll")
            let sys32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
            if access(mullionD3D12.path, F_OK) == 0, access(sys32.path, F_OK) == 0 {
                let real = sys32.appendingPathComponent("d3d12_mullion.dll")
                let shim = sys32.appendingPathComponent("d3d12.dll")
                try? fm.removeItem(at: real)
                try? fm.removeItem(at: shim)
                try fm.copyItem(at: mullionD3D12, to: real)
                try fm.copyItem(at: guardDLL, to: shim)
            }
        }
        report(.preparingPrefix, 1, String(format: "Golden base prefix initialized in %.1f s",
                                           Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9))
    }

    // MARK: - Helpers

    static func verifyCodesign(_ app: URL) -> (ok: Bool, output: String) {
        let r = spawnAndWait(["/usr/bin/codesign", "--verify", "--strict", "--deep", app.path], captureOutput: true)
        return (r.status == 0, r.output)
    }

    static func allocatedBytes(of root: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Removes staging/download/trash leftovers from crashed or killed installs (> 1 h old).
    private static func removeStaleArtifacts(in root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in items where name.hasPrefix(".\(runtimeDirName).") {
            let path = root.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Raw `posix_spawn` + `waitpid` (no Foundation `Process`): only fds 0/1/2 are inherited
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so daemons (wineserver) can never pin our pipes open.
    /// `captureOutput == false` => stdin/stdout/stderr are `/dev/null`.
    /// Returns the exit status (`128 + signal` when signaled, `-1` when the spawn failed).
    @discardableResult
    static func spawnAndWait(_ argv: [String], environment: [String: String]? = nil,
                             captureOutput: Bool = false) -> (status: Int32, output: String) {
        guard let exe = argv.first else { return (-1, "empty argv") }
        var fds: [Int32] = [-1, -1]
        if captureOutput {
            guard pipe(&fds) == 0 else { return (-1, "pipe() failed: \(String(cString: strerror(errno)))") }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if captureOutput {
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var cenv: [UnsafeMutablePointer<CChar>?] = []
        if let environment {
            cenv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        }
        defer { cenv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc: Int32
        if environment != nil {
            rc = cenv.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, exe, &actions, &attr, cargs, UnsafeMutablePointer(mutating: envp.baseAddress))
            }
        } else {
            rc = posix_spawn(&pid, exe, &actions, &attr, cargs, environ)
        }
        if captureOutput { close(fds[1]) }
        guard rc == 0 else {
            if captureOutput { close(fds[0]) }
            return (-1, "posix_spawn(\(exe)) failed: \(String(cString: strerror(rc)))")
        }

        var out = Data()
        if captureOutput {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(fds[0], &buf, buf.count)
                if n > 0 {
                    if out.count < 256 * 1024 { out.append(buf, count: n) }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fds[0])
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return (-1, "waitpid failed: \(String(cString: strerror(errno)))") }
        }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = status & 0x7f
        if sig != 0 { return (128 + sig, text) }
        return ((status >> 8) & 0xff, text)
    }
}

// MARK: - Streaming download delegate

/// All callbacks run on a serial delegate queue; the installing thread only reads state after `done` fires.
private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let fd: Int32
    let progress: ((RuntimeInstallProgress) -> Void)?
    let done = DispatchSemaphore(value: 0)
    private var hasher = SHA256()
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = -1
    private(set) var failure: String?
    private var lastReport: UInt64 = 0

    init(fd: Int32, progress: ((RuntimeInstallProgress) -> Void)?) {
        self.fd = fd
        self.progress = progress
    }

    func finalDigest() -> SHA256.Digest {
        return hasher.finalize()
    }

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
                try RuntimeManager.writeAll(fd, raw)
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
            let frac = expected > 0 ? min(Double(received) / Double(expected), 1) : -1
            progress?(RuntimeInstallProgress(phase: .downloading, bytesReceived: received, totalBytes: expected,
                                             fraction: frac, message: "Downloading MetalSharp-Wine runtime…"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil {
            failure = error.localizedDescription
        }
        if failure == nil, expected > 0, received != expected {
            failure = "truncated download (\(received) of \(expected) bytes)"
        }
        done.signal()
    }
}
