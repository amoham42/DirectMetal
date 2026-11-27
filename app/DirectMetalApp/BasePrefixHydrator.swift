import Darwin
import Foundation

enum BasePrefixHydratorError: Error, CustomStringConvertible {
    case missingBundle(String)
    case invalidFingerprint(String)
    case extractFailed(String)
    case invalidManifest(String)
    case linkFailed(String)
    case installFailed(String)

    var description: String {
        switch self {
        case .missingBundle(let m), .invalidFingerprint(let m), .extractFailed(let m),
             .invalidManifest(let m), .linkFailed(let m), .installFailed(let m):
            return m
        }
    }
}

/// Rehydrates the slim release `base-prefix-dehydrated/` bundle into a full ARM64EC Wine golden prefix.
///
/// Layout produced by packaging (inside any arm64ec runtime root):
///   base-prefix-dehydrated/base-prefix-fingerprint.txt   trimmed ASCII fingerprint
///   base-prefix-dehydrated/base-prefix-delta.tar.gz      unique files (registry hives, guards, symlinks, dirs)
///   base-prefix-dehydrated/base-prefix-links.tsv         `rel_dst_in_prefix \t rel_src_in_wine_app_contents`
///
/// Hydration runs once per runtime fingerprint into
/// `~/Library/Application Support/DirectMetal/BasePrefixes/arm64ec-<fingerprint>/`.
/// Linked files are materialized with APFS `clonefile()` (zero extra data blocks), falling back to a
/// real copy only when the source lives on another volume (e.g. running straight from a mounted DMG).
enum BasePrefixHydrator {
    static let unpackedDirName = "base-prefix"
    static let dehydratedDirName = "base-prefix-dehydrated"
    static let fingerprintFileName = "base-prefix-fingerprint.txt"
    static let deltaFileName = "base-prefix-delta.tar.gz"
    static let linksFileName = "base-prefix-links.tsv"
    static let markerFileName = ".hydrated_ok"

    /// Root holding hydrated golden prefixes. `DIRECTMETAL_BASE_PREFIX_CACHE` overrides (tests / custom volumes).
    static func cacheRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_BASE_PREFIX_CACHE"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("DirectMetal", isDirectory: true)
            .appendingPathComponent("BasePrefixes", isDirectory: true)
    }

    /// True when `url` is a `base-prefix-dehydrated/` bundle directory.
    static func isDehydratedBundle(_ url: URL) -> Bool {
        return fileExists(url.appendingPathComponent(fingerprintFileName).path)
    }

    /// Default Wine binary for a runtime root (mirrors `RuntimeLauncher.resolveARM64ECRuntime`).
    static func defaultWineBin(runtimeRoot: URL) -> URL {
        let launcher = runtimeRoot.appendingPathComponent("bin/wine-launcher")
        if FileManager.default.isExecutableFile(atPath: launcher.path) { return launcher }
        return runtimeRoot.appendingPathComponent("bin/wine")
    }

    /// Reads and validates the runtime fingerprint (`nil` when the runtime has no dehydrated bundle).
    static func readFingerprint(runtimeRoot: URL) throws -> String? {
        let fpURL = runtimeRoot
            .appendingPathComponent(dehydratedDirName, isDirectory: true)
            .appendingPathComponent(fingerprintFileName)
        guard let raw = try? String(contentsOf: fpURL, encoding: .utf8) else { return nil }
        let fp = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !fp.isEmpty, fp.count <= 128, fp != ".", fp != "..",
              fp.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BasePrefixHydratorError.invalidFingerprint("Invalid base-prefix fingerprint in \(fpURL.path)")
        }
        return fp
    }

    static func hydratedDestination(fingerprint: String) -> URL {
        return cacheRoot().appendingPathComponent("arm64ec-\(fingerprint)", isDirectory: true)
    }

    /// Convenience used when only the `base-prefix-dehydrated/` directory is known (e.g. `PrefixManager`).
    static func resolveOrHydrate(dehydratedDir: URL) throws -> URL {
        let root = dehydratedDir.deletingLastPathComponent()
        return try resolveOrHydrate(runtimeRoot: root, wineBin: defaultWineBin(runtimeRoot: root)).basePrefix
    }

    static func resolveOrHydrate(runtimeRoot: URL, wineBin: URL) throws -> (basePrefix: URL, hydratedNow: Bool, hydrateMs: Double) {
        // Fast path 1: unpacked dev build / legacy bundle.
        let unpacked = runtimeRoot.appendingPathComponent(unpackedDirName, isDirectory: true)
        if fileExists(unpacked.appendingPathComponent("system.reg").path) {
            return (unpacked, false, 0)
        }

        // Fast path 2: already hydrated for this runtime fingerprint.
        guard let fingerprint = try readFingerprint(runtimeRoot: runtimeRoot) else {
            throw BasePrefixHydratorError.missingBundle(
                "No base-prefix or \(dehydratedDirName)/\(fingerprintFileName) in \(runtimeRoot.path)"
            )
        }
        let dest = hydratedDestination(fingerprint: fingerprint)
        if isHydrated(dest) {
            return (dest, false, 0)
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        let installedByUs = try hydrate(runtimeRoot: runtimeRoot, wineBin: wineBin, fingerprint: fingerprint, dest: dest)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return (dest, installedByUs, ms)
    }

    // MARK: - Hydration

    private static func fileExists(_ path: String) -> Bool {
        return access(path, F_OK) == 0
    }

    private static func isHydrated(_ dir: URL) -> Bool {
        return fileExists(dir.appendingPathComponent("system.reg").path) &&
               fileExists(dir.appendingPathComponent(markerFileName).path)
    }

    /// Returns `true` when this process installed `dest`, `false` when a concurrent launch won the race.
    private static func hydrate(runtimeRoot: URL, wineBin: URL, fingerprint: String, dest: URL) throws -> Bool {
        let fm = FileManager.default
        let bundle = runtimeRoot.appendingPathComponent(dehydratedDirName, isDirectory: true)
        let deltaURL = bundle.appendingPathComponent(deltaFileName)
        let linksURL = bundle.appendingPathComponent(linksFileName)
        let wineAppContents = wineBin.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let root = dest.deletingLastPathComponent()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        removeStaleStagingDirs(in: root, fingerprint: fingerprint)

        let staging = root.appendingPathComponent(
            "arm64ec-\(fingerprint).staging-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var installed = false
        defer {
            if !installed { try? fm.removeItem(at: staging) }
        }

        // 1. Unique files (registry hives, D3D12 guard, symlinks, empty dirs).
        var tPhase = DispatchTime.now().uptimeNanoseconds
        func lap() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            defer { tPhase = now }
            return Double(now - tPhase) / 1_000_000.0
        }
        if fileExists(deltaURL.path) {
            try extractTarGz(deltaURL, into: staging)
        }
        let tarMs = lap()

        // 2. Clone every runtime-identical DLL/EXE from the Wine app bundle.
        let stats: (cloned: Int, copied: Int)
        if fileExists(linksURL.path) {
            let links = try parseLinks(linksURL)
            stats = try materialize(links: links, wineAppContents: wineAppContents, staging: staging)
        } else {
            stats = (0, 0)
        }
        let linkMs = lap()

        guard fileExists(staging.appendingPathComponent("system.reg").path) else {
            throw BasePrefixHydratorError.invalidManifest(
                "Hydrated base prefix is missing system.reg (bundle: \(bundle.path))"
            )
        }

        // 3. Completion marker, then atomic install.
        let marker = """
        fingerprint=\(fingerprint)
        hydrated_utc=\(ISO8601DateFormatter().string(from: Date()))
        cloned=\(stats.cloned)
        copied=\(stats.copied)
        tar_ms=\(String(format: "%.1f", tarMs))
        link_ms=\(String(format: "%.1f", linkMs))
        wine_contents=\(wineAppContents.path)

        """
        try marker.write(to: staging.appendingPathComponent(markerFileName), atomically: false, encoding: .utf8)

        if rename(staging.path, dest.path) == 0 {
            installed = true
            return true
        }
        let renameErr = errno
        // Concurrent launch already installed a complete prefix: discard ours.
        if isHydrated(dest) {
            return false
        }
        // Incomplete leftover at dest (e.g. pre-marker crash or manual tampering): move aside and retry once.
        if renameErr == ENOTEMPTY || renameErr == EEXIST {
            let trash = root.appendingPathComponent(
                "arm64ec-\(fingerprint).staging-stale-\(UUID().uuidString)", isDirectory: true
            )
            if rename(dest.path, trash.path) == 0 {
                try? fm.removeItem(at: trash)
            }
            if rename(staging.path, dest.path) == 0 {
                installed = true
                return true
            }
            if isHydrated(dest) { return false }
        }
        throw BasePrefixHydratorError.installFailed(
            "Failed to install hydrated base prefix at \(dest.path): \(String(cString: strerror(renameErr)))"
        )
    }

    /// Extracts with `/usr/bin/tar` via raw `posix_spawn` + `waitpid`: Foundation `Process.waitUntilExit()`
    /// adds ~65 ms of run-loop exit-detection latency on macOS 27 (measured 66 ms vs 1.3 ms for /usr/bin/true).
    private static func extractTarGz(_ archive: URL, into dir: URL) throws {
        let argv = ["/usr/bin/tar", "-xzf", archive.path, "-C", dir.path]
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw BasePrefixHydratorError.extractFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, nil, cargs, environ)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw BasePrefixHydratorError.extractFailed("posix_spawn(/usr/bin/tar) failed: \(String(cString: strerror(rc)))")
        }

        var errData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fds[0], &buf, buf.count)
            if n > 0 {
                if errData.count < 64 * 1024 { errData.append(buf, count: n) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fds[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR {
                throw BasePrefixHydratorError.extractFailed("waitpid(tar) failed: \(String(cString: strerror(errno)))")
            }
        }
        // WIFEXITED && WEXITSTATUS == 0
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BasePrefixHydratorError.extractFailed(
                "tar -xzf \(archive.path) failed (wait status \(status)): \(msg)"
            )
        }
    }

    private static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/") else { return false }
        return !p.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func parseLinks(_ url: URL) throws -> [(dst: String, src: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw BasePrefixHydratorError.invalidManifest("Unreadable links manifest \(url.path)")
        }
        var out: [(dst: String, src: String)] = []
        out.reserveCapacity(2048)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let tab = line.firstIndex(of: "\t") else {
                throw BasePrefixHydratorError.invalidManifest("Malformed links line (no TAB): \(line)")
            }
            let dst = String(line[line.startIndex..<tab])
            let src = String(line[line.index(after: tab)...])
            guard isSafeRelativePath(dst), !src.isEmpty, !src.hasPrefix("/") else {
                throw BasePrefixHydratorError.invalidManifest("Unsafe links entry: \(line)")
            }
            out.append((dst, src))
        }
        return out
    }

    private static func materialize(
        links: [(dst: String, src: String)],
        wineAppContents: URL,
        staging: URL
    ) throws -> (cloned: Int, copied: Int) {
        guard !links.isEmpty else { return (0, 0) }
        let stagingPath = staging.path
        let contentsPath = wineAppContents.path

        // Pre-create each unique parent directory exactly once (serial: cheap, avoids mkdir races).
        var parents = Set<String>()
        for l in links {
            if let slash = l.dst.lastIndex(of: "/") {
                parents.insert(String(l.dst[l.dst.startIndex..<slash]))
            }
        }
        let fm = FileManager.default
        for p in parents.sorted() {
            let full = stagingPath + "/" + p
            if mkdir(full, 0o755) == 0 || errno == EEXIST { continue }
            try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
        }

        let lock = NSLock()
        var cloned = 0
        var copied = 0
        var firstError: String?

        // Strided work split: APFS serializes namespace updates per directory, so interleaving entries
        // (system32/syswow64/...) across workers keeps every core busy instead of convoying on one dir lock.
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let workers = min(links.count, cores * 2)

        links.withUnsafeBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var localCloned = 0
                var localCopied = 0
                var localError: String?
                for i in stride(from: worker, to: buf.count, by: workers) {
                    let srcPath = contentsPath + "/" + buf[i].src
                    let dstPath = stagingPath + "/" + buf[i].dst
                    if clonefile(srcPath, dstPath, 0) == 0 {
                        localCloned += 1
                        continue
                    }
                    let err = errno
                    switch err {
                    case EEXIST:
                        // Delta archive already provides this file (e.g. d3d12.dll guard): delta wins.
                        continue
                    case EXDEV, ENOTSUP:
                        // Cross-volume (mounted DMG) or non-APFS destination: real copy.
                        do {
                            try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
                            localCopied += 1
                        } catch {
                            if localError == nil { localError = "copy \(srcPath) -> \(dstPath): \(error)" }
                        }
                    default:
                        if localError == nil {
                            localError = "clonefile \(srcPath) -> \(dstPath): \(String(cString: strerror(err)))"
                        }
                    }
                }
                lock.lock()
                cloned += localCloned
                copied += localCopied
                if firstError == nil, let e = localError { firstError = e }
                lock.unlock()
            }
        }

        if let e = firstError {
            throw BasePrefixHydratorError.linkFailed("Base-prefix hydration failed: \(e)")
        }
        return (cloned, copied)
    }

    /// Removes staging dirs for this fingerprint left behind by crashed/killed launches (> 10 min old).
    private static func removeStaleStagingDirs(in root: URL, fingerprint: String) {
        let fm = FileManager.default
        let prefix = "arm64ec-\(fingerprint).staging-"
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for name in items where name.hasPrefix(prefix) {
            let path = root.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
