import Darwin
import Foundation

// MARK: - Minimal Test Harness (zero external dependencies)

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    var description: String { "\(message) (\(file):\(line))" }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure(message: message, file: file, line: line)
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if actual != expected {
        let prefix = message.isEmpty ? "" : "\(message): "
        throw TestFailure(message: "\(prefix)expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func expectNil<T>(
    _ value: T?,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if let value {
        let prefix = message.isEmpty ? "" : "\(message): "
        throw TestFailure(message: "\(prefix)expected nil, got \(value)", file: file, line: line)
    }
}

@discardableResult
private func expectNotNil<T>(
    _ value: T?,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) throws -> T {
    guard let value else {
        let prefix = message.isEmpty ? "" : "\(message): "
        throw TestFailure(message: "\(prefix)expected non-nil value", file: file, line: line)
    }
    return value
}

private func expectThrows<T>(
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ body: () throws -> T,
    verify: ((Error) -> Bool)? = nil
) throws {
    do {
        _ = try body()
    } catch {
        if let verify, !verify(error) {
            throw TestFailure(message: "\(message): threw unexpected error \(error)", file: file, line: line)
        }
        return
    }
    throw TestFailure(message: "\(message): expected error to be thrown", file: file, line: line)
}

// MARK: - Synthetic PE & Fuzzing Helpers

private extension Data {
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

private func makeSyntheticPE(
    is64Bit: Bool,
    timeDateStamp: UInt32 = 0x6543_2100,
    sizeOfImage: UInt32 = 0x0010_0000,
    importedDLLs: [String] = [],
    extraPadding: Int = 0
) -> Data {
    let peOffset = 0x40
    let coffOffset = peOffset + 4
    let optOffset = coffOffset + 20
    let optSize: UInt16 = is64Bit ? 240 : 224
    let dataDirBase = optOffset + (is64Bit ? 112 : 96)
    let numRvaOffset = optOffset + (is64Bit ? 108 : 92)
    let secBase = optOffset + Int(optSize)
    let rawSectionOffset = 0x200
    let sectionVA: UInt32 = 0x2000
    let sectionRawSize = importedDLLs.isEmpty ? 0 : 0x400

    let totalSize = max(rawSectionOffset + sectionRawSize, 0x200) + max(extraPadding, 0)
    var data = Data(repeating: 0, count: totalSize)

    // DOS header ("MZ" + e_lfanew)
    data.writeUInt16LE(0x5A4D, at: 0x00)
    data.writeUInt32LE(UInt32(peOffset), at: 0x3C)

    // PE\0\0 signature
    data.writeUInt32LE(0x0000_4550, at: peOffset)

    // COFF header
    data.writeUInt16LE(is64Bit ? 0x8664 : 0x014C, at: coffOffset + 0)
    data.writeUInt16LE(importedDLLs.isEmpty ? 0 : 1, at: coffOffset + 2)
    data.writeUInt32LE(timeDateStamp, at: coffOffset + 4)
    data.writeUInt16LE(optSize, at: coffOffset + 16)

    // Optional header
    data.writeUInt16LE(is64Bit ? 0x020B : 0x010B, at: optOffset + 0)
    data.writeUInt32LE(sizeOfImage, at: optOffset + 56)
    data.writeUInt32LE(16, at: numRvaOffset)

    if !importedDLLs.isEmpty {
        // DataDirectory[1] = Import Table
        data.writeUInt32LE(sectionVA, at: dataDirBase + 1 * 8)
        data.writeUInt32LE(UInt32((importedDLLs.count + 1) * 20), at: dataDirBase + 1 * 8 + 4)

        // Section 0 (.idata)
        data.writeUInt32LE(UInt32(sectionRawSize), at: secBase + 8)
        data.writeUInt32LE(sectionVA, at: secBase + 12)
        data.writeUInt32LE(UInt32(sectionRawSize), at: secBase + 16)
        data.writeUInt32LE(UInt32(rawSectionOffset), at: secBase + 20)

        var strRelOffset = (importedDLLs.count + 1) * 20
        for (i, dll) in importedDLLs.enumerated() {
            let descOff = rawSectionOffset + i * 20
            data.writeUInt32LE(1, at: descOff + 0) // OriginalFirstThunk (non-zero)
            data.writeUInt32LE(sectionVA + UInt32(strRelOffset), at: descOff + 12) // Name RVA
            data.writeUInt32LE(1, at: descOff + 16) // FirstThunk (non-zero)

            let bytes = Array(dll.utf8)
            for (j, b) in bytes.enumerated() {
                data[rawSectionOffset + strRelOffset + j] = b
            }
            data[rawSectionOffset + strRelOffset + bytes.count] = 0
            strRelOffset += bytes.count + 1
        }
    }

    return data
}

private struct Xorshift64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }

    mutating func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var i = 0
        while i < count {
            var v = next()
            for _ in 0..<8 where i < count {
                bytes[i] = UInt8(truncatingIfNeeded: v)
                v >>= 8
                i += 1
            }
        }
        return Data(bytes)
    }
}

private func setEnv(_ key: String, _ value: String?) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}

// MARK: - Test Suite Entrypoint

@main
struct DirectMetalTests {
    static func main() {
        exit(runSuite())
    }

    private static func runSuite() -> Int32 {
        let suiteStart = DispatchTime.now().uptimeNanoseconds
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: "/tmp/dm_swift_tests_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            fputs("[FAIL] test setup: could not create temp root \(tempRoot.path): \(error)\n", stderr)
            return 1
        }
        defer { try? fm.removeItem(at: tempRoot) }

        // Isolate all DirectMetal storage paths BEFORE any lazy singleton initializes.
        let tempPECache = tempRoot.appendingPathComponent("pe_inspect_cache.json")
        let tempControllerProfiles = tempRoot.appendingPathComponent("controller_profiles.json")
        let tempLibraryDir = tempRoot.appendingPathComponent("library", isDirectory: true)
        let tempPrefixesDir = tempRoot.appendingPathComponent("prefixes", isDirectory: true)
        let tempBasePrefixCache = tempRoot.appendingPathComponent("base_prefixes", isDirectory: true)
        let tempHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        try? fm.createDirectory(at: tempHome, withIntermediateDirectories: true)

        setEnv("DIRECTMETAL_PE_CACHE_PATH", tempPECache.path)
        setEnv("DIRECTMETAL_DISABLE_PE_CACHE", nil)
        setEnv("DIRECTMETAL_CONTROLLER_PROFILES", tempControllerProfiles.path)
        setEnv("DIRECTMETAL_LIBRARY_DIR", tempLibraryDir.path)
        setEnv("DIRECTMETAL_PREFIX_ROOT", tempPrefixesDir.path)
        setEnv("DIRECTMETAL_BASE_PREFIX_CACHE", tempBasePrefixCache.path)
        setEnv("DIRECTMETAL_GAME_PROFILES", nil)
        setEnv("DIRECTMETAL_DISABLE_UPDATE_CHECK", nil)
        setEnv("DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP", nil)
        setEnv("DIRECTMETAL_UPDATE_EDITION", nil)
        setEnv("DIRECTMETAL_SCAN_DIR", nil)
        setEnv("HOME", tempHome.path)

        let tests: [(String, () throws -> Void)] = [
            ("PEInspector: rejects missing, empty, non-MZ, and truncated PE files", {
                try testPEInspectorRejectsInvalidFiles(tempRoot: tempRoot)
            }),
            ("PEInspector: parses synthetic valid PE32+ (64-bit) header and imports", {
                try testPEInspectorPE32Plus(tempRoot: tempRoot)
            }),
            ("PEInspector: parses synthetic valid PE32 (32-bit) header", {
                try testPEInspectorPE32(tempRoot: tempRoot)
            }),
            ("PEInspector: disk cache hit and mtime/size/neighborhood invalidation", {
                try testPEInspectorDiskCacheAndInvalidation(tempRoot: tempRoot, cacheFile: tempPECache)
            }),
            ("GameLibraryManager: canonicalPath, stableID, deriveTitle, defaultPrefixName", {
                try testGameLibraryPathAndTitleHelpers(tempRoot: tempRoot)
            }),
            ("GameLibraryManager: splitArguments quoting and escaping edge cases", {
                try testGameLibrarySplitArguments()
            }),
            ("GameLibraryManager: tolerant GameLibraryEntry JSON decoding", {
                try testGameLibraryEntryTolerantDecoding()
            }),
            ("GameProfileRegistry: loads 50+ profiles, matches titles, rejects ambiguous remakes", {
                try testGameProfileRegistry(tempRoot: tempRoot)
            }),
            ("GameLibraryManager: GOG Galaxy and Epic Games Store scanning in temp prefix", {
                try testGOGAndEpicScanning(tempRoot: tempRoot)
            }),
            ("ControllerMappingManager: all 5 presets and deadzone clamping", {
                try testControllerPresetsAndDeadzones()
            }),
            ("ControllerMappingManager: inheritance, SDL_GAMECONTROLLERCONFIG, stock empty env, reset", {
                try testControllerPersistenceAndSDLConfig(profilesFile: tempControllerProfiles)
            }),
            ("UpdateChecker: semantic version comparison and tag filtering", {
                try testUpdateCheckerSemver()
            }),
            ("UpdateChecker & AppUpdater: file:// fixtures, prerelease/tag skipping, HTTP refusal", {
                try testUpdateCheckerFixturesAndHTTPPolicy(tempRoot: tempRoot)
            }),
            ("AppUpdater: .sha256 sidecar and SHA256SUMS parsing", {
                try testAppUpdaterChecksumParsing(tempRoot: tempRoot)
            }),
            ("GameArtworkManager: fuzz safety on 70+ malformed/truncated/random PE & ICO buffers", {
                try testGameArtworkManagerFuzzSafety(tempRoot: tempRoot)
            }),
            ("BasePrefixHydrator: valid ASCII fingerprints accepted, path traversal & invalid rejected", {
                try testBasePrefixHydratorFingerprints(tempRoot: tempRoot, cacheRoot: tempBasePrefixCache)
            }),
            ("RuntimeLauncher: resolveBundledResources finds mullion.conf and appVersion returns semver", {
                try testRuntimeLauncherResourcesAndVersion()
            }),
            ("PEInspector & LauncherStyle: detects Vulkan and OpenGL imports and renders API badges", {
                try testPEInspectorVulkanAndOpenGL(tempRoot: tempRoot)
            }),
            ("ShaderCacheManager: listLocalCaches, pruneStaleCaches & parallel SHA-256 export/import", {
                try testShaderCacheListPruneAndParallelRoundTrip(tempRoot: tempRoot)
            }),
            ("GameLibraryManager & LauncherStyle: playtime tracking, formatting & Most Played sort", {
                try testPlaytimeTrackingAndSorting(tempRoot: tempRoot)
            }),
            ("PrefixManager: prefixStats computes disk usage and metadata", {
                try testPrefixManagerStats(tempRoot: tempRoot)
            }),
            ("SteamLibraryLocator: stat-cached manifestIndex returns O(1) hits and invalidates on change", {
                try testSteamManifestIndexCaching(tempRoot: tempRoot)
            }),
            ("DirectMetalSandbox: Seatbelt profile rendering, SBPL escaping & Z: output dir inference", {
                try testSandboxProfileRendering(tempRoot: tempRoot)
            }),
            ("DirectMetalAttestation: ECDSA P-256 sign/verify round-trip, nonce & tamper rejection", {
                try testAttestationSignVerifyAndTamperRejection()
            }),
            ("DisplayCapabilities & LibraryFilter: Retina/ProMotion/HDR formatting, filters & home redaction", {
                try testDisplayCapabilitiesAndLibraryFilters()
            }),
            ("DirectMetalBenchmark: built-in UMA, APFS CoW, SHA-256 & PE microbenchmarks run cleanly", {
                try testBuiltInBenchmarkScorecard()
            }),
            ("GameLibraryManager: portable library + controller backup export/import round-trip", {
                try testLibraryBackupExportAndImport(tempRoot: tempRoot)
            }),
            ("RuntimeLauncher & GameLibraryEntry: FPS cap clamping, env/config & user override precedence", {
                try testFPSCapEnvironmentAndClamping()
            }),
            ("GameLibraryManager & RuntimeLauncher: customEnv parsing, isolation blocklist & WINEDLLOVERRIDES merge", {
                try testCustomEnvParsingAndMerging()
            }),
        ]

        var passed = 0
        var failed = 0
        for (name, body) in tests {
            do {
                try body()
                passed += 1
                print("[PASS] \(name)")
            } catch {
                failed += 1
                print("[FAIL] \(name) -- \(error)")
            }
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - suiteStart) / 1_000_000.0
        print(String(format: "\nDirectMetal Swift Unit Tests: %d passed, %d failed (%.1f ms)", passed, failed, elapsedMs))
        return failed == 0 ? 0 : 1
    }

    // MARK: - 1. PEInspector Tests

    private static func testPEInspectorRejectsInvalidFiles(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("pe_invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Missing file
        let missing = dir.appendingPathComponent("does_not_exist.exe")
        try expectThrows("missing file") {
            try PEInspector.inspect(exePath: missing.path)
        } verify: { err in
            if case PEInspectError.unreadableFile = err { return true }
            return false
        }

        // Empty file
        let empty = dir.appendingPathComponent("empty.exe")
        try Data().write(to: empty)
        try expectThrows("empty file") {
            try PEInspector.inspect(exePath: empty.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }

        // Non-MZ file (ELF header)
        let nonMZ = dir.appendingPathComponent("non_mz.exe")
        try Data([0x7F, 0x45, 0x4C, 0x46] + [UInt8](repeating: 0, count: 124)).write(to: nonMZ)
        try expectThrows("non-MZ file") {
            try PEInspector.inspect(exePath: nonMZ.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }

        // Truncated DOS header ("MZ" only)
        let truncDOS = dir.appendingPathComponent("trunc_dos.exe")
        try Data([0x4D, 0x5A]).write(to: truncDOS)
        try expectThrows("truncated DOS header") {
            try PEInspector.inspect(exePath: truncDOS.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }

        // Valid MZ + e_lfanew pointing to invalid PE signature
        var badPESigData = Data(repeating: 0, count: 128)
        badPESigData.writeUInt16LE(0x5A4D, at: 0)
        badPESigData.writeUInt32LE(0x40, at: 0x3C)
        badPESigData.writeUInt32LE(0x5858_5858, at: 0x40)
        let badPESig = dir.appendingPathComponent("bad_pe_sig.exe")
        try badPESigData.write(to: badPESig)
        try expectThrows("bad PE signature") {
            try PEInspector.inspect(exePath: badPESig.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }

        // Truncated COFF header (ends right after PE\0\0)
        var truncCOFFData = Data(repeating: 0, count: 0x48)
        truncCOFFData.writeUInt16LE(0x5A4D, at: 0)
        truncCOFFData.writeUInt32LE(0x40, at: 0x3C)
        truncCOFFData.writeUInt32LE(0x0000_4550, at: 0x40)
        let truncCOFF = dir.appendingPathComponent("trunc_coff.exe")
        try truncCOFFData.write(to: truncCOFF)
        try expectThrows("truncated COFF header") {
            try PEInspector.inspect(exePath: truncCOFF.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }

        // Unknown optional header magic
        var badMagicData = makeSyntheticPE(is64Bit: true)
        badMagicData.writeUInt16LE(0x9999, at: 0x58)
        let badMagic = dir.appendingPathComponent("bad_magic.exe")
        try badMagicData.write(to: badMagic)
        try expectThrows("unknown optional magic") {
            try PEInspector.inspect(exePath: badMagic.path)
        } verify: { err in
            if case PEInspectError.invalidHeader = err { return true }
            return false
        }
    }

    private static func testPEInspectorPE32Plus(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("pe64", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("Game64.exe")
        let peBytes = makeSyntheticPE(
            is64Bit: true,
            timeDateStamp: 0x6611_2233,
            sizeOfImage: 0x0024_0000,
            importedDLLs: ["d3d12.dll", "dxgi.dll", "KERNEL32.dll"]
        )
        try peBytes.write(to: exe)

        let p1 = try PEInspector.inspect(exePath: exe.path)
        let p2 = try PEInspector.inspect(exePath: exe.path)

        try expectEqual(p1.is64Bit, true, "PE32+ is64Bit")
        try expectEqual(p1.architecture, "x86_64", "PE32+ architecture")
        try expectEqual(p1.fileName, "Game64.exe", "PE32+ fileName")
        try expectEqual(p1.timeDateStamp, 0x6611_2233, "PE32+ timeDateStamp")
        try expectEqual(p1.sizeOfImage, 0x0024_0000, "PE32+ sizeOfImage")
        try expect(!p1.buildHash.isEmpty, "buildHash should not be empty")
        try expect(p1.buildHash.hasSuffix("_\(0x6611_2233)_\(0x0024_0000)"), "buildHash format mismatch: \(p1.buildHash)")
        try expectEqual(p1.buildHash, p2.buildHash, "buildHash must be deterministic")
        try expect(p1.detectedAPIs.contains("D3D12"), "should detect D3D12 API")
        try expect(p1.detectedAPIs.contains("DXGI"), "should detect DXGI API")
        try expectEqual(p1.importedDLLs.count, 3, "imported DLL count")
    }

    private static func testPEInspectorPE32(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("pe32", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("Legacy32.exe")
        let peBytes = makeSyntheticPE(
            is64Bit: false,
            timeDateStamp: 0x4D55_6677,
            sizeOfImage: 0x0008_0000,
            importedDLLs: ["d3d9.dll"]
        )
        try peBytes.write(to: exe)

        let profile = try PEInspector.inspect(exePath: exe.path)
        try expectEqual(profile.is64Bit, false, "PE32 is64Bit")
        try expectEqual(profile.architecture, "x86", "PE32 architecture")
        try expectEqual(profile.timeDateStamp, 0x4D55_6677, "PE32 timeDateStamp")
        try expectEqual(profile.sizeOfImage, 0x0008_0000, "PE32 sizeOfImage")
        try expect(profile.detectedAPIs.contains("D3D9"), "should detect D3D9 API")
        try expect(!profile.buildHash.isEmpty, "PE32 buildHash non-empty")
    }

    private static func testPEInspectorDiskCacheAndInvalidation(tempRoot: URL, cacheFile: URL) throws {
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent("pe_cache_test", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("CachedGame.exe")

        // 1. Initial inspect writes the cache to disk
        let bytesV1 = makeSyntheticPE(is64Bit: true, timeDateStamp: 0x1111_1111, sizeOfImage: 0x0010_0000)
        try bytesV1.write(to: exe)
        let p1 = try PEInspector.inspect(exePath: exe.path)
        try expectEqual(p1.timeDateStamp, 0x1111_1111)
        try expect(fm.fileExists(atPath: cacheFile.path), "PE cache file should be written to \(cacheFile.path)")

        let cacheText = try String(contentsOf: cacheFile, encoding: .utf8)
        try expect(cacheText.contains(p1.buildHash), "disk cache JSON should persist buildHash")

        // 2. Repeat inspect hits cache cleanly
        let p1Cached = try PEInspector.inspect(exePath: exe.path)
        try expectEqual(p1Cached.buildHash, p1.buildHash, "cache hit buildHash")
        try expectEqual(p1Cached.timeDateStamp, p1.timeDateStamp, "cache hit timeDateStamp")

        // 3. Size change invalidates cache
        let bytesV2 = makeSyntheticPE(is64Bit: true, timeDateStamp: 0x2222_2222, sizeOfImage: 0x0012_0000, extraPadding: 64)
        try bytesV2.write(to: exe)
        let p2 = try PEInspector.inspect(exePath: exe.path)
        try expectEqual(p2.timeDateStamp, 0x2222_2222, "size change should invalidate cache")
        try expect(p2.buildHash != p1.buildHash, "new buildHash after size invalidation")

        // 4. Same-size mtime change invalidates cache
        let bytesV3 = makeSyntheticPE(is64Bit: true, timeDateStamp: 0x3333_3333, sizeOfImage: 0x0012_0000, extraPadding: 64)
        try expectEqual(bytesV3.count, bytesV2.count, "v3 should match v2 byte size")
        try bytesV3.write(to: exe)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: exe.path)
        let p3 = try PEInspector.inspect(exePath: exe.path)
        try expectEqual(p3.timeDateStamp, 0x3333_3333, "mtime change should invalidate cache even when size is equal")
        try expect(p3.buildHash != p2.buildHash, "new buildHash after mtime invalidation")

        // 5. Neighborhood directory change (dropping DLSS DLL) invalidates cache
        try expect(!p3.detectedUpscalers.contains("DLSS"), "DLSS should not be detected before DLL is present")
        try Data([0]).write(to: dir.appendingPathComponent("nvngx_dlss.dll"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: dir.path)
        let p4 = try PEInspector.inspect(exePath: exe.path)
        try expect(p4.detectedUpscalers.contains("DLSS"), "dropping nvngx_dlss.dll should invalidate cache and detect DLSS")
    }

    // MARK: - 2. GameLibraryManager Tests

    private static func testGameLibraryPathAndTitleHelpers(tempRoot: URL) throws {
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent("lib_helpers", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // canonicalPath resolves relative segments & symlinks
        let realFile = dir.appendingPathComponent("RealGame.exe")
        try Data([0x4D, 0x5A]).write(to: realFile)
        let linkFile = dir.appendingPathComponent("LinkGame.exe")
        try fm.createSymbolicLink(at: linkFile, withDestinationURL: realFile)

        let rawWithDots = dir.path + "/./../lib_helpers/LinkGame.exe"
        let canonical = GameLibraryManager.canonicalPath(rawWithDots)
        let expectedCanonical = GameLibraryManager.canonicalPath(realFile.path)
        try expectEqual(canonical, expectedCanonical, "canonicalPath should resolve dots and symlinks")
        try expectEqual(GameLibraryManager.canonicalPath(""), "", "empty canonicalPath stays empty")

        // stableID determinism & format
        let id1 = GameLibraryManager.stableID(forCanonicalPath: "/Games/Hades/x64/Hades.exe")
        let id2 = GameLibraryManager.stableID(forCanonicalPath: "/Games/Hades/x64/Hades.exe")
        let id3 = GameLibraryManager.stableID(forCanonicalPath: "/Games/Celeste/Celeste.exe")
        try expectEqual(id1, id2, "stableID must be deterministic")
        try expectEqual(id1.count, 12, "stableID should be 12 hex chars")
        try expect(id1.allSatisfy { $0.isHexDigit && $0.isASCII }, "stableID must be ASCII hex")
        try expect(id1 != id3, "distinct paths must produce distinct stableIDs")

        // deriveTitle across layouts
        try expectEqual(
            GameLibraryManager.deriveTitle(exePath: "/Users/test/Games/Hades/x64/Hades.exe"),
            "Hades",
            "deriveTitle under Games/"
        )
        try expectEqual(
            GameLibraryManager.deriveTitle(exePath: "/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Hollow Knight/hollow_knight.exe"),
            "Hollow Knight",
            "deriveTitle under steamapps/common/"
        )
        // Unreal Engine layout with Engine/ directory
        let ueRoot = dir.appendingPathComponent("MyUnrealTitle", isDirectory: true)
        let ueBin = ueRoot.appendingPathComponent("GameProj/Binaries/Win64", isDirectory: true)
        try fm.createDirectory(at: ueBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: ueRoot.appendingPathComponent("Engine", isDirectory: true), withIntermediateDirectories: true)
        try expectEqual(
            GameLibraryManager.deriveTitle(exePath: ueBin.appendingPathComponent("GameProj-Win64-Shipping.exe").path),
            "MyUnrealTitle",
            "deriveTitle for UE5 layout with Engine/"
        )

        // defaultPrefixName & launchPrefixName fallback
        try expectEqual(GameLibraryManager.defaultPrefixName(exePath: "/Games/Hades/x64/Hades.exe"), "Hades")
        try expectEqual(GameLibraryManager.defaultPrefixName(exePath: "/Games/My Game/Game.v2.exe"), "Game.v2")
        let blankPrefixEntry = GameLibraryEntry(title: "Blank", exePath: "/Games/Blank/Blank.exe", prefixName: "   ")
        try expectEqual(blankPrefixEntry.launchPrefixName, "default")
    }

    private static func testGameLibrarySplitArguments() throws {
        try expectEqual(GameLibraryManager.splitArguments(""), [], "empty args")
        try expectEqual(GameLibraryManager.splitArguments("   \t  \n "), [], "whitespace-only args")
        try expectEqual(
            GameLibraryManager.splitArguments("-fullscreen -width 1920 -height 1080"),
            ["-fullscreen", "-width", "1920", "-height", "1080"],
            "simple tokens"
        )
        try expectEqual(
            GameLibraryManager.splitArguments("--title \"Hello World\" --flag"),
            ["--title", "Hello World", "--flag"],
            "double-quoted spaces"
        )
        try expectEqual(
            GameLibraryManager.splitArguments("'C:\\Program Files\\Game' -novid"),
            ["C:\\Program Files\\Game", "-novid"],
            "single quotes preserve backslashes"
        )
        try expectEqual(
            GameLibraryManager.splitArguments("foo\\ bar \"a\\\"b\" \"\""),
            ["foo bar", "a\"b", ""],
            "escaped spaces, escaped quotes, and empty quoted arg"
        )
        try expectEqual(
            GameLibraryManager.splitArguments("pre'mid 1'\"mid 2\"post"),
            ["premid 1mid 2post"],
            "adjacent quoted and unquoted fragments"
        )
    }

    private static func testGameLibraryEntryTolerantDecoding() throws {
        // Legacy JSON missing newer fields (storeSource, storeGameID, profileID, profileNote, steamAppID, etc.)
        let legacyJSON = #"""
        {
            "exePath": "/Games/LegacyTitle/LegacyTitle.exe",
            "title": "Legacy Title",
            "prefixName": "legacy_prefix"
        }
        """#
        let legacy = try JSONDecoder().decode(GameLibraryEntry.self, from: Data(legacyJSON.utf8))
        try expectEqual(legacy.title, "Legacy Title")
        try expectEqual(legacy.prefixName, "legacy_prefix")
        try expectEqual(legacy.engine, .auto)
        try expectEqual(legacy.perfProfile, .balanced)
        try expectEqual(legacy.dx9Backend, .auto)
        try expectEqual(legacy.upscaleMode, "off")
        try expectEqual(legacy.retinaMode, true)
        try expectEqual(legacy.enableHUD, true)
        try expectEqual(legacy.enableSandbox, false)
        try expectEqual(legacy.playCount, 0)
        try expectNil(legacy.storeSource, "missing storeSource defaults to nil")
        try expectNil(legacy.profileID, "missing profileID defaults to nil")
        try expectNil(legacy.steamAppID, "missing steamAppID defaults to nil")
        try expect(!legacy.id.isEmpty, "missing id derived from exePath")

        // Forward-compat JSON with unknown enum values & integer IDs
        let futureJSON = #"""
        {
            "exePath": "/Games/Future/Future.exe",
            "engine": "quantum_cpu_99",
            "perfProfile": "ludicrous",
            "dx9Backend": "magic9",
            "steamAppID": 1145360,
            "storeSource": "GOG",
            "storeGameID": 1423049311
        }
        """#
        let future = try JSONDecoder().decode(GameLibraryEntry.self, from: Data(futureJSON.utf8))
        try expectEqual(future.engine, .auto, "unknown engine falls back to .auto")
        try expectEqual(future.perfProfile, .balanced, "unknown perfProfile falls back to .balanced")
        try expectEqual(future.dx9Backend, .auto, "unknown dx9Backend falls back to .auto")
        try expectEqual(future.steamAppID, "1145360", "numeric steamAppID decoded as String")
        try expectEqual(future.storeSource, "gog", "storeSource normalized to lowercase")
        try expectEqual(future.storeGameID, "1423049311", "numeric storeGameID decoded as String")
    }

    private static func testGameProfileRegistry(tempRoot: URL) throws {
        let emptySupport = tempRoot.appendingPathComponent("profiles_support", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySupport, withIntermediateDirectories: true)

        let registry = GameProfileRegistry.load(supportRoot: emptySupport)
        try expect(
            registry.source.hasSuffix("runtime/profiles/game_profiles.json"),
            "expected registry to load runtime/profiles/game_profiles.json, got \(registry.source)"
        )
        try expect(registry.profiles.count >= 50, "expected >= 50 community game profiles, got \(registry.profiles.count)")

        // Positive matches
        let hades = try expectNotNil(
            registry.match(title: "Hades", exePath: "/Games/Hades/x64/Hades.exe", steamAppID: nil),
            "should match Hades"
        )
        try expectEqual(hades.id, "hades")
        try expectEqual(hades.isVerified, true)

        let hadesEpic = try expectNotNil(
            registry.match(title: "Unknown", exePath: "/Games/Unknown/app.exe", steamAppID: nil, storeSource: "epic", storeGameID: "Min"),
            "should match Hades by Epic AppName"
        )
        try expectEqual(hadesEpic.id, "hades")

        let reanimal = try expectNotNil(
            registry.match(title: "REANIMAL", exePath: "/Games/REANIMAL/REANIMAL.exe", steamAppID: nil),
            "should match REANIMAL"
        )
        try expectEqual(reanimal.id, "reanimal")
        try expectEqual(reanimal.perfProfile, .ultra)

        let nfs = try expectNotNil(
            registry.match(title: "Need For Speed - Hot Pursuit", exePath: "/Games/NFS/game.exe", steamAppID: nil),
            "should match Need for Speed: Hot Pursuit"
        )
        try expectEqual(nfs.id, "need-for-speed-hot-pursuit")
        try expectEqual(nfs.dx9Backend, .wined3d)

        let cp2077 = try expectNotNil(
            registry.match(title: "Cyberpunk 2077", exePath: "/Games/CP/bin/x64/Cyberpunk2077.exe", steamAppID: nil),
            "should match Cyberpunk 2077"
        )
        try expectEqual(cp2077.id, "cyberpunk-2077")
        try expectEqual(cp2077.upscaleMode, "performance")

        let cpGOG = try expectNotNil(
            registry.match(title: "Some Folder", exePath: "/Games/CP/game.exe", steamAppID: nil, storeSource: "gog", storeGameID: "1423049311"),
            "should match Cyberpunk 2077 by GOG gameId"
        )
        try expectEqual(cpGOG.id, "cyberpunk-2077")

        // Ambiguous remakes: MUST NOT match bare original titles or generic exe names
        try expectNil(
            registry.match(title: "SILENT HILL 2", exePath: "/Games/SH2/sh2pc.exe", steamAppID: nil),
            "bare 'SILENT HILL 2' must not match the 2024 remake"
        )
        try expectNil(
            registry.match(title: "Dead Space", exePath: "/Games/Dead Space/Dead Space.exe", steamAppID: nil),
            "bare 'Dead Space' must not match the 2023 remake"
        )

        // Confirm explicit remake identifiers still match
        let sh2Remake = try expectNotNil(
            registry.match(title: "SILENT HILL 2", exePath: "/Games/SH2/SHProto-Win64-Shipping.exe", steamAppID: "2124490"),
            "SILENT HILL 2 (2024) should match by Steam app ID / exe"
        )
        try expectEqual(sh2Remake.id, "silent-hill-2-remake")

        let dsRemake = try expectNotNil(
            registry.match(title: "Dead Space", exePath: "/Games/Dead Space/Dead Space.exe", steamAppID: "1693980"),
            "Dead Space (2023) should match by Steam app ID"
        )
        try expectEqual(dsRemake.id, "dead-space-remake")
    }

    private static func testGOGAndEpicScanning(tempRoot: URL) throws {
        let fm = FileManager.default
        let supportDir = tempRoot.appendingPathComponent("store_scan_support", isDirectory: true)
        let prefixesDir = tempRoot.appendingPathComponent("store_scan_prefixes", isDirectory: true)
        let prefix = prefixesDir.appendingPathComponent("store_prefix", isDirectory: true)
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)

        // --- GOG Galaxy fixture ---
        let gogGameDir = driveC.appendingPathComponent("GOG Games/CyberTest", isDirectory: true)
        let gogBinDir = gogGameDir.appendingPathComponent("bin/x64", isDirectory: true)
        try fm.createDirectory(at: gogBinDir, withIntermediateDirectories: true)

        let peData = makeSyntheticPE(is64Bit: true, importedDLLs: ["d3d11.dll"])
        let gogMainExe = gogBinDir.appendingPathComponent("CyberTest.exe")
        let gogUninstaller = gogGameDir.appendingPathComponent("unins000.exe")
        let gogConfigTool = gogGameDir.appendingPathComponent("config.exe")
        try peData.write(to: gogMainExe)
        try peData.write(to: gogUninstaller)
        try peData.write(to: gogConfigTool)
        try Data("PDF manual".utf8).write(to: gogGameDir.appendingPathComponent("manual.pdf"))

        let gogInfoJSON = #"""
        {
            "gameId": "123456",
            "rootGameId": "123456",
            "name": "CyberTest GOG",
            "playTasks": [
                {"path": "unins000.exe", "type": "FileTask", "category": "tool", "isPrimary": false},
                {"path": "manual.pdf", "type": "FileTask", "category": "document", "isPrimary": false},
                {"path": "https://www.gog.com", "type": "URLTask", "category": "document", "isPrimary": false},
                {"path": "config.exe", "type": "FileTask", "category": "tool", "isPrimary": false},
                {"path": "bin\\x64\\CyberTest.exe", "type": "FileTask", "category": "game", "isPrimary": true}
            ]
        }
        """#
        try Data(gogInfoJSON.utf8).write(to: gogGameDir.appendingPathComponent("goggame-123456.info"))

        // --- Epic Games Store fixture ---
        let epicManifestsDir = driveC.appendingPathComponent("ProgramData/Epic/EpicGamesLauncher/Data/Manifests", isDirectory: true)
        let epicGameDir = driveC.appendingPathComponent("Program Files/Epic Games/TestEpic", isDirectory: true)
        let epicBinDir = epicGameDir.appendingPathComponent("Binaries/Win64", isDirectory: true)
        let epicDLCDir = driveC.appendingPathComponent("Program Files/Epic Games/TestEpicDLC", isDirectory: true)
        try fm.createDirectory(at: epicManifestsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: epicBinDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: epicDLCDir, withIntermediateDirectories: true)

        let epicMainExe = epicBinDir.appendingPathComponent("TestEpic.exe")
        let epicDLCExe = epicDLCDir.appendingPathComponent("dlc_pack.exe")
        try peData.write(to: epicMainExe)
        try peData.write(to: epicDLCExe)

        let epicMainManifest = #"""
        {
            "AppName": "TestEpicApp",
            "MainGameAppName": "TestEpicApp",
            "DisplayName": "Test Epic Game",
            "InstallLocation": "C:\\Program Files\\Epic Games\\TestEpic",
            "LaunchExecutable": "Binaries\\Win64\\TestEpic.exe",
            "AppCategories": ["games"],
            "bIsIncompleteInstall": false
        }
        """#
        let epicDLCManifest = #"""
        {
            "AppName": "TestEpicDLC",
            "MainGameAppName": "TestEpicApp",
            "DisplayName": "Test Epic Expansion DLC",
            "InstallLocation": "C:\\Program Files\\Epic Games\\TestEpicDLC",
            "LaunchExecutable": "dlc_pack.exe",
            "AppCategories": ["games"],
            "bIsIncompleteInstall": false
        }
        """#
        let epicIncompleteManifest = #"""
        {
            "AppName": "IncompleteApp",
            "MainGameAppName": "IncompleteApp",
            "DisplayName": "Incomplete Epic Game",
            "InstallLocation": "C:\\Program Files\\Epic Games\\TestEpic",
            "LaunchExecutable": "Binaries\\Win64\\TestEpic.exe",
            "AppCategories": ["games"],
            "bIsIncompleteInstall": true
        }
        """#
        try Data(epicMainManifest.utf8).write(to: epicManifestsDir.appendingPathComponent("TestEpic.item"))
        try Data(epicDLCManifest.utf8).write(to: epicManifestsDir.appendingPathComponent("TestEpicDLC.item"))
        try Data(epicIncompleteManifest.utf8).write(to: epicManifestsDir.appendingPathComponent("Incomplete.item"))

        // 1. Direct StoreMetadataLocator verification
        let records = StoreMetadataLocator.storeRecords(inPrefix: prefix)
        try expectEqual(records.count, 2, "expected exactly 1 GOG and 1 Epic record (skipping DLC & incomplete)")

        let gogRec = try expectNotNil(records.first(where: { $0.source == "gog" }), "missing GOG record")
        try expectEqual(gogRec.gameID, "123456")
        try expectEqual(gogRec.title, "CyberTest GOG")
        try expectEqual(
            GameLibraryManager.canonicalPath(gogRec.exeURL?.path ?? ""),
            GameLibraryManager.canonicalPath(gogMainExe.path),
            "GOG scanner should pick primary playTasks exe and skip uninstaller/manual/tool"
        )

        let epicRec = try expectNotNil(records.first(where: { $0.source == "epic" }), "missing Epic record")
        try expectEqual(epicRec.gameID, "TestEpicApp")
        try expectEqual(epicRec.title, "Test Epic Game")
        try expectEqual(
            GameLibraryManager.canonicalPath(epicRec.exeURL?.path ?? ""),
            GameLibraryManager.canonicalPath(epicMainExe.path),
            "Epic scanner should pick LaunchExecutable"
        )

        // 2. Full GameLibraryManager.scanKnownLocations() integration
        let mgr = GameLibraryManager(supportRoot: supportDir, prefixRoot: prefixesDir)
        let scanned = mgr.scanKnownLocations()

        let scannedGOG = try expectNotNil(
            scanned.first(where: { $0.storeSource == "gog" && $0.storeGameID == "123456" }),
            "scanKnownLocations should discover GOG game"
        )
        try expectEqual(scannedGOG.title, "CyberTest GOG")
        try expectEqual(scannedGOG.exePath, GameLibraryManager.canonicalPath(gogMainExe.path))
        try expectEqual(scannedGOG.prefixName, "store_prefix")

        let scannedEpic = try expectNotNil(
            scanned.first(where: { $0.storeSource == "epic" && $0.storeGameID == "TestEpicApp" }),
            "scanKnownLocations should discover Epic game"
        )
        try expectEqual(scannedEpic.title, "Test Epic Game")
        try expectEqual(scannedEpic.exePath, GameLibraryManager.canonicalPath(epicMainExe.path))

        try expectNil(
            scanned.first(where: { $0.storeGameID == "TestEpicDLC" }),
            "scanKnownLocations must skip Epic DLC"
        )
        try expectNil(
            scanned.first(where: { $0.exePath.hasSuffix("unins000.exe") }),
            "scanKnownLocations must skip GOG uninstaller"
        )
    }

    // MARK: - 3. ControllerMappingManager Tests

    private static func testControllerPresetsAndDeadzones() throws {
        try expectEqual(ControllerPreset.allCases.count, 5, "should have 5 controller presets")

        let xbox = ControllerMappingProfile.forPreset(.xboxStandard)
        try expectEqual(xbox.preset, .xboxStandard)
        try expectEqual(xbox.isStock, true)
        try expectEqual(xbox.isIdentityMap, true)
        try expectEqual(xbox.invertRightY, false)
        try expectEqual(xbox.enableHaptics, true)

        let nintendo = ControllerMappingProfile.forPreset(.nintendoSwap)
        try expectEqual(nintendo.preset, .nintendoSwap)
        try expectEqual(nintendo.isStock, false)
        try expectEqual(nintendo.buttonMap["a"], "b")
        try expectEqual(nintendo.buttonMap["b"], "a")
        try expectEqual(nintendo.buttonMap["x"], "y")
        try expectEqual(nintendo.buttonMap["y"], "x")
        try expectEqual(nintendo.invertRightY, false)

        let dualSense = ControllerMappingProfile.forPreset(.playstationDualSense)
        try expectEqual(dualSense.preset, .playstationDualSense)
        try expectEqual(dualSense.isIdentityMap, true)
        try expectEqual(dualSense.enableHaptics, true)
        try expectEqual(dualSense.isStock, false)

        let inverted = ControllerMappingProfile.forPreset(.invertedLookY)
        try expectEqual(inverted.preset, .invertedLookY)
        try expectEqual(inverted.isIdentityMap, true)
        try expectEqual(inverted.invertRightY, true)
        try expectEqual(inverted.isStock, false)

        let custom = ControllerMappingProfile.forPreset(.custom)
        try expectEqual(custom.preset, .custom)
        try expectEqual(custom.isStock, false)

        // Deadzone clamping
        try expectEqual(ControllerMappingProfile.clampDeadzone(-0.5), 0.0, "clamp -0.5 -> 0.0")
        try expectEqual(ControllerMappingProfile.clampDeadzone(0.9), 0.35, "clamp 0.9 -> 0.35")
        try expectEqual(ControllerMappingProfile.clampDeadzone(0.15), 0.15, "in-range deadzone preserved")
        try expectEqual(
            ControllerMappingProfile.clampDeadzone(.nan),
            ControllerMappingProfile.defaultDeadzone,
            "NaN deadzone falls back to default"
        )

        let clampedProfile = ControllerMappingProfile(
            preset: .custom,
            leftDeadzone: -0.5,
            rightDeadzone: 0.9,
            invertRightY: false,
            enableHaptics: false
        )
        try expectEqual(clampedProfile.leftDeadzone, 0.0, "init clamps leftDeadzone")
        try expectEqual(clampedProfile.rightDeadzone, 0.35, "init clamps rightDeadzone")
    }

    private static func testControllerPersistenceAndSDLConfig(profilesFile: URL) throws {
        try ControllerMappingManager.resetAll()
        defer { try? ControllerMappingManager.resetAll() }

        // 1. Stock profile emits empty env dict
        let stockEnv = ControllerMappingManager.environmentOverrides(profile: .stock, key: "default")
        try expect(stockEnv.isEmpty, "stock profile must emit empty environment dict")

        let initialResolved = ControllerMappingManager.resolvedProfile(for: "game-alpha")
        try expectEqual(initialResolved.source, "stock")
        try expectEqual(initialResolved.profile, .stock)
        try expect(ControllerMappingManager.environmentOverrides(for: "game-alpha").isEmpty, "unresolved game yields empty env")

        // 2. Set global default to nintendoSwap -> per-game inherits global
        try ControllerMappingManager.setProfile(.forPreset(.nintendoSwap), for: nil)
        try expect(FileManager.default.fileExists(atPath: profilesFile.path), "profiles file created at DIRECTMETAL_CONTROLLER_PROFILES")

        let inherited = ControllerMappingManager.resolvedProfile(for: "game-alpha")
        try expectEqual(inherited.source, "global", "game without override should inherit global default")
        try expectEqual(inherited.profile.preset, .nintendoSwap)

        let nintendoEnv = ControllerMappingManager.environmentOverrides(for: "game-alpha")
        let nintendoSDL = try expectNotNil(nintendoEnv["SDL_GAMECONTROLLERCONFIG"], "SDL_GAMECONTROLLERCONFIG missing for nintendoSwap")
        try expect(nintendoSDL.contains("a:b1,b:b0,x:b3,y:b2"), "nintendoSwap must swap a/b and x/y in SDL config")
        try expect(nintendoSDL.contains("righty:a3,"), "non-inverted righty should not have ~")
        try expectEqual(nintendoEnv["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"], "0", "nintendoSwap disables SDL button label re-swap")
        let lineCount = nintendoSDL.split(separator: "\n").count
        try expectEqual(lineCount, ControllerMappingManager.knownControllers.count * 2, "USB + Bluetooth GUID line per known controller")

        // 3. Per-game override (invertedLookY) overrides global default
        try ControllerMappingManager.setProfile(.forPreset(.invertedLookY), for: "game-alpha")
        let gameOverride = ControllerMappingManager.resolvedProfile(for: "game-alpha")
        try expectEqual(gameOverride.source, "game", "explicit per-game profile should win over global")
        try expectEqual(gameOverride.profile.preset, .invertedLookY)

        let otherGame = ControllerMappingManager.resolvedProfile(for: "game-beta")
        try expectEqual(otherGame.source, "global", "other game still inherits global default")
        try expectEqual(otherGame.profile.preset, .nintendoSwap)

        let invertedEnv = ControllerMappingManager.environmentOverrides(for: "game-alpha")
        let invertedSDL = try expectNotNil(invertedEnv["SDL_GAMECONTROLLERCONFIG"], "SDL_GAMECONTROLLERCONFIG missing for invertedLookY")
        try expect(invertedSDL.contains("righty:a3~"), "invertRightY must append ~ to righty")
        try expectEqual(invertedEnv["DIRECTMETAL_CONTROLLER_INVERT_RIGHT_Y"], "1")
        try expectNil(invertedEnv["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"], "non-nintendo preset should not set label override")

        // 4. Per-game stock override suppresses customized global profile
        try ControllerMappingManager.setProfile(.stock, for: "game-stock")
        let stockOverride = ControllerMappingManager.resolvedProfile(for: "game-stock")
        try expectEqual(stockOverride.source, "game", "per-game stock override must be persisted")
        try expect(ControllerMappingManager.environmentOverrides(for: "game-stock").isEmpty, "per-game stock override emits empty env")

        // 5. Reset single game -> falls back to global; resetAll deletes file cleanly
        let removed = try ControllerMappingManager.resetProfile(for: "game-alpha")
        try expectEqual(removed, true, "resetProfile should return true when entry existed")
        let removedAgain = try ControllerMappingManager.resetProfile(for: "game-alpha")
        try expectEqual(removedAgain, false, "second resetProfile should return false")
        try expectEqual(ControllerMappingManager.resolvedProfile(for: "game-alpha").source, "global")

        try ControllerMappingManager.resetAll()
        try expect(ControllerMappingManager.loadAll().isEmpty, "resetAll should clear all profiles")
        try expect(!FileManager.default.fileExists(atPath: profilesFile.path), "resetAll should remove temp profiles file")
    }

    // MARK: - 4. AppUpdater & UpdateChecker Tests

    private static func testUpdateCheckerSemver() throws {
        try expectEqual(UpdateChecker.compareVersions("1.0.0", "1.0.1"), .orderedAscending, "1.0.0 < 1.0.1")
        try expectEqual(UpdateChecker.compareVersions("1.0.1", "1.1.0"), .orderedAscending, "1.0.1 < 1.1.0")
        try expectEqual(UpdateChecker.compareVersions("1.1.0", "2.0.0"), .orderedAscending, "1.1.0 < 2.0.0")
        try expectEqual(UpdateChecker.compareVersions("2.0.0", "1.1.0"), .orderedDescending, "2.0.0 > 1.1.0")
        try expectEqual(UpdateChecker.compareVersions("v1.0.1", "1.0.1"), .orderedSame, "v1.0.1 == 1.0.1")
        try expectEqual(UpdateChecker.compareVersions("V1.0.1", "1.0.1"), .orderedSame, "V1.0.1 == 1.0.1")
        try expectEqual(UpdateChecker.compareVersions("1.2.0-beta.1", "1.2.0"), .orderedAscending, "prerelease < release")

        try expectEqual(UpdateChecker.isVersionTag("v1.2.0"), true)
        try expectEqual(UpdateChecker.isVersionTag("1.0.1"), true)
        try expectEqual(UpdateChecker.isVersionTag("conformance-bins-v0.2"), false)
        try expectEqual(UpdateChecker.isVersionTag("nightly"), false)
    }

    private static func testUpdateCheckerFixturesAndHTTPPolicy(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("updater_fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            setEnv("DIRECTMETAL_UPDATE_URL", nil)
            setEnv("DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP", nil)
        }

        // 1. Up-to-date v1.0.1 fixture via file://
        let upToDateFile = dir.appendingPathComponent("release_1_0_1.json")
        let upToDateJSON = #"""
        {
            "tag_name": "v1.0.1",
            "html_url": "https://github.com/amoham42/DirectMetal/releases/tag/v1.0.1",
            "published_at": "2026-10-01T00:00:00Z",
            "assets": [
                {
                    "name": "DirectMetal-Lite-macOS-arm64.dmg",
                    "browser_download_url": "https://example.com/DirectMetal-Lite-macOS-arm64.dmg",
                    "size": 12345678
                }
            ]
        }
        """#
        try Data(upToDateJSON.utf8).write(to: upToDateFile)
        setEnv("DIRECTMETAL_UPDATE_URL", upToDateFile.absoluteString)

        let resCurrent = UpdateChecker.check(currentVersion: "1.0.1")
        try expectNil(resCurrent.error, "up-to-date check should have no error")
        try expectEqual(resCurrent.latestVersion, "1.0.1")
        try expectEqual(resCurrent.updateAvailable, false, "v1.0.1 vs 1.0.1 must be up-to-date")

        // 2. Newer v1.2.0 fixture via file://
        let newerFile = dir.appendingPathComponent("release_1_2_0.json")
        let newerJSON = #"""
        {
            "tag_name": "v1.2.0",
            "html_url": "https://github.com/amoham42/DirectMetal/releases/tag/v1.2.0",
            "published_at": "2026-11-01T00:00:00Z",
            "assets": [
                {
                    "name": "DirectMetal-Lite-macOS-arm64.dmg",
                    "browser_download_url": "https://example.com/DirectMetal-Lite-macOS-arm64.dmg",
                    "size": 23456789
                },
                {
                    "name": "DirectMetal-Lite-macOS-arm64.dmg.sha256",
                    "browser_download_url": "https://example.com/DirectMetal-Lite-macOS-arm64.dmg.sha256",
                    "size": 96
                }
            ]
        }
        """#
        try Data(newerJSON.utf8).write(to: newerFile)
        setEnv("DIRECTMETAL_UPDATE_URL", newerFile.absoluteString)

        let resNewer = UpdateChecker.check(currentVersion: "1.0.1")
        try expectNil(resNewer.error, "newer release check should have no error")
        try expectEqual(resNewer.latestVersion, "1.2.0")
        try expectEqual(resNewer.updateAvailable, true, "v1.2.0 > 1.0.1 should report updateAvailable")
        try expectEqual(resNewer.assetName, "DirectMetal-Lite-macOS-arm64.dmg")
        try expectEqual(resNewer.sha256URL, "https://example.com/DirectMetal-Lite-macOS-arm64.dmg.sha256")

        // 3. Release list skipping prereleases, drafts, and non-version tags
        let listFile = dir.appendingPathComponent("releases_list.json")
        let listJSON = #"""
        [
            {"tag_name": "conformance-bins-v0.2", "draft": false, "prerelease": false, "assets": []},
            {"tag_name": "v2.0.0-rc.1", "draft": false, "prerelease": true, "assets": []},
            {"tag_name": "v3.0.0", "draft": true, "prerelease": false, "assets": []},
            {"tag_name": "v1.0.1", "draft": false, "prerelease": false, "assets": []},
            {"tag_name": "v1.2.0", "draft": false, "prerelease": false, "assets": []}
        ]
        """#
        try Data(listJSON.utf8).write(to: listFile)
        setEnv("DIRECTMETAL_UPDATE_URL", listFile.absoluteString)

        let resList = UpdateChecker.check(currentVersion: "1.0.1")
        try expectNil(resList.error, "release list check should succeed")
        try expectEqual(resList.latestVersion, "1.2.0", "must skip prerelease, draft, and conformance-bins-v0.2")
        try expectEqual(resList.updateAvailable, true)

        // 4. Refuses insecure http:// URLs in both UpdateChecker and AppUpdater
        setEnv("DIRECTMETAL_UPDATE_URL", "http://example.com/releases/latest")
        let resHTTP = UpdateChecker.check(currentVersion: "1.0.1")
        try expectEqual(resHTTP.updateAvailable, false)
        let httpErr = try expectNotNil(resHTTP.error, "UpdateChecker must refuse http:// URLs")
        try expect(httpErr.lowercased().contains("refusing"), "unexpected http error: \(httpErr)")

        setEnv("DIRECTMETAL_ALLOW_INSECURE_UPDATE_HTTP", nil)
        let insecureURL = try expectNotNil(URL(string: "http://example.com/DirectMetal.dmg"))
        try expectThrows("AppUpdater must refuse http:// URL") {
            try AppUpdater.validateSourceURL(insecureURL, what: "update")
        } verify: { err in
            if case AppUpdateError.invalidURL = err { return true }
            return false
        }

        // Valid https:// and file:// URLs pass validation
        try AppUpdater.validateSourceURL(try expectNotNil(URL(string: "https://example.com/DirectMetal.dmg")), what: "update")
        try AppUpdater.validateSourceURL(newerFile, what: "update")
    }

    private static func testAppUpdaterChecksumParsing(tempRoot: URL) throws {
        let hashA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let hashB = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

        // "<hash>  filename" format (shasum -a 256)
        let sidecarNamed = "\(hashA.uppercased())  DirectMetal-Lite-macOS-arm64.dmg\n"
        try expectEqual(
            AppUpdater.parseChecksum(sidecarNamed, fileName: "DirectMetal-Lite-macOS-arm64.dmg"),
            hashA,
            "named sidecar should parse and lowercase digest"
        )

        // Bare "<hash>" format
        try expectEqual(
            AppUpdater.parseChecksum("  \(hashB)\n", fileName: "DirectMetal-Lite-macOS-arm64.dmg"),
            hashB,
            "bare hash sidecar should parse"
        )

        // Multi-entry SHA256SUMS selects matching filename and rejects unknown filename
        let sums = """
        # DirectMetal release checksums
        \(hashA)  DirectMetal-Lite-macOS-arm64.dmg
        \(hashB) *DirectMetal-macOS-arm64.dmg
        """
        try expectEqual(AppUpdater.parseChecksum(sums, fileName: "DirectMetal-macOS-arm64.dmg"), hashB)
        try expectNil(AppUpdater.parseChecksum(sums, fileName: "NonExistent.dmg"), "multi-entry mismatch must return nil")

        // BSD format
        let bsd = "SHA256 (DirectMetal-Lite-macOS-arm64.dmg) = \(hashA)\n"
        try expectEqual(AppUpdater.parseChecksum(bsd, fileName: "DirectMetal-Lite-macOS-arm64.dmg"), hashA)

        // Invalid checksum text
        try expectNil(AppUpdater.parseChecksum("not-a-valid-sha256  file.dmg", fileName: "file.dmg"))

        // Round-trip file:// fetchChecksum
        let shaFile = tempRoot.appendingPathComponent("test.dmg.sha256")
        try Data(sidecarNamed.utf8).write(to: shaFile)
        let fetched = try AppUpdater.fetchChecksum(from: shaFile, fileName: "DirectMetal-Lite-macOS-arm64.dmg")
        try expectEqual(fetched, hashA)
    }

    // MARK: - 5. GameArtworkManager Fuzz Safety Tests

    private static func testGameArtworkManagerFuzzSafety(tempRoot: URL) throws {
        var peInputs: [Data] = []
        var icoInputs: [Data] = []

        // Crafted edge-case PE buffers
        peInputs.append(Data())
        peInputs.append(Data([0x4D]))
        peInputs.append(Data([0x4D, 0x5A]))
        peInputs.append(Data(repeating: 0xFF, count: 64))
        peInputs.append(Data(repeating: 0x00, count: 128))

        // Huge / overflowing lfanew values
        for lfanew: UInt32 in [0, 1, 0x3C, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF] {
            var d = Data(repeating: 0, count: 96)
            d.writeUInt16LE(0x5A4D, at: 0)
            d.writeUInt32LE(lfanew, at: 0x3C)
            peInputs.append(d)
        }

        // Valid PE header with malformed resource directory (self-loop, huge entry count, bad RVA)
        for scenario in 0..<6 {
            var d = makeSyntheticPE(is64Bit: scenario % 2 == 0, extraPadding: 512)
            let dataDirBase = 0x58 + (scenario % 2 == 0 ? 112 : 96)
            let secBase = 0x58 + (scenario % 2 == 0 ? 240 : 224)
            d.writeUInt16LE(1, at: 0x44 + 2) // 1 section
            d.writeUInt32LE(0x2000, at: dataDirBase + 2 * 8) // rsrc RVA
            d.writeUInt32LE(0x0200, at: dataDirBase + 2 * 8 + 4) // rsrc size
            d.writeUInt32LE(0x0200, at: secBase + 8)
            d.writeUInt32LE(0x2000, at: secBase + 12)
            d.writeUInt32LE(0x0200, at: secBase + 16)
            d.writeUInt32LE(0x0200, at: secBase + 20)
            switch scenario {
            case 0:
                // Self-referencing resource directory loop
                d.writeUInt16LE(0, at: 0x200 + 12)
                d.writeUInt16LE(1, at: 0x200 + 14)
                d.writeUInt32LE(3, at: 0x200 + 16) // RT_ICON
                d.writeUInt32LE(0x8000_0000, at: 0x200 + 20) // points back to offset 0
            case 1:
                // Huge entry count exceeding buffer
                d.writeUInt16LE(0xFFFF, at: 0x200 + 12)
                d.writeUInt16LE(0xFFFF, at: 0x200 + 14)
            case 2:
                // RT_ICON leaf pointing to corrupted DIB
                d.writeUInt16LE(1, at: 0x200 + 14)
                d.writeUInt32LE(3, at: 0x200 + 16)
                d.writeUInt32LE(0x8000_0020, at: 0x200 + 20)
                d.writeUInt16LE(1, at: 0x220 + 14)
                d.writeUInt32LE(1, at: 0x220 + 16)
                d.writeUInt32LE(0x8000_0040, at: 0x220 + 20)
                d.writeUInt16LE(1, at: 0x240 + 14)
                d.writeUInt32LE(0x0409, at: 0x240 + 16)
                d.writeUInt32LE(0x0000_0060, at: 0x240 + 20)
                // Data entry: RVA 0x2080, size 64
                d.writeUInt32LE(0x2080, at: 0x260)
                d.writeUInt32LE(64, at: 0x264)
                // Truncated/bogus BITMAPINFOHEADER at 0x280
                d.writeUInt32LE(40, at: 0x280)
                d.writeUInt32LE(512, at: 0x284)
                d.writeUInt32LE(1024, at: 0x288)
                d.writeUInt16LE(32, at: 0x280 + 14)
            default:
                // Huge section count / out-of-bounds resource RVA
                d.writeUInt16LE(96, at: 0x44 + 2)
                d.writeUInt32LE(0xFFFF_F000, at: dataDirBase + 2 * 8)
            }
            peInputs.append(d)
        }

        // Crafted edge-case ICO / DIB / PNG buffers
        icoInputs.append(Data())
        icoInputs.append(Data([0, 0, 1, 0, 0, 0])) // 0 entries
        icoInputs.append(Data([0, 0, 1, 0, 0xFF, 0xFF])) // 65535 entries, truncated
        // ICO with overflowing offset & size
        var icoOverflow = Data(repeating: 0, count: 64)
        icoOverflow.writeUInt16LE(1, at: 2)
        icoOverflow.writeUInt16LE(1, at: 4)
        icoOverflow.writeUInt32LE(0xFFFF_FFFF, at: 6 + 8)
        icoOverflow.writeUInt32LE(0xFFFF_FFFF, at: 6 + 12)
        icoInputs.append(icoOverflow)

        // Truncated PNG signature + bogus IHDR
        icoInputs.append(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]))

        // Bogus DIB headers (Int32.min height, invalid bpp, huge palette, truncated XOR/AND)
        for (w, h, bpp, comp): (UInt32, UInt32, UInt16, UInt32) in [
            (16, 0x8000_0000, 32, 0),
            (1024, 2048, 32, 0),
            (32, 64, 8, 0),
            (32, 64, 32, 3),
            (16, 32, 16, 0),
            (0, 0, 32, 0),
        ] {
            var dib = Data(repeating: 0, count: 52)
            dib.writeUInt32LE(40, at: 0)
            dib.writeUInt32LE(w, at: 4)
            dib.writeUInt32LE(h, at: 8)
            dib.writeUInt16LE(bpp, at: 14)
            dib.writeUInt32LE(comp, at: 16)
            dib.writeUInt32LE(0xFFFF_FFFF, at: 32)
            icoInputs.append(dib)
        }

        // 50 deterministic pseudo-random buffers across sizes
        var rng = Xorshift64(state: 0xD1EC_7AE7_A123_4567)
        let sizes = [1, 3, 8, 16, 22, 40, 64, 96, 128, 256, 512, 1024, 4096]
        for i in 0..<50 {
            let buf = rng.randomData(count: sizes[i % sizes.count])
            peInputs.append(buf)
            icoInputs.append(buf)
        }

        try expect(peInputs.count >= 60, "expected 60+ PE fuzz buffers")
        try expect(icoInputs.count >= 60, "expected 60+ ICO fuzz buffers")

        for (idx, buf) in peInputs.enumerated() {
            try expectNil(PEIconExtractor.extractIcon(peData: buf), "malformed PE buffer #\(idx) should return nil")
        }
        for (idx, buf) in icoInputs.enumerated() {
            try expectNil(PEIconExtractor.decodeICOFile(buf), "malformed ICO buffer #\(idx) should return nil")
            try expectNil(PEIconExtractor.decodeIconImage(buf), "malformed icon image #\(idx) should return nil")
        }

        // End-to-end GameArtworkManager check on a malformed .exe and .ico on disk
        let artDir = tempRoot.appendingPathComponent("artwork_fuzz", isDirectory: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let badExe = artDir.appendingPathComponent("Broken.exe")
        let badICO = artDir.appendingPathComponent("Broken.ico")
        try Data([0x4D, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: badExe)
        try icoOverflow.write(to: badICO)

        try expectNil(GameArtworkManager.decodeImageFile(at: badICO), "malformed .ico file should return nil")
        let artworkMgr = GameArtworkManager(prefixRoot: tempRoot.appendingPathComponent("prefixes", isDirectory: true))
        let entry = GameLibraryEntry(title: "Broken", exePath: badExe.path, prefixName: "broken")
        try expectNil(artworkMgr.resolveArtwork(for: entry, style: .icon), "resolveArtwork(.icon) on malformed exe must return nil")
        try expectNil(artworkMgr.resolveArtwork(for: entry, style: .banner), "resolveArtwork(.banner) on malformed exe must return nil")
    }

    // MARK: - 6. BasePrefixHydrator Tests

    private static func testBasePrefixHydratorFingerprints(tempRoot: URL, cacheRoot: URL) throws {
        let fm = FileManager.default
        let runtimeRoot = tempRoot.appendingPathComponent("hydrator_runtime", isDirectory: true)
        let dehydratedDir = runtimeRoot.appendingPathComponent(BasePrefixHydrator.dehydratedDirName, isDirectory: true)
        let fpFile = dehydratedDir.appendingPathComponent(BasePrefixHydrator.fingerprintFileName)

        // Absent dehydrated directory returns nil
        try expectNil(try BasePrefixHydrator.readFingerprint(runtimeRoot: runtimeRoot), "absent fingerprint returns nil")

        try fm.createDirectory(at: dehydratedDir, withIntermediateDirectories: true)

        // Valid ASCII fingerprints (including whitespace trimming and max 128 chars)
        let maxLenValid = String(repeating: "a", count: 128)
        for (raw, expected) in [
            ("abc123\n", "abc123"),
            ("  10.6-arm64ec_v1.2  \r\n", "10.6-arm64ec_v1.2"),
            (maxLenValid, maxLenValid),
        ] {
            try Data(raw.utf8).write(to: fpFile)
            let parsed = try BasePrefixHydrator.readFingerprint(runtimeRoot: runtimeRoot)
            try expectEqual(parsed, expected, "valid fingerprint should be accepted")
        }

        // Cache destination honors DIRECTMETAL_BASE_PREFIX_CACHE
        let dest = BasePrefixHydrator.hydratedDestination(fingerprint: "10.6-arm64ec")
        try expectEqual(dest.path, cacheRoot.appendingPathComponent("arm64ec-10.6-arm64ec").path)

        // Invalid / path-traversal fingerprints must throw invalidFingerprint
        let invalidCases: [(label: String, value: String)] = [
            ("path traversal ../escape", "../escape"),
            ("slash a/b", "a/b"),
            ("empty string", ""),
            ("whitespace only", "   \n\t "),
            ("dot", "."),
            ("double dot", ".."),
            ("over 128 chars", String(repeating: "x", count: 129)),
            ("space inside", "bad fingerprint"),
            ("shell metachar", "fp;rm-rf"),
            ("non-ASCII", "café-123"),
        ]
        for (label, badValue) in invalidCases {
            try Data(badValue.utf8).write(to: fpFile)
            try expectThrows("should reject \(label)") {
                try BasePrefixHydrator.readFingerprint(runtimeRoot: runtimeRoot)
            } verify: { err in
                if case BasePrefixHydratorError.invalidFingerprint = err { return true }
                return false
            }
        }
    }

    // MARK: - 7. RuntimeLauncher Tests

    private static func testRuntimeLauncherResourcesAndVersion() throws {
        let resources = RuntimeLauncher.resolveBundledResources()
        let confURL = try expectNotNil(
            resources.mullionConfig,
            "resolveBundledResources() should locate mullion.conf when run from repo root"
        )
        try expectEqual(confURL.lastPathComponent, "mullion.conf")
        try expect(FileManager.default.fileExists(atPath: confURL.path), "mullion.conf must exist on disk")

        let version = RuntimeLauncher.appVersion()
        try expect(!version.isEmpty, "appVersion() must not be empty")
        try expect(
            UpdateChecker.isVersionTag(version),
            "appVersion() should return a valid semver string, got '\(version)'"
        )
    }

    // MARK: - 8. Vulkan/OpenGL, Parallel Shader Cache, Playtime & Prefix Stats Tests

    private static func testPEInspectorVulkanAndOpenGL(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("pe_vk_gl", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("vk_game.exe")
        let data = makeSyntheticPE(is64Bit: true, importedDLLs: ["KERNEL32.dll", "vulkan-1.dll", "opengl32.dll"])
        try data.write(to: exe)

        let prof = try PEInspector.inspect(exePath: exe.path)
        try expect(prof.detectedAPIs.contains("Vulkan"), "expected Vulkan in detectedAPIs, got \(prof.detectedAPIs)")
        try expect(prof.detectedAPIs.contains("OpenGL"), "expected OpenGL in detectedAPIs, got \(prof.detectedAPIs)")

        var entry = GameLibraryEntry(title: "VK Game", exePath: exe.path, prefixName: "vk_game")
        entry.apply(profile: prof)
        let badgeTexts = LauncherStyle.apiBadges(for: entry).map(\.text)
        try expect(badgeTexts.contains("Vulkan"), "expected Vulkan badge, got \(badgeTexts)")
        try expect(badgeTexts.contains("OpenGL"), "expected OpenGL badge, got \(badgeTexts)")
    }

    private static func testShaderCacheListPruneAndParallelRoundTrip(tempRoot: URL) throws {
        let fm = FileManager.default
        let cacheRoot = tempRoot.appendingPathComponent("shader_cache_root", isDirectory: true)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        setEnv("DIRECTMETAL_SHADER_CACHE_ROOT", cacheRoot.path)
        defer { setEnv("DIRECTMETAL_SHADER_CACHE_ROOT", nil) }

        let hostKey = RuntimeLauncher.queryHardwareInfo().cacheKey
        let currentDir = cacheRoot.appendingPathComponent("game_current_\(hostKey)", isDirectory: true)
        let staleDir = cacheRoot.appendingPathComponent("game_old_apple9_24A000", isDirectory: true)
        let genericDir = cacheRoot.appendingPathComponent("generic_unkeyed", isDirectory: true)
        for d in [currentDir, staleDir, genericDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // 8 files to exercise DispatchQueue.concurrentPerform (>= 4) in exportArchive & importArchive
        for i in 0..<8 {
            try Data("compiled-metal-pso-\(i)".utf8).write(to: currentDir.appendingPathComponent("pso_\(i).metallib"))
        }
        try Data("stale-cache-payload".utf8).write(to: staleDir.appendingPathComponent("old.metallib"))
        try Data("generic-payload".utf8).write(to: genericDir.appendingPathComponent("gen.metallib"))

        let listed = ShaderCacheManager.listLocalCaches()
        try expectEqual(listed.count, 3, "expected 3 shader cache entries")
        let staleListed = try expectNotNil(listed.first(where: { $0.name == staleDir.lastPathComponent }))
        try expect(staleListed.isKnownKeyedEntry && !staleListed.matchesHostCacheKey, "stale entry should be flagged incompatible")

        let archivePath = tempRoot.appendingPathComponent("parallel_test.dmcache.tar.gz").path
        let exported = try ShaderCacheManager.exportArchive(to: archivePath, filterEntry: "game_current_")
        try expectEqual(exported.fileCount, 8, "exported archive should contain all 8 files")

        let imported = try ShaderCacheManager.importArchive(from: archivePath, allowCrossBuild: false)
        try expectEqual(imported.verifiedFiles, 8, "parallel import should verify all 8 files")

        let dryRes = try ShaderCacheManager.pruneStaleCaches(dryRun: true)
        try expectEqual(dryRes.removedEntries, [staleDir.lastPathComponent], "dry-run should target only stale entry")
        try expect(fm.fileExists(atPath: staleDir.path), "dry-run must not delete files")

        let realRes = try ShaderCacheManager.pruneStaleCaches(dryRun: false)
        try expectEqual(realRes.removedEntries, [staleDir.lastPathComponent], "prune should remove stale entry")
        try expect(!fm.fileExists(atPath: staleDir.path), "stale entry should be deleted after prune")
        try expect(fm.fileExists(atPath: currentDir.path), "current-host entry must be preserved")
        try expect(fm.fileExists(atPath: genericDir.path), "unkeyed generic entry must be preserved")
    }

    private static func testPlaytimeTrackingAndSorting(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("playtime_test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exeA = dir.appendingPathComponent("Alpha.exe")
        let exeB = dir.appendingPathComponent("Beta.exe")
        try makeSyntheticPE(is64Bit: true, importedDLLs: ["d3d11.dll"]).write(to: exeA)
        try makeSyntheticPE(is64Bit: true, importedDLLs: ["d3d12.dll"]).write(to: exeB)

        let mgr = GameLibraryManager(
            supportRoot: dir.appendingPathComponent("support", isDirectory: true),
            prefixRoot: dir.appendingPathComponent("prefixes", isDirectory: true)
        )
        let entryA = try mgr.addOrUpdate(exePath: exeA.path, customTitle: "Alpha")
        let entryB = try mgr.addOrUpdate(exePath: exeB.path, customTitle: "Beta")
        mgr.recordLaunch(id: entryA.id)
        mgr.recordSessionDuration(id: entryA.id, seconds: 120)
        mgr.recordLaunch(id: entryB.id)
        mgr.recordSessionDuration(id: entryB.id, seconds: 5400) // 1.5 hrs

        let loaded = mgr.load()
        let sorted = LibrarySort.mostPlayed.sorted(loaded)
        try expectEqual(sorted.first?.title, "Beta", "Most Played should rank longer playtime first")
        try expectNil(LauncherStyle.playtimeText(45), "under 60s should return nil")
        try expectEqual(LauncherStyle.playtimeText(120), "2m played")
        try expectEqual(LauncherStyle.playtimeText(5400), "1.5 hrs played")
    }

    private static func testPrefixManagerStats(tempRoot: URL) throws {
        let fm = FileManager.default
        let root = tempRoot.appendingPathComponent("prefix_stats_root", isDirectory: true)
        let p1 = root.appendingPathComponent("game_one", isDirectory: true)
        let p2 = root.appendingPathComponent("game_two", isDirectory: true)
        try fm.createDirectory(at: p1, withIntermediateDirectories: true)
        try fm.createDirectory(at: p2, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: p1.appendingPathComponent("system.reg"))
        try Data(repeating: 0x42, count: 1024).write(to: p2.appendingPathComponent("system.reg"))

        let meta = PrefixMetadata(
            createdUtc: "2026-11-27T00:00:00Z",
            basePrefix: "/tmp/base",
            gameExe: "/Games/Hades.exe",
            dxApi: "D3D11",
            shaderCacheKey: "apple7_26B131",
            cowCloneMs: 0.35
        )
        try JSONEncoder().encode(meta).write(to: p1.appendingPathComponent("directmetal_prefix.json"))

        let mgr = PrefixManager(prefixRoot: root)
        let stats = mgr.prefixStats()
        try expectEqual(stats.count, 2, "expected 2 prefix stats")
        try expectEqual(stats[0].name, "game_one", "prefixStats should sort largest first")
        try expectEqual(stats[0].gameExe, "/Games/Hades.exe")
        try expect(stats[0].sizeBytes > 4096, "game_one should include system.reg + metadata bytes")
        try expectEqual(stats[1].sizeBytes, 1024)
    }

    private static func testSteamManifestIndexCaching(tempRoot: URL) throws {
        let fm = FileManager.default
        let steamapps = tempRoot.appendingPathComponent("steam_cache_test/steamapps", isDirectory: true)
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        SteamLibraryLocator.invalidateManifestCache()

        let acf1 = """
        "AppState"
        {
            "appid"        "1145360"
            "installdir"   "Hades"
        }
        """
        try Data(acf1.utf8).write(to: steamapps.appendingPathComponent("appmanifest_1145360.acf"))
        let idx1 = SteamLibraryLocator.manifestIndex(steamapps: steamapps)
        try expectEqual(idx1["hades"], "1145360")
        let idx1Hit = SteamLibraryLocator.manifestIndex(steamapps: steamapps)
        try expectEqual(idx1Hit, idx1)

        // Adding a new manifest updates the directory mtime (bump explicitly to avoid 1-tick coarseness)
        let acf2 = """
        "AppState"
        {
            "appid"        "1145350"
            "installdir"   "Hades II"
        }
        """
        try Data(acf2.utf8).write(to: steamapps.appendingPathComponent("appmanifest_1145350.acf"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: steamapps.path)

        let idx2 = SteamLibraryLocator.manifestIndex(steamapps: steamapps)
        try expectEqual(idx2["hades"], "1145360")
        try expectEqual(idx2["hades ii"], "1145350")
    }

    private static func testSandboxProfileRendering(tempRoot: URL) throws {
        let fm = FileManager.default
        let prefixesRoot = tempRoot.appendingPathComponent("sb_prefixes", isDirectory: true)
        let targetPrefix = prefixesRoot.appendingPathComponent("game_a", isDirectory: true)
        let gameDir = tempRoot.appendingPathComponent("game \"quoted\" dir", isDirectory: true)
        let cacheDir = tempRoot.appendingPathComponent("sb_cache", isDirectory: true)
        for d in [prefixesRoot, targetPrefix, gameDir, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // Z:\ drive output dir inference
        let inferred = DirectMetalSandbox.inferOutputDir(
            from: ["--foo", "--out", "Z:\\tmp\\dm_out"],
            explicit: nil,
            targetPrefix: targetPrefix.path
        )
        try expectEqual(inferred, "/tmp/dm_out")
        let explicit = DirectMetalSandbox.inferOutputDir(
            from: ["--out", "Z:\\ignored"],
            explicit: "/tmp/explicit_dir",
            targetPrefix: targetPrefix.path
        )
        try expectEqual(explicit, "/tmp/explicit_dir")

        // Offline Seatbelt profile rendering + quote escaping
        let sbURL = try DirectMetalSandbox.writeProfile(
            prefixesRoot: prefixesRoot.path,
            targetPrefix: targetPrefix.path,
            gameDir: gameDir.path,
            shaderCacheDir: cacheDir.path,
            outputDir: targetPrefix.path,
            allowNetwork: false
        )
        let content = try String(contentsOf: sbURL, encoding: .utf8)
        try expect(!content.contains("${TARGET_PREFIX}"), "placeholders must be substituted")
        try expect(!content.contains("${NETWORK_RULES}"), "network rules must be substituted")
        try expect(content.contains("deny network-outbound"), "offline profile must deny outbound IP")
        try expect(content.contains("game \\\"quoted\\\" dir"), "quotes in game path must be SBPL-escaped")
    }

    private static func testAttestationSignVerifyAndTamperRejection() throws {
        let nonce = "deadbeef01234567"
        let status = DirectMetalAttestation.collectStatus(targetBinaryPath: nil, sandboxActive: true)
        let bundle = try DirectMetalAttestation.generateSignedBundle(
            status: status,
            nonceHex: nonce,
            targetPid: nil
        )
        try expect(bundle.verified, "self-verification of freshly signed bundle must succeed")
        try expect(
            DirectMetalAttestation.verify(bundleJSON: bundle.json, expectedNonce: nonce),
            "valid signed attestation must verify"
        )
        try expect(
            !DirectMetalAttestation.verify(bundleJSON: bundle.json, expectedNonce: "wrong_nonce_9999"),
            "mismatched nonce must be rejected"
        )
        // Tamper with a signed field inside payload
        let tampered = bundle.json.replacingOccurrences(of: "\"sandbox_active\":true", with: "\"sandbox_active\":false")
            .replacingOccurrences(of: "\"sandbox_active\" : true", with: "\"sandbox_active\" : false")
        try expect(tampered != bundle.json, "tamper replacement should modify JSON")
        try expect(
            !DirectMetalAttestation.verify(bundleJSON: tampered, expectedNonce: nonce),
            "tampered attestation payload must fail ECDSA verification"
        )
    }

    private static func testDisplayCapabilitiesAndLibraryFilters() throws {
        let xdr = DisplayCapabilities(
            displayAvailable: true,
            displayName: "Built-in Liquid Retina XDR",
            logicalWidth: 1512,
            logicalHeight: 982,
            pixelWidth: 3024,
            pixelHeight: 1964,
            scaleFactor: 2.0,
            dpi: 192,
            refreshRateHz: 120,
            variableRefresh: true,
            edrHeadroom: 2.0,
            potentialEDRHeadroom: 16.0,
            supportsHDR: true,
            source: "appkit"
        )
        try expect(xdr.isRetina && xdr.isProMotion, "2x 120Hz should be Retina + ProMotion")
        try expectEqual(xdr.resolutionLabel, "1512×982 @2x Retina")
        try expectEqual(xdr.refreshLabel, "120 Hz ProMotion")
        try expectEqual(xdr.hdrLabel, "HDR/EDR 16.0x")

        let dx12 = GameLibraryEntry(title: "UE5 Game", exePath: "/Games/UE5/Game.exe", prefixName: "ue5", architecture: "x86_64", detectedAPIs: ["D3D12"])
        let dx9 = GameLibraryEntry(title: "Classic 32", exePath: "/Games/Old/Game.exe", prefixName: "old", architecture: "x86", detectedAPIs: ["D3D9"])
        try expect(LibraryFilter.dx12.matches(dx12) && !LibraryFilter.dx12.matches(dx9), "dx12 filter should match only D3D12")
        try expect(LibraryFilter.dx9.matches(dx9) && LibraryFilter.x86.matches(dx9), "dx9 and x86 filters should match 32-bit D3D9")
        try expect(!LibraryFilter.x86.matches(dx12), "x86 filter must not match x86_64")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let redacted = LaunchDiagnostics.redactHome("\(home)/Games/Hades/Hades.exe")
        try expectEqual(redacted, "~/Games/Hades/Hades.exe", "home directory should redact to ~")
    }

    private static func testBuiltInBenchmarkScorecard() throws {
        let card = DirectMetalBenchmark.runAll()
        try expectEqual(card.schema, "directmetal.bench.v1")
        try expectEqual(card.metrics.count, 4, "expected 4 built-in benchmark metrics")
        for m in card.metrics {
            try expect(m.value > 0, "benchmark \(m.id) should produce positive value, got \(m.value) (\(m.detail))")
        }
    }

    private static func testLibraryBackupExportAndImport(tempRoot: URL) throws {
        let dir = tempRoot.appendingPathComponent("backup_roundtrip", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("BackupGame.exe")
        try makeSyntheticPE(is64Bit: true, importedDLLs: ["d3d12.dll"]).write(to: exe)

        let srcSupport = dir.appendingPathComponent("src_support", isDirectory: true)
        let dstSupport = dir.appendingPathComponent("dst_support", isDirectory: true)
        let prefixes = dir.appendingPathComponent("prefixes", isDirectory: true)
        let srcMgr = GameLibraryManager(supportRoot: srcSupport, prefixRoot: prefixes)
        var added = try srcMgr.addOrUpdate(exePath: exe.path, customTitle: "Backup Game")
        added.perfProfile = .ultra
        added.upscaleMode = "quality"
        added.totalPlaySeconds = 7200
        srcMgr.save([added])

        let ctrlProfile = ControllerMappingProfile.forPreset(.nintendoSwap)
        try ControllerMappingManager.setProfile(ctrlProfile, for: added.id)

        let backupFile = dir.appendingPathComponent("directmetal_backup.json")
        let exported = try srcMgr.exportBackup(to: backupFile)
        try expectEqual(exported.games.count, 1)
        try expectEqual(exported.controllerProfiles[added.id]?.preset, .nintendoSwap)

        // Reset controller profiles, then restore into a fresh library support dir
        try ControllerMappingManager.resetProfile(for: added.id)
        let dstMgr = GameLibraryManager(supportRoot: dstSupport, prefixRoot: prefixes)
        let summary1 = try dstMgr.importBackup(from: backupFile, overwriteExisting: false)
        try expectEqual(summary1.added, 1)
        try expectEqual(summary1.skipped, 0)
        try expect(summary1.controllerProfilesRestored >= 1, "expected controller profile restored")
        let restored = try expectNotNil(dstMgr.load().first)
        try expectEqual(restored.perfProfile, .ultra)
        try expectEqual(restored.upscaleMode, "quality")
        try expectEqual(restored.totalPlaySeconds, 7200)
        try expectEqual(ControllerMappingManager.storedProfile(for: added.id)?.preset, .nintendoSwap)

        // Second import without --overwrite must skip existing entry
        let summary2 = try dstMgr.importBackup(from: backupFile, overwriteExisting: false)
        try expectEqual(summary2.added, 0)
        try expectEqual(summary2.skipped, 1)

        // Import with --overwrite must update existing entry
        let summary3 = try dstMgr.importBackup(from: backupFile, overwriteExisting: true)
        try expectEqual(summary3.updated, 1)
    }

    private static func testFPSCapEnvironmentAndClamping() throws {
        // Entry clamping & tolerant decoding
        let eHigh = GameLibraryEntry(title: "Cap", exePath: "/Games/Cap.exe", prefixName: "cap", fpsCap: 999)
        let eNeg = GameLibraryEntry(title: "Neg", exePath: "/Games/Neg.exe", prefixName: "neg", fpsCap: -20)
        try expectEqual(eHigh.fpsCap, 360)
        try expectEqual(eNeg.fpsCap, 0)

        let uncapped = RuntimeLauncher.fpsCapEnvironmentAndConfig(fpsCap: 0, existingEnv: [:])
        try expect(uncapped.env.isEmpty && uncapped.mullionConfig.isEmpty, "0 FPS cap should emit no overrides")

        let capped = RuntimeLauncher.fpsCapEnvironmentAndConfig(fpsCap: 40, existingEnv: [:])
        try expectEqual(capped.env["DXMT_FRAME_RATE_CAP"], "40")
        try expectEqual(capped.env["DXVK_FRAME_RATE"], "40")
        try expectEqual(capped.mullionConfig, ["dxgi.maxFrameRate=40"])

        // User-exported env vars must win
        let withUser = RuntimeLauncher.fpsCapEnvironmentAndConfig(
            fpsCap: 60,
            existingEnv: ["DXVK_FRAME_RATE": "120"]
        )
        try expectNil(withUser.env["DXVK_FRAME_RATE"], "explicit user DXVK_FRAME_RATE should not be overwritten")
        try expectEqual(withUser.env["DXMT_FRAME_RATE_CAP"], "60")
        try expectEqual(withUser.mullionConfig, ["dxgi.maxFrameRate=60"])
    }

    private static func testCustomEnvParsingAndMerging() throws {
        let parsed = GameLibraryManager.parseCustomEnv(
            #"DXVK_ASYNC=1 WINEDLLOVERRIDES="version=n,b" WINEPREFIX=/evil DYLD_INSERT_LIBRARIES=/bad.dylib 123BAD=x LC_ALL=ja_JP.UTF-8"#
        )
        try expectEqual(parsed["DXVK_ASYNC"], "1")
        try expectEqual(parsed["WINEDLLOVERRIDES"], "version=n,b")
        try expectEqual(parsed["LC_ALL"], "ja_JP.UTF-8")
        try expectNil(parsed["WINEPREFIX"], "WINEPREFIX must be blocked in customEnv")
        try expectNil(parsed["DYLD_INSERT_LIBRARIES"], "DYLD_INSERT_LIBRARIES must be blocked in customEnv")
        try expectNil(parsed["123BAD"], "invalid POSIX env key must be ignored")

        var env: [String: String] = ["WINEDLLOVERRIDES": "d3d12=n"]
        RuntimeLauncher.applyCustomEnv(parsed, to: &env)
        try expectEqual(env["WINEDLLOVERRIDES"], "d3d12=n;version=n,b", "WINEDLLOVERRIDES must append rather than clobber d3d12=n")
        try expectEqual(env["DXVK_ASYNC"], "1")
        try expectEqual(env["LC_ALL"], "ja_JP.UTF-8")
    }
}
