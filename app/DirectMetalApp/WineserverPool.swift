import Foundation

/// Keeps a persistent `wineserver -p<seconds>` alive per prefix so repeat launches and multi-process game
/// bootstrappers skip wineserver startup (measured M1 Pro / MetalSharp-Wine 10.5: pure Wine startup
/// 0.853 s -> 0.222 s, D3D11/D3D12 conformance suite 1.65 s -> 0.73 s).
///
/// Servers are started with raw `posix_spawn` (stdin/stdout/stderr = `/dev/null`, every other fd closed via
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`), never Foundation `Process` pipes, so the daemon can't keep a caller's pipe open.
enum WineserverPool {
    static let defaultPersistSeconds = 120

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tracked: [String: String] = [:] // prefixPath -> wineserverPath

    /// Resolves the warm-server duration: an explicit value wins (`<= 0` disables, e.g. `--no-warm-server`);
    /// otherwise `DIRECTMETAL_WARM_SERVER` (`"1"` -> 120 s, `N > 1` -> N s). `nil` => no warm server.
    static func effectiveWarmSeconds(_ explicit: Int?) -> Int? {
        if let explicit { return explicit > 0 ? explicit : nil }
        guard let raw = ProcessInfo.processInfo.environment["DIRECTMETAL_WARM_SERVER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if raw == "1" || raw == "true" || raw == "yes" || raw == "on" { return defaultPersistSeconds }
        if let n = Int(raw), n > 0 { return n }
        return nil
    }

    /// Environment for wineserver control commands. Wine sync mode (msync/esync/fsync) must match the clients'.
    private static func serverEnvironment(prefixURL: URL, base: [String: String]?) -> [String: String] {
        var env = base ?? ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        if base == nil {
            env["WINEMSYNC"] = "1" // matches RuntimeLauncher.runExecutable
        }
        if env["WINEDEBUG"] == nil {
            env["WINEDEBUG"] = "-all"
        }
        return env
    }

    /// PID of the wineserver currently serving `prefixURL` (holder of its `server-<dev>-<ino>/lock`), or `nil`.
    static func runningPID(prefixURL: URL) -> pid_t? {
        var st = stat()
        guard stat(prefixURL.path, &st) == 0 else { return nil }
        let dir = String(format: "/tmp/.wine-%u/server-%llx-%llx", getuid(), UInt64(UInt32(bitPattern: st.st_dev)), UInt64(st.st_ino))
        let fd = open(dir + "/lock", O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        guard fcntl(fd, F_GETLK, &fl) == 0, fl.l_type != Int16(F_UNLCK), fl.l_pid > 0 else { return nil }
        return fl.l_pid
    }

    /// Starts (or reuses) a persistent wineserver for `prefixURL`. Returns `true` when a server is running afterwards.
    @discardableResult
    static func warm(prefixURL: URL, wineserverBin: URL, persistSeconds: Int = 120,
                     environment: [String: String]? = nil) -> Bool {
        guard persistSeconds > 0, access(prefixURL.path, F_OK) == 0 else { return false }
        lock.lock()
        tracked[prefixURL.path] = wineserverBin.path
        lock.unlock()
        if runningPID(prefixURL: prefixURL) != nil { return true }
        // The forking parent exits as soon as the daemon holds the server lock (0 = started, 2 = already running).
        let res = RuntimeManager.spawnAndWait(
            [wineserverBin.path, "-p\(persistSeconds)"],
            environment: serverEnvironment(prefixURL: prefixURL, base: environment)
        )
        return res.status == 0 || runningPID(prefixURL: prefixURL) != nil
    }

    /// `wineserver -k` for `prefixURL` (waits until the server released its lock).
    static func stop(prefixURL: URL, wineserverBin: URL) {
        lock.lock()
        tracked.removeValue(forKey: prefixURL.path)
        lock.unlock()
        guard access(prefixURL.path, F_OK) == 0 else { return }
        RuntimeManager.spawnAndWait(
            [wineserverBin.path, "-k"],
            environment: serverEnvironment(prefixURL: prefixURL, base: nil)
        )
    }

    /// Stops every server warmed by this process (GUI quit => zero orphan wineserver daemons).
    static func stopAll() {
        lock.lock()
        let snapshot = tracked
        tracked.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
            let item = snapshot[snapshot.index(snapshot.startIndex, offsetBy: i)]
            stop(prefixURL: URL(fileURLWithPath: item.key, isDirectory: true),
                 wineserverBin: URL(fileURLWithPath: item.value))
        }
    }

    static func trackedPrefixes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tracked.keys.sorted()
    }
}
