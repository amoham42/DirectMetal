import AppKit
import Foundation
import SwiftUI

// Shader Cache Maintenance & Apple Silicon Benchmark tabs for SystemHealthSheet.
// Provides local Shader Cache inspection/pruning/Finder reveal and on-device Apple Silicon
// microbenchmark execution with Markdown scorecard export.

// MARK: - Models & Markdown export

extension BenchmarkScorecard {
    /// Generates a GitHub-ready Markdown scorecard matching `DirectMetal bench --markdown`.
    func markdownReport() -> String {
        let metalTier = supportsMetal4 ? "Metal 4" : "Metal 3"
        var lines: [String] = [
            "### DirectMetal Apple Silicon Benchmark (`v\(appVersion)`)",
            "- **GPU:** `\(gpuName)` (`\(gpuFamily)`, `\(String(format: "%.1f", workingSetGiB)) GiB` UMA, `\(metalTier)`)",
            "- **macOS:** `\(macosVersion)` (`\(macosBuild)`)",
            "",
            "| Subsystem | Result | Details |",
            "| :--- | ---: | :--- |",
        ]
        for m in metrics {
            let safeDetail = m.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| **\(m.label)** | **`\(m.value) \(m.unit)`** | \(safeDetail) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

struct ShaderCacheSnapshot: Sendable {
    let rootPath: String
    let hostCacheKey: String
    let entries: [ShaderCacheLocalEntry]
    let totalBytes: UInt64
    let totalFiles: Int
    let staleCount: Int
    let reclaimableBytes: UInt64
    let reclaimableFiles: Int
}

struct CacheBannerNotice: Equatable {
    let message: String
    let isError: Bool
}

// MARK: - Shader Cache probe (off-main-thread work)

enum ShaderCacheProbe {
    /// Reads local shader cache entries and computes stale reclaimable space via dry-run prune.
    static func loadShaderCaches() -> ShaderCacheSnapshot {
        let root = RuntimeLauncher.shaderCacheRoot()
        let hostKey = RuntimeLauncher.queryHardwareInfo().cacheKey
        let entries = ShaderCacheManager.listLocalCaches(cacheRoot: root, currentCacheKey: hostKey)
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let totalFiles = entries.reduce(0) { $0 + $1.fileCount }
        let preview = try? ShaderCacheManager.pruneStaleCaches(
            dryRun: true,
            cacheRoot: root,
            currentCacheKey: hostKey
        )
        return ShaderCacheSnapshot(
            rootPath: root.path,
            hostCacheKey: hostKey,
            entries: entries,
            totalBytes: totalBytes,
            totalFiles: totalFiles,
            staleCount: preview?.removedEntries.count ?? 0,
            reclaimableBytes: preview?.reclaimedBytes ?? 0,
            reclaimableFiles: preview?.reclaimedFiles ?? 0
        )
    }

    static func loadShaderCachesAsync(completion: @escaping (ShaderCacheSnapshot) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = loadShaderCaches()
            DispatchQueue.main.async {
                completion(snap)
            }
        }
    }
}

// MARK: - Shader Cache Maintenance tab

struct ShaderCacheMaintenanceTab: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Binding var cacheSnapshot: ShaderCacheSnapshot?
    @Binding var isLoadingCaches: Bool
    @Binding var isPruningCaches: Bool
    @Binding var cacheBanner: CacheBannerNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cacheSummaryHeader
                .padding(.horizontal, 22)
                .padding(.top, 14)

            if let banner = cacheBanner {
                HStack(spacing: 8) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Color.orange : Color.green)
                    Text(banner.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        cacheBanner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (banner.isError ? Color.orange : Color.green).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((banner.isError ? Color.orange : Color.green).opacity(0.3))
                )
                .padding(.horizontal, 22)
            }

            if isLoadingCaches && cacheSnapshot == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning local Metal shader caches…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snap = cacheSnapshot, !snap.entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snap.entries) { entry in
                            ShaderCacheEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("No Local Shader Caches Yet")
                        .font(.headline)
                    Text("Compiled Metal shader pipelines will appear here after you launch a game or import a verified .dmcache.tar.gz archive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var cacheSummaryHeader: some View {
        let totalMiB = formatMiB(cacheSnapshot?.totalBytes ?? 0)
        let reclaimableMiB = formatMiB(cacheSnapshot?.reclaimableBytes ?? 0)
        let entryCount = cacheSnapshot?.entries.count ?? 0
        let totalFiles = cacheSnapshot?.totalFiles ?? 0
        let staleCount = cacheSnapshot?.staleCount ?? 0
        let hostKey = cacheSnapshot?.hostCacheKey ?? vm.gpuInfo.cacheKey

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(totalMiB) MiB")
                                .font(.title3.bold().monospacedDigit())
                            Text("across \(entryCount) director\(entryCount == 1 ? "y" : "ies") (\(totalFiles) file\(totalFiles == 1 ? "" : "s"))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if staleCount > 0 {
                            Label(
                                "\(reclaimableMiB) MiB reclaimable from \(staleCount) stale macOS build cache\(staleCount == 1 ? "" : "s")",
                                systemImage: "sparkles"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        } else {
                            Label(
                                "0.00 MiB reclaimable — no stale macOS build caches",
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        refreshShaderCaches()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(isLoadingCaches || isPruningCaches)
                    .help("Rescan local shader cache directories")
                }

                HStack(spacing: 8) {
                    Button {
                        pruneStaleCaches()
                    } label: {
                        if isPruningCaches {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("Pruning…")
                            }
                        } else {
                            Label("Prune Stale Builds", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(staleCount == 0 || isPruningCaches || isLoadingCaches)
                    .help(staleCount == 0
                          ? "No stale macOS build caches to prune"
                          : "Remove \(staleCount) stale build cache\(staleCount == 1 ? "" : "s") (\(reclaimableMiB) MiB); current and generic caches are kept")

                    Button {
                        revealShaderCacheInFinder()
                    } label: {
                        Label("Reveal Folder in Finder", systemImage: "folder")
                    }
                    .help("Open the DirectMetal shader cache directory in Finder")

                    Spacer(minLength: 8)

                    Text("Host key: \(hostKey)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        }
    }

    private func refreshShaderCaches() {
        guard !isLoadingCaches else { return }
        isLoadingCaches = true
        ShaderCacheProbe.loadShaderCachesAsync { snap in
            self.cacheSnapshot = snap
            self.isLoadingCaches = false
            self.vm.refreshShaderCache()
        }
    }

    private func pruneStaleCaches() {
        guard !isPruningCaches else { return }
        isPruningCaches = true
        cacheBanner = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try ShaderCacheManager.pruneStaleCaches(dryRun: false)
                let updated = ShaderCacheProbe.loadShaderCaches()
                let mib = String(format: "%.2f", Double(res.reclaimedBytes) / (1024.0 * 1024.0))
                let count = res.removedEntries.count
                let msg = count > 0
                    ? "Pruned \(count) stale build cache\(count == 1 ? "" : "s") (\(res.reclaimedFiles) file\(res.reclaimedFiles == 1 ? "" : "s")), reclaiming \(mib) MiB."
                    : "No stale build caches needed pruning."
                DispatchQueue.main.async {
                    self.cacheSnapshot = updated
                    self.isPruningCaches = false
                    self.cacheBanner = CacheBannerNotice(message: msg, isError: false)
                    self.vm.refreshShaderCache()
                    self.vm.statusMessage = msg
                }
            } catch {
                let msg = "Failed to prune stale shader caches: \(error.localizedDescription)"
                let updated = ShaderCacheProbe.loadShaderCaches()
                DispatchQueue.main.async {
                    self.cacheSnapshot = updated
                    self.isPruningCaches = false
                    self.cacheBanner = CacheBannerNotice(message: msg, isError: true)
                    self.vm.refreshShaderCache()
                }
            }
        }
    }

    private func revealShaderCacheInFinder() {
        let root = RuntimeLauncher.shaderCacheRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func formatMiB(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / (1024.0 * 1024.0))
    }
}

// MARK: - Apple Silicon Benchmark tab

struct AppleSiliconBenchmarkTab: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Binding var benchmarkScorecard: BenchmarkScorecard?
    @Binding var isRunningBenchmark: Bool

    @State private var copiedBenchmark: Bool = false

    var body: some View {
        let gridColumns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]

        return VStack(alignment: .leading, spacing: 14) {
            benchmarkHeader
                .padding(.horizontal, 22)
                .padding(.top, 14)

            if isRunningBenchmark && benchmarkScorecard == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Running on-device Apple Silicon microbenchmarks…")
                        .font(.callout.weight(.medium))
                    Text("Measuring Metal UMA compute bandwidth, APFS CoW clonefile(2), CryptoKit SHA-256 & PE32+ cache (~1 s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let card = benchmarkScorecard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(card.metrics, id: \.id) { metric in
                                BenchmarkMetricCard(metric: metric)
                            }
                        }
                        .opacity(isRunningBenchmark ? 0.6 : 1.0)
                        .overlay {
                            if isRunningBenchmark {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Running benchmark…")
                                        .font(.callout.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(Color.secondary.opacity(0.2))
                                )
                            }
                        }

                        BenchmarkHostFooter(card: card)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Ready to Benchmark This Mac")
                        .font(.headline)
                    Text("Click Run Benchmark to measure Metal UMA zero-copy bandwidth, APFS CoW clone latency, ARMv8 SHA-256 speed, and cached PE32+ inspection in ~1 second.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var benchmarkHeader: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("On-Device Apple Silicon Microbenchmarks", systemImage: "speedometer")
                        .font(.headline)
                    Text("Measures Metal UMA zero-copy compute bandwidth, APFS CoW clonefile(2) latency, ARMv8 CryptoKit SHA-256 verification speed, and cached PE32+ inspection latency — runs in ~1 second with no external binaries.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        runBenchmark()
                    } label: {
                        if isRunningBenchmark {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Running…")
                            }
                        } else {
                            Label("Run Benchmark", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningBenchmark)
                    .help("Run all 4 on-device Apple Silicon microbenchmarks (~1 second)")

                    Button {
                        copyBenchmarkMarkdown()
                    } label: {
                        Label(
                            copiedBenchmark ? "Copied" : "Copy Markdown Scorecard",
                            systemImage: copiedBenchmark ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(benchmarkScorecard == nil || isRunningBenchmark)
                    .help("Copy a GitHub-ready Markdown scorecard matching `DirectMetal bench --markdown`")

                    Spacer(minLength: 8)

                    if let card = benchmarkScorecard {
                        Text("v\(card.appVersion) · \(card.metrics.count) metrics")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(6)
        }
    }

    private func runBenchmark() {
        guard !isRunningBenchmark else { return }
        isRunningBenchmark = true
        copiedBenchmark = false
        DispatchQueue.global(qos: .userInitiated).async {
            let card = DirectMetalBenchmark.runAll()
            DispatchQueue.main.async {
                self.benchmarkScorecard = card
                self.isRunningBenchmark = false
                self.vm.statusMessage = "Completed Apple Silicon benchmark scorecard (\(card.metrics.count) subsystems)."
            }
        }
    }

    private func copyBenchmarkMarkdown() {
        guard let card = benchmarkScorecard else { return }
        let report = card.markdownReport()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        vm.statusMessage = "Copied Apple Silicon benchmark scorecard Markdown."
        withAnimation { copiedBenchmark = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { copiedBenchmark = false }
        }
    }
}

// MARK: - Subviews

private struct ShaderCacheEntryRow: View {
    let entry: ShaderCacheLocalEntry

    private var badge: (label: String, color: Color) {
        if !entry.isKnownKeyedEntry {
            return ("Generic", .secondary)
        }
        return entry.matchesHostCacheKey ? ("Current", .green) : ("Stale Build", .orange)
    }

    var body: some View {
        let mib = String(format: "%.2f MiB", Double(entry.totalBytes) / (1024.0 * 1024.0))
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(badge.color.opacity(0.85))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Text(mib)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)

            Text(badge.label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .foregroundStyle(badge.color)
                .background(badge.color.opacity(0.14), in: Capsule())
                .frame(minWidth: 74, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
        .help(entry.path)
    }
}

private struct BenchmarkMetricCard: View {
    let metric: BenchmarkMetric

    private var visualStyle: (icon: String, tint: Color) {
        switch metric.id {
        case "metal_uma_bandwidth":
            return ("memorychip", .blue)
        case "apfs_cow_clone":
            return ("doc.on.doc.fill", .purple)
        case "sha256_verify_throughput":
            return ("checkmark.shield.fill", .green)
        case "pe_inspector_cached":
            return ("bolt.fill", .orange)
        default:
            return ("speedometer", .accentColor)
        }
    }

    var body: some View {
        let style = visualStyle
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: style.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 26, height: 26)
                    .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(metric.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(metric.value) \(metric.unit)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            Text(metric.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
        )
    }
}

private struct BenchmarkHostFooter: View {
    let card: BenchmarkScorecard

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(card.gpuName) (\(card.gpuFamily))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text("\(String(format: "%.1f", card.workingSetGiB)) GiB UMA · \(card.supportsMetal4 ? "Metal 4" : "Metal 3")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("macOS \(card.macosVersion) (\(card.macosBuild))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
    }
}
