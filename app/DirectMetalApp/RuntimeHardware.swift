import Foundation
import Metal
import MetalFX

struct MetalHardwareInfo: Codable {
    let gpuName: String
    let gpuFamily: String
    let macosVersion: String
    let macosBuild: String
    let cacheKey: String
    let workingSetGiB: Double
    let hasUnifiedMemory: Bool
    let supportsMetal3: Bool
    let supportsMetal4: Bool
    let supportsRaytracing: Bool
    let supportsMetalFXSpatial: Bool
    let supportsMetalFXTemporal: Bool
    let supportsMetal4FX: Bool
}

struct ShaderCacheSummary: Codable {
    let rootPath: String
    let entryCount: Int
    let fileCount: Int
    let totalBytes: UInt64
    let entries: [String]
}

enum ExecutionEngine: String, Codable {
    case auto
    case arm64ec
    case rosetta
}

enum DX9Backend: String, Codable {
    case auto
    case dxvk
    case wined3d
}

enum PerfProfile: String, Codable {
    case balanced
    case ultra
}

struct RuntimePaths {
    let runtimeRoot: URL
    let wineBin: URL?
    let wineserverBin: URL?
    let basePrefix: URL?
    let mullionConfig: URL?
    let vkCompatLayerDir: URL?
    let arm64ecRoot: URL?
    let arm64ecWineBin: URL?
    let arm64ecWineserverBin: URL?
    let arm64ecBasePrefix: URL?
    let arm64ecKosmicKrispICD: URL?
}

struct LaunchResult {
    let exitCode: Int32
    let elapsedSeconds: Double
    let prefixPath: String
    let cloneMs: Double
    let shaderCacheDir: String
    let activeEngine: String
    let sandboxed: Bool
}

enum LauncherError: Error, CustomStringConvertible {
    case runtimeNotFound(String)
    case executableNotFound(String)

    var description: String {
        switch self {
        case .runtimeNotFound(let m), .executableNotFound(let m):
            return m
        }
    }
}

extension RuntimeLauncher {
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    /// GPU family, Metal 4 / MetalFX capabilities and the macOS build never change during a process
    /// lifetime: probe once (MTLDevice creation + sysctl) and reuse everywhere (GUI, CLI, shader cache, launch).
    static let cachedHardwareInfo: MetalHardwareInfo = probeHardwareInfo()

    static func queryHardwareInfo() -> MetalHardwareInfo {
        return cachedHardwareInfo
    }

    private static func queryMetal4FXSupport(_ descriptorClass: AnyClass, device: MTLDevice) -> Bool {
        let sel = NSSelectorFromString("supportsMetal4FX:")
        guard let method = class_getClassMethod(descriptorClass, sel) else { return false }
        typealias SupportsM4FXFn = @convention(c) (AnyClass, Selector, MTLDevice) -> ObjCBool
        let fn = unsafeBitCast(method_getImplementation(method), to: SupportsM4FXFn.self)
        return fn(descriptorClass, sel, device).boolValue
    }

    private static func probeHardwareInfo() -> MetalHardwareInfo {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let buildStr = sysctlString("kern.osversion")

        guard let dev = MTLCreateSystemDefaultDevice() else {
            return MetalHardwareInfo(
                gpuName: "Unavailable",
                gpuFamily: "Unknown",
                macosVersion: osStr,
                macosBuild: buildStr,
                cacheKey: "unknown_\(buildStr)",
                workingSetGiB: 0.0,
                hasUnifiedMemory: false,
                supportsMetal3: false,
                supportsMetal4: false,
                supportsRaytracing: false,
                supportsMetalFXSpatial: false,
                supportsMetalFXTemporal: false,
                supportsMetal4FX: false
            )
        }

        let apple10Family = MTLGPUFamily(rawValue: 1010)
        let metal4Family = MTLGPUFamily(rawValue: 5002)

        let family: String
        if let f10 = apple10Family, dev.supportsFamily(f10) {
            family = "Apple10"
        } else if dev.supportsFamily(.apple9) {
            family = "Apple9"
        } else if dev.supportsFamily(.apple8) {
            family = "Apple8"
        } else if dev.supportsFamily(.apple7) {
            family = "Apple7"
        } else {
            family = "Mac2"
        }

        let m3 = dev.supportsFamily(.metal3)
        var m4 = false
        var m4fx = false
        if #available(macOS 26.0, *) {
            if let fm4 = metal4Family {
                m4 = dev.supportsFamily(fm4)
            }
            m4fx = Self.queryMetal4FXSupport(MTLFXSpatialScalerDescriptor.self, device: dev) &&
                   Self.queryMetal4FXSupport(MTLFXTemporalScalerDescriptor.self, device: dev)
        }

        let cacheKey = "\(family.lowercased())_\(buildStr)"
        let workingGiB = Double(dev.recommendedMaxWorkingSetSize) / (1024.0 * 1024.0 * 1024.0)

        return MetalHardwareInfo(
            gpuName: dev.name,
            gpuFamily: family,
            macosVersion: osStr,
            macosBuild: buildStr,
            cacheKey: cacheKey,
            workingSetGiB: workingGiB,
            hasUnifiedMemory: dev.hasUnifiedMemory,
            supportsMetal3: m3,
            supportsMetal4: m4,
            supportsRaytracing: dev.supportsRaytracing,
            supportsMetalFXSpatial: MTLFXSpatialScalerDescriptor.supportsDevice(dev),
            supportsMetalFXTemporal: MTLFXTemporalScalerDescriptor.supportsDevice(dev),
            supportsMetal4FX: m4fx
        )
    }

    /// Marketing version of the running app (`CFBundleShortVersionString`), `1.0.1` for bare CLI builds.
    static func appVersion() -> String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v! : "1.0.1"
    }

    static func shaderCacheRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["DIRECTMETAL_SHADER_CACHE_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("DirectMetal/Shaders", isDirectory: true)
    }

    static func queryShaderCache() -> ShaderCacheSummary {
        let fm = FileManager.default
        let root = shaderCacheRoot()
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ShaderCacheSummary(rootPath: root.path, entryCount: 0, fileCount: 0, totalBytes: 0, entries: [])
        }
        var entries: [String] = []
        var fileCount = 0
        var totalBytes: UInt64 = 0
        for item in top {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { entries.append(item.lastPathComponent) }
        }
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in enumerator {
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if vals?.isRegularFile == true {
                    fileCount += 1
                    totalBytes += UInt64(vals?.fileSize ?? 0)
                }
            }
        }
        return ShaderCacheSummary(
            rootPath: root.path,
            entryCount: entries.count,
            fileCount: fileCount,
            totalBytes: totalBytes,
            entries: entries.sorted()
        )
    }

    static func clearShaderCache() throws {
        let fm = FileManager.default
        let root = shaderCacheRoot()
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }
}
