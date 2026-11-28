import CryptoKit
import Darwin
import Foundation
import Metal

// MARK: - Built-in Apple Silicon Microbenchmark Scorecard (`DirectMetal bench`)

struct BenchmarkMetric: Codable {
    let id: String
    let label: String
    let value: Double
    let unit: String
    let detail: String
}

struct BenchmarkScorecard: Codable {
    let schema: String
    let appVersion: String
    let timestampUtc: String
    let gpuName: String
    let gpuFamily: String
    let macosVersion: String
    let macosBuild: String
    let workingSetGiB: Double
    let supportsMetal4: Bool
    let metrics: [BenchmarkMetric]
}

enum DirectMetalBenchmark {
    /// 1. Metal UMA Zero-Copy Compute Bandwidth (`MTLStorageModeShared` buffer stream).
    static func runMetalUMABenchmark() -> BenchmarkMetric {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return BenchmarkMetric(
                id: "metal_uma_bandwidth",
                label: "Metal UMA Compute Bandwidth",
                value: 0,
                unit: "GB/s",
                detail: "Metal device unavailable"
            )
        }

        let mslSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void dm_uma_fma(
            device const float4* a [[buffer(0)]],
            device const float4* b [[buffer(1)]],
            device float4* out     [[buffer(2)]],
            uint gid [[thread_position_in_grid]]
        ) {
            out[gid] = fma(a[gid], float4(1.0005f), b[gid]);
        }
        """

        guard let library = try? device.makeLibrary(source: mslSource, options: nil),
              let fn = library.makeFunction(name: "dm_uma_fma"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else {
            return BenchmarkMetric(
                id: "metal_uma_bandwidth",
                label: "Metal UMA Compute Bandwidth",
                value: 0,
                unit: "GB/s",
                detail: "Failed to compile MSL compute pipeline"
            )
        }

        // 1,048,576 float4 elements = 16 MiB per buffer (48 MiB read+read+write per pass)
        let count = 1 << 20
        let byteLength = count * MemoryLayout<SIMD4<Float>>.stride
        guard let bufA = device.makeBuffer(length: byteLength, options: .storageModeShared),
              let bufB = device.makeBuffer(length: byteLength, options: .storageModeShared),
              let bufOut = device.makeBuffer(length: byteLength, options: .storageModeShared) else {
            return BenchmarkMetric(
                id: "metal_uma_bandwidth",
                label: "Metal UMA Compute Bandwidth",
                value: 0,
                unit: "GB/s",
                detail: "Failed to allocate shared UMA buffers"
            )
        }

        let ptrA = bufA.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let ptrB = bufB.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        ptrA[0] = SIMD4<Float>(1, 2, 3, 4)
        ptrB[0] = SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
        ptrA[count - 1] = SIMD4<Float>(2, 4, 6, 8)
        ptrB[count - 1] = SIMD4<Float>(1, 1, 1, 1)

        let tgWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let gridSize = MTLSize(width: count, height: 1, depth: 1)
        let tgSize = MTLSize(width: tgWidth, height: 1, depth: 1)

        func dispatchOne() {
            guard let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(bufA, offset: 0, index: 0)
            enc.setBuffer(bufB, offset: 0, index: 1)
            enc.setBuffer(bufOut, offset: 0, index: 2)
            enc.dispatchThreads(gridSize, threadsPerThreadgroup: tgSize)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }

        // 2 warmup passes + 12 timed passes
        dispatchOne()
        dispatchOne()

        let passes = 12
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes {
            dispatchOne()
        }
        let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000.0

        // Spot-check zero-copy UMA result directly on CPU
        let ptrOut = bufOut.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let checkOK = abs(ptrOut[0].x - 1.5005) < 1e-3 && abs(ptrOut[count - 1].w - 9.004) < 1e-2

        let totalBytes = Double(byteLength * 3 * passes)
        let gbps = elapsedSec > 0 ? (totalBytes / 1_000_000_000.0) / elapsedSec : 0
        let avgMs = (elapsedSec * 1000.0) / Double(passes)
        return BenchmarkMetric(
            id: "metal_uma_bandwidth",
            label: "Metal UMA Compute Bandwidth",
            value: (gbps * 10.0).rounded() / 10.0,
            unit: "GB/s",
            detail: String(format: "%.2f ms/pass (48 MiB/pass, verified=%@)", avgMs, checkOK ? "ok" : "mismatch")
        )
    }

    /// 2. APFS Copy-on-Write `clonefile(2)` prefix-tree clone latency.
    static func runAPFSCloneBenchmark() -> BenchmarkMetric {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dm_bench_cow_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            let src = root.appendingPathComponent("golden_prefix", isDirectory: true)
            let sys32 = src.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
            try fm.createDirectory(at: sys32, withIntermediateDirectories: true)
            let payload = Data(repeating: 0x5A, count: 4096)
            for i in 0..<48 {
                try payload.write(to: sys32.appendingPathComponent("dll_\(i).dll"))
            }
            var times: [Double] = []
            for run in 0..<5 {
                let dst = root.appendingPathComponent("clone_\(run)", isDirectory: true)
                let ms = try PrefixManager.cloneTree(from: src, to: dst)
                times.append(ms)
            }
            times.sort()
            let median = times[times.count / 2]
            return BenchmarkMetric(
                id: "apfs_cow_clone",
                label: "APFS CoW Prefix Clone",
                value: (median * 1000.0).rounded() / 1000.0,
                unit: "ms",
                detail: String(format: "median of 5 clones (48 files, min %.3f ms)", times.first ?? median)
            )
        } catch {
            return BenchmarkMetric(
                id: "apfs_cow_clone",
                label: "APFS CoW Prefix Clone",
                value: 0,
                unit: "ms",
                detail: "failed: \(error)"
            )
        }
    }

    /// 3. ARMv8 Hardware CryptoKit SHA-256 verification throughput (32 MiB stream).
    static func runSHA256Benchmark() -> BenchmarkMetric {
        let totalBytes = 32 * 1024 * 1024
        let chunkSize = 256 * 1024
        let chunk = Data((0..<chunkSize).map { UInt8($0 & 0xFF) })
        let iterations = totalBytes / chunkSize

        let t0 = DispatchTime.now().uptimeNanoseconds
        var hasher = SHA256()
        for _ in 0..<iterations {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000.0
        let mbps = elapsedSec > 0 ? (Double(totalBytes) / (1024.0 * 1024.0)) / elapsedSec : 0
        let hexPrefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return BenchmarkMetric(
            id: "sha256_verify_throughput",
            label: "SHA-256 Verification Speed",
            value: (mbps * 10.0).rounded() / 10.0,
            unit: "MiB/s",
            detail: String(format: "32 MiB in %.1f ms (digest %@…)", elapsedSec * 1000.0, hexPrefix)
        )
    }

    /// 4. `PEInspector` stat-cached lookup speed on a synthetic PE32+ executable.
    static func runPEInspectorBenchmark() -> BenchmarkMetric {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dm_bench_pe_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let exe = root.appendingPathComponent("bench_game.exe")
            // Minimal valid PE32+ binary (512 bytes)
            var buf = Data(repeating: 0, count: 512)
            buf[0] = 0x4D; buf[1] = 0x5A // MZ
            buf[0x3C] = 0x40             // e_lfanew = 0x40
            buf[0x40] = 0x50; buf[0x41] = 0x45 // PE\0\0
            buf[0x44] = 0x64; buf[0x45] = 0x86 // x86_64
            buf[0x46] = 0x00                   // 0 sections
            buf[0x54] = 0xF0                   // SizeOfOptionalHeader = 240
            buf[0x58] = 0x0B; buf[0x59] = 0x02 // PE32+ magic
            try buf.write(to: exe)

            // Warm cache once, then measure 50 stat-validated cached lookups
            _ = try PEInspector.inspect(exePath: exe.path)
            let runs = 50
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs {
                _ = try PEInspector.inspect(exePath: exe.path)
            }
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000.0
            let perCallUs = elapsedUs / Double(runs)
            return BenchmarkMetric(
                id: "pe_inspector_cached",
                label: "PE32+ Cached Inspection",
                value: (perCallUs * 10.0).rounded() / 10.0,
                unit: "us/call",
                detail: "mean of \(runs) stat-validated cache hits"
            )
        } catch {
            return BenchmarkMetric(
                id: "pe_inspector_cached",
                label: "PE32+ Cached Inspection",
                value: 0,
                unit: "us/call",
                detail: "failed: \(error)"
            )
        }
    }

    static func runAll() -> BenchmarkScorecard {
        let hw = RuntimeLauncher.queryHardwareInfo()
        let metrics = [
            runMetalUMABenchmark(),
            runAPFSCloneBenchmark(),
            runSHA256Benchmark(),
            runPEInspectorBenchmark(),
        ]
        return BenchmarkScorecard(
            schema: "directmetal.bench.v1",
            appVersion: RuntimeLauncher.appVersion(),
            timestampUtc: ISO8601DateFormatter().string(from: Date()),
            gpuName: hw.gpuName,
            gpuFamily: hw.gpuFamily,
            macosVersion: hw.macosVersion,
            macosBuild: hw.macosBuild,
            workingSetGiB: (hw.workingSetGiB * 100.0).rounded() / 100.0,
            supportsMetal4: hw.supportsMetal4,
            metrics: metrics
        )
    }
}

func runBenchmarkCLI(args: [String]) -> Int32 {
    let asJSON = args.contains("--json")
    let asMarkdown = args.contains("--markdown") || args.contains("--md")
    let card = DirectMetalBenchmark.runAll()

    if asJSON {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(card), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        return 0
    }

    if asMarkdown {
        print("### DirectMetal Apple Silicon Benchmark (`v\(card.appVersion)`)")
        print("- **GPU:** `\(card.gpuName)` (`\(card.gpuFamily)`, `\(String(format: "%.1f", card.workingSetGiB)) GiB` UMA, `\(card.supportsMetal4 ? "Metal 4" : "Metal 3")`)")
        print("- **macOS:** `\(card.macosVersion)` (`\(card.macosBuild)`)")
        print("")
        print("| Subsystem | Result | Details |")
        print("| :--- | ---: | :--- |")
        for m in card.metrics {
            print("| **\(m.label)** | **`\(m.value) \(m.unit)`** | \(m.detail) |")
        }
        return 0
    }

    print("DirectMetal Apple Silicon Benchmark (v\(card.appVersion))")
    print("Host: \(card.gpuName) (\(card.gpuFamily), \(String(format: "%.1f", card.workingSetGiB)) GiB UMA) · macOS \(card.macosVersion) (\(card.macosBuild))")
    print(String(repeating: "-", count: 74))
    for m in card.metrics {
        let lbl = m.label.padding(toLength: 30, withPad: " ", startingAt: 0)
        let val = "\(m.value) \(m.unit)".padding(toLength: 16, withPad: " ", startingAt: 0)
        print("\(lbl)  \(val)  \(m.detail)")
    }
    return 0
}
