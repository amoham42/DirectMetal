import AppKit
import Foundation
import SwiftUI

// System Health & Shader Cache Maintenance Sheet.
// Provides live 9-point System Doctor diagnostics (off main thread) with Markdown export
// and local Shader Cache inspection, stale-build pruning, and Finder reveal.

// MARK: - Models

enum SystemHealthTab: String, CaseIterable, Identifiable {
    case doctor = "System Doctor"
    case shaderCache = "Shader Cache"

    var id: String { rawValue }
}

enum DoctorCheckSeverity: String, Sendable {
    case ok
    case warn
    case fail

    var iconName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    var tag: String {
        switch self {
        case .ok: return "OK"
        case .warn: return "WARN"
        case .fail: return "FAIL"
        }
    }
}

struct DoctorCheckItem: Identifiable, Sendable {
    let id: String
    let title: String
    let severity: DoctorCheckSeverity
    let summary: String
    let remediation: String?
}

struct DoctorSnapshot: Sendable {
    let appVersion: String
    let capturedAt: Date
    let checks: [DoctorCheckItem]

    var passedCount: Int { checks.filter { $0.severity == .ok }.count }
    var warningCount: Int { checks.filter { $0.severity == .warn }.count }
    var failureCount: Int { checks.filter { $0.severity == .fail }.count }

    var overallSeverity: DoctorCheckSeverity {
        if failureCount > 0 { return .fail }
        if warningCount > 0 { return .warn }
        return .ok
    }

    var overallLabel: String {
        if failureCount > 0 {
            return "\(failureCount) failure\(failureCount == 1 ? "" : "s")"
        }
        if warningCount > 0 {
            return "\(passedCount)/\(checks.count) ok · \(warningCount) warning\(warningCount == 1 ? "" : "s")"
        }
        return "All \(checks.count) checks passed"
    }

    /// Generates a GitHub-ready Markdown diagnostics report with `$HOME` redacted to `~`.
    func markdownReport(home: String = NSHomeDirectory()) -> String {
        let redact: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        let ts = GameLibraryManager.isoFormatter.string(from: capturedAt)
        var lines: [String] = [
            "### DirectMetal System Diagnostics (v\(appVersion))",
            "",
            "- **Captured:** \(ts)",
            "- **Summary:** \(passedCount) ok, \(warningCount) warning(s), \(failureCount) failure(s) (`\(overallSeverity.tag)`)",
            "",
            "| Status | Check | Details |",
            "| :--- | :--- | :--- |",
        ]
        for check in checks {
            let safeSummary = redact(check.summary).replacingOccurrences(of: "|", with: "\\|")
            var detail = safeSummary
            if let rem = check.remediation, !rem.isEmpty {
                let safeRem = redact(rem).replacingOccurrences(of: "|", with: "\\|")
                detail += "<br>_Hint: \(safeRem)_"
            }
            lines.append("| `\(check.severity.tag)` | **\(check.title)** | \(detail) |")
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

// MARK: - Diagnostics & cache runners (off-main-thread work)

private enum SystemHealthProbe {
    /// Runs the 9-point read-only diagnostics off the main thread.
    /// Display & controller snapshots are captured on `@MainActor` first so AppKit HDR/ProMotion
    /// telemetry is preserved without touching UI APIs from a background queue.
    static func runDoctor(
        display: DisplayCapabilities,
        controllers: [ConnectedControllerInfo]
    ) -> DoctorSnapshot {
        let fm = FileManager.default
        var checks: [DoctorCheckItem] = []

        // 1. GPU / Metal 3/4 + UMA working set
        let hw = RuntimeLauncher.queryHardwareInfo()
        if hw.hasUnifiedMemory && hw.supportsMetal3 {
            let metalTier = hw.supportsMetal4 ? "Metal 4" : "Metal 3"
            let fxLabel = hw.supportsMetal4FX ? "Metal 4 FX" : (hw.supportsMetalFXTemporal ? "MetalFX Temporal + Spatial" : "MetalFX Spatial")
            let rtLabel = hw.supportsRaytracing ? ", RT" : ""
            checks.append(DoctorCheckItem(
                id: "gpu_metal",
                title: "Apple Silicon GPU & Metal",
                severity: .ok,
                summary: "\(hw.gpuName) (\(hw.gpuFamily), \(String(format: "%.1f", hw.workingSetGiB)) GiB UMA, \(metalTier) + \(fxLabel)\(rtLabel))",
                remediation: nil
            ))
        } else {
            checks.append(DoctorCheckItem(
                id: "gpu_metal",
                title: "Apple Silicon GPU & Metal",
                severity: .fail,
                summary: "Unsupported GPU (\(hw.gpuName) / \(hw.gpuFamily)) — Apple Silicon with Metal 3+ required",
                remediation: "Run DirectMetal on an Apple Silicon Mac (M1 or newer)."
            ))
        }

        // 2. macOS post-Rosetta tier
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let is26_4Plus = (osVer.majorVersion > 26) || (osVer.majorVersion == 26 && osVer.minorVersion >= 4)
        if is26_4Plus {
            checks.append(DoctorCheckItem(
                id: "macos_tier",
                title: "macOS Post-Rosetta Tier",
                severity: .ok,
                summary: "macOS \(hw.macosVersion) (\(hw.macosBuild)) — full 100% post-Rosetta 64-bit & 32-bit ARM64EC + FL 12_2",
                remediation: nil
            ))
        } else if osVer.majorVersion >= 15 {
            checks.append(DoctorCheckItem(
                id: "macos_tier",
                title: "macOS Post-Rosetta Tier",
                severity: .warn,
                summary: "macOS \(hw.macosVersion) (\(hw.macosBuild)) — 64-bit ARM64EC ready; 32-bit titles need --include-rosetta",
                remediation: "Upgrade to macOS 26.4+ for native 32-bit ARM64EC + Metal 4, or package with --include-rosetta."
            ))
        } else {
            checks.append(DoctorCheckItem(
                id: "macos_tier",
                title: "macOS Post-Rosetta Tier",
                severity: .fail,
                summary: "macOS \(hw.macosVersion) is below the macOS 15.0 Sequoia minimum",
                remediation: "Upgrade to macOS 15.0 Sequoia or newer."
            ))
        }

        // 3. ARM64EC runtime + codesign status
        let rtStatus = RuntimeManager.status(checkCodesign: true, measureDisk: false)
        if rtStatus.installed {
            let sigOK = rtStatus.codesignValid ?? true
            let sigText: String
            if let valid = rtStatus.codesignValid {
                sigText = valid ? "codesign valid" : "codesign unverified"
            } else {
                sigText = "codesign n/a"
            }
            checks.append(DoctorCheckItem(
                id: "arm64ec_runtime",
                title: "ARM64EC + FEX Runtime",
                severity: sigOK ? .ok : .warn,
                summary: "MetalSharp-Wine \(rtStatus.version) (\(rtStatus.source.rawValue), \(sigText))",
                remediation: sigOK ? nil : "Reinstall the runtime from Software Updates or run `DirectMetal runtime install --force`."
            ))
        } else {
            checks.append(DoctorCheckItem(
                id: "arm64ec_runtime",
                title: "ARM64EC + FEX Runtime",
                severity: .warn,
                summary: "ARM64EC runtime not installed yet (DirectMetal-Lite mode)",
                remediation: "Use the in-app installer card or run `DirectMetal runtime install`."
            ))
        }

        // 4. Bundled graphics layers & D3D12 placed-resource guard
        let resolved = try? RuntimeLauncher.resolveRuntimePaths()
        let bundled = RuntimeLauncher.resolveBundledResources(runtimeRoot: resolved?.runtimeRoot)
        let vkLayer = bundled.vkCompatLayerDir ?? resolved?.vkCompatLayerDir
        let mullionConf = bundled.mullionConfig ?? resolved?.mullionConfig
        let guardPaths: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("guards/d3d12_x64.dll"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/dm_d3d12_placed_guard/d3d12_x64.dll"),
        ].compactMap { $0 }
        let hasGuard = guardPaths.contains { fm.fileExists(atPath: $0.path) }
        if vkLayer != nil && (hasGuard || is26_4Plus) {
            let confText = mullionConf != nil ? "mullion.conf ready" : "mullion.conf default"
            checks.append(DoctorCheckItem(
                id: "graphics_layers",
                title: "Bundled Graphics Layers",
                severity: .ok,
                summary: "VK compat layer ready; \(confText); D3D12 guard \(hasGuard ? "bundled" : "native on macOS \(hw.macosVersion)")",
                remediation: nil
            ))
        } else {
            checks.append(DoctorCheckItem(
                id: "graphics_layers",
                title: "Bundled Graphics Layers",
                severity: .warn,
                summary: "VK compat layer=\(vkLayer != nil ? "ready" : "missing"), mullion.conf=\(mullionConf != nil ? "ready" : "missing"), D3D12 guard=\(hasGuard ? "bundled" : "missing")",
                remediation: "Rebuild with `make app-lite` or reinstall from an official DirectMetal DMG."
            ))
        }

        // 5. Base prefix readiness
        if let root = resolved?.arm64ecRoot {
            let unpacked = root.appendingPathComponent("\(BasePrefixHydrator.unpackedDirName)/system.reg")
            if fm.fileExists(atPath: unpacked.path) {
                checks.append(DoctorCheckItem(
                    id: "base_prefix",
                    title: "Base Prefix Readiness",
                    severity: .ok,
                    summary: "Golden ARM64EC base prefix ready (APFS CoW clones in ~0.4 ms)",
                    remediation: nil
                ))
            } else if let fp = try? BasePrefixHydrator.readFingerprint(runtimeRoot: root) {
                let hydrated = BasePrefixHydrator.hydratedDestination(fingerprint: fp)
                let ready = fm.fileExists(atPath: hydrated.appendingPathComponent(BasePrefixHydrator.markerFileName).path)
                checks.append(DoctorCheckItem(
                    id: "base_prefix",
                    title: "Base Prefix Readiness",
                    severity: .ok,
                    summary: ready
                        ? "Dehydrated base prefix hydrated (\(fp), zero-copy APFS ready)"
                        : "Dehydrated base prefix staged (\(fp); hydrates automatically in ~150 ms on first launch)",
                    remediation: nil
                ))
            } else {
                checks.append(DoctorCheckItem(
                    id: "base_prefix",
                    title: "Base Prefix Readiness",
                    severity: .warn,
                    summary: "Base prefix not initialized under \(LaunchDiagnostics.redactHome(root.path))",
                    remediation: "Reinstall the runtime via `DirectMetal runtime install --force`."
                ))
            }
        } else {
            checks.append(DoctorCheckItem(
                id: "base_prefix",
                title: "Base Prefix Readiness",
                severity: .warn,
                summary: "Waiting for ARM64EC runtime installation",
                remediation: "Install the MetalSharp-Wine runtime first."
            ))
        }

        // 6. Display Retina / ProMotion / HDR
        if display.displayAvailable {
            checks.append(DoctorCheckItem(
                id: "display",
                title: "Display (Retina / ProMotion / HDR)",
                severity: .ok,
                summary: "\(display.displayName) — \(display.resolutionLabel) (\(display.pixelWidth)×\(display.pixelHeight) px, \(display.dpi) DPI), \(display.refreshLabel), \(display.hdrLabel)",
                remediation: nil
            ))
        } else {
            checks.append(DoctorCheckItem(
                id: "display",
                title: "Display (Retina / ProMotion / HDR)",
                severity: .warn,
                summary: "No active GUI display detected (headless / SSH session)",
                remediation: nil
            ))
        }

        // 7. Shader Cache & Community Profiles
        let cache = RuntimeLauncher.queryShaderCache()
        let profiles = GameProfileRegistry.load()
        let cacheMiB = Double(cache.totalBytes) / (1024.0 * 1024.0)
        checks.append(DoctorCheckItem(
            id: "cache_and_profiles",
            title: "Shader Cache & Community Profiles",
            severity: profiles.profiles.isEmpty ? .warn : .ok,
            summary: String(
                format: "Shader cache: %d title%@ (%d file%@, %.2f MiB) · %d community profile%@ loaded",
                cache.entryCount, cache.entryCount == 1 ? "" : "s",
                cache.fileCount, cache.fileCount == 1 ? "" : "s",
                cacheMiB,
                profiles.profiles.count, profiles.profiles.count == 1 ? "" : "s"
            ),
            remediation: profiles.profiles.isEmpty ? "Re-package DirectMetal so runtime/profiles/game_profiles.json is bundled." : nil
        ))

        // 8. Connected Game Controllers
        let ctrlSummary: String
        if controllers.isEmpty {
            ctrlSummary = "No physical gamepads connected (SDL remapper ready)"
        } else {
            ctrlSummary = controllers.map(\.summary).joined(separator: " · ")
        }
        checks.append(DoctorCheckItem(
            id: "controllers",
            title: "Game Controllers (GCController)",
            severity: .ok,
            summary: ctrlSummary,
            remediation: nil
        ))

        // 9. Security / SIP / SSV / Secure Enclave
        let att = DirectMetalAttestation.collectStatus()
        let secOK = att.sipEnabled && att.ssvSealed && att.secureEnclaveAvailable
        checks.append(DoctorCheckItem(
            id: "security",
            title: "Security, SIP, SSV & Secure Enclave",
            severity: secOK ? .ok : .warn,
            summary: "SIP=\(att.sipEnabled ? "enabled" : "disabled"), SSV=\(att.ssvSealed ? "sealed" : "unsealed"), Secure Enclave=\(att.secureEnclaveAvailable ? "active" : "unavailable"), Hardened Runtime=\(att.hardenedRuntime ? "on" : "off"), DCAppAttest=\(att.dcAppAttestSupported ? "ready" : "unsupported")",
            remediation: secOK ? nil : "Keep SIP and Signed System Volume (SSV) enabled for full hardware-backed attestation."
        ))

        return DoctorSnapshot(
            appVersion: RuntimeLauncher.appVersion(),
            capturedAt: Date(),
            checks: checks
        )
    }

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
}

// MARK: - Sheet view

struct SystemHealthSheet: View {
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SystemHealthTab = .doctor

    // Doctor state
    @State private var doctorSnapshot: DoctorSnapshot?
    @State private var isRunningDoctor: Bool = false
    @State private var copiedDiagnostics: Bool = false

    // Shader cache state
    @State private var cacheSnapshot: ShaderCacheSnapshot?
    @State private var isLoadingCaches: Bool = false
    @State private var isPruningCaches: Bool = false
    @State private var cacheBanner: CacheBannerNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            Group {
                switch selectedTab {
                case .doctor:
                    doctorTabContent
                case .shaderCache:
                    shaderCacheTabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerBar
        }
        .frame(minWidth: 660, idealWidth: 740, minHeight: 500, idealHeight: 580)
        .onAppear {
            if doctorSnapshot == nil && !isRunningDoctor {
                refreshDoctor()
            }
            if cacheSnapshot == nil && !isLoadingCaches {
                refreshShaderCaches()
            }
        }
    }

    // MARK: Header & footer

    private var headerBar: some View {
        HStack(spacing: 14) {
            Label("System Health & Shader Cache", systemImage: "stethoscope")
                .font(.title2.bold())
                .lineLimit(1)
            Spacer(minLength: 12)
            Picker("Section", selection: $selectedTab) {
                ForEach(SystemHealthTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            if selectedTab == .doctor {
                if let snap = doctorSnapshot {
                    HStack(spacing: 6) {
                        Image(systemName: snap.overallSeverity.iconName)
                            .foregroundStyle(snap.overallSeverity.color)
                        Text("v\(snap.appVersion) · \(snap.overallLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Read-only system health probe — nothing on disk is modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(LaunchDiagnostics.redactHome(cacheSnapshot?.rootPath ?? RuntimeLauncher.shaderCacheRoot().path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isPruningCaches)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: System Doctor tab

    private var doctorTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            doctorActionBar
                .padding(.horizontal, 22)
                .padding(.top, 14)

            if let snap = doctorSnapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snap.checks) { item in
                            DoctorCheckRow(item: item)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Running 9-point Apple Silicon, runtime, display & security diagnostics…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var doctorActionBar: some View {
        HStack(spacing: 10) {
            if let snap = doctorSnapshot {
                HStack(spacing: 6) {
                    Image(systemName: snap.overallSeverity.iconName)
                        .foregroundStyle(snap.overallSeverity.color)
                    Text(snap.overallLabel)
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(snap.overallSeverity.color.opacity(0.12), in: Capsule())
            } else if isRunningDoctor {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking system…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                refreshDoctor()
            } label: {
                if isRunningDoctor {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRunningDoctor)
            .help("Re-run all 9 read-only system health diagnostics")

            Button {
                copyDiagnosticsMarkdown()
            } label: {
                Label(
                    copiedDiagnostics ? "Copied Markdown" : "Copy Diagnostics Markdown",
                    systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(doctorSnapshot == nil)
            .help("Copy a GitHub-ready Markdown report with your home path redacted to ~")
        }
    }

    // MARK: Shader Cache tab

    private var shaderCacheTabContent: some View {
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

    // MARK: Actions

    private func refreshDoctor() {
        guard !isRunningDoctor else { return }
        isRunningDoctor = true
        let display = DisplayCapabilities.current()
        let controllers = ConnectedControllerInfo.snapshot()
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = SystemHealthProbe.runDoctor(display: display, controllers: controllers)
            DispatchQueue.main.async {
                self.doctorSnapshot = snapshot
                self.isRunningDoctor = false
            }
        }
    }

    private func copyDiagnosticsMarkdown() {
        guard let snap = doctorSnapshot else { return }
        let report = snap.markdownReport()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        vm.statusMessage = "Copied system diagnostics Markdown (home path redacted to ~)."
        withAnimation { copiedDiagnostics = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { copiedDiagnostics = false }
        }
    }

    private func refreshShaderCaches() {
        guard !isLoadingCaches else { return }
        isLoadingCaches = true
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = SystemHealthProbe.loadShaderCaches()
            DispatchQueue.main.async {
                self.cacheSnapshot = snap
                self.isLoadingCaches = false
                self.vm.refreshShaderCache()
            }
        }
    }

    private func pruneStaleCaches() {
        guard !isPruningCaches else { return }
        isPruningCaches = true
        cacheBanner = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let res = try ShaderCacheManager.pruneStaleCaches(dryRun: false)
                let updated = SystemHealthProbe.loadShaderCaches()
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
                let updated = SystemHealthProbe.loadShaderCaches()
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

// MARK: - Subviews

private struct DoctorCheckRow: View {
    let item: DoctorCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.severity.iconName)
                .font(.system(size: 16))
                .foregroundStyle(item.severity.color)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(item.severity.tag)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(item.severity.color)
                        .background(item.severity.color.opacity(0.14), in: Capsule())
                }
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let hint = item.remediation, !hint.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 1.5)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
    }
}

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
