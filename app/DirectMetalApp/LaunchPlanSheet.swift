import AppKit
import Foundation
import SwiftUI

// Native macOS 15 SwiftUI sheet for previewing GameLaunchPlan dry-run inspections.
// Pure resolver and formatters live in LaunchPlanInspector.swift.

// MARK: - SwiftUI Sheet

struct LaunchPlanSheet: View {
    let entry: GameLibraryEntry
    @ObservedObject var vm: DirectMetalViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var plan: GameLaunchPlan?
    @State private var preflight: PreflightReport?
    @State private var copiedMarkdown = false

    private var liveEntry: GameLibraryEntry {
        vm.library.first(where: { $0.id == entry.id }) ?? entry
    }

    private var activePlan: GameLaunchPlan {
        plan ?? LaunchPlanInspector.inspect(entry: liveEntry, hardware: vm.gpuInfo)
    }

    var body: some View {
        let currentPlan = activePlan
        VStack(alignment: .leading, spacing: 0) {
            headerBar(currentPlan)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let checkReport = preflight {
                        preflightCard(checkReport)
                    }
                    executionCard(currentPlan)
                    framePacingCard(currentPlan)
                    prefixAndCacheCard(currentPlan)
                    sandboxControllerEnvCard(currentPlan)
                    if !currentPlan.warnings.isEmpty {
                        warningsCard(currentPlan)
                    }
                }
                .padding(20)
            }

            Divider()
            footerBar(currentPlan)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .onAppear {
            refreshPlan()
        }
        .onChange(of: liveEntry) {
            refreshPlan()
        }
    }

    // MARK: Header & footer

    private func headerBar(_ currentPlan: GameLaunchPlan) -> some View {
        HStack(spacing: 12) {
            GameMonogram(title: currentPlan.title, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Launch Plan Inspector")
                        .font(.title3.bold())
                    Text("DRY-RUN")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }

                HStack(spacing: 6) {
                    Text(currentPlan.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ArchPill(architecture: currentPlan.architecture)
                    ForEach(LauncherStyle.apiBadges(for: liveEntry)) { badge in
                        BadgeView(badge: badge)
                    }
                }
            }

            Spacer(minLength: 8)

            statusBadge(currentPlan)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func statusBadge(_ currentPlan: GameLaunchPlan) -> some View {
        let hasWarnings = !currentPlan.warnings.isEmpty
        let color: Color = hasWarnings ? .orange : .green
        let icon = hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
        let label = hasWarnings
            ? "\(currentPlan.warnings.count) Warning\(currentPlan.warnings.count == 1 ? "" : "s")"
            : "Ready"
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }

    private func footerBar(_ currentPlan: GameLaunchPlan) -> some View {
        HStack(spacing: 10) {
            Button {
                copyMarkdown(currentPlan)
            } label: {
                Label(
                    copiedMarkdown ? "Copied Markdown" : "Copy Markdown",
                    systemImage: copiedMarkdown ? "checkmark" : "doc.on.doc"
                )
            }
            .help("Copy a GitHub-issue-ready Markdown launch plan with home paths redacted")

            Button {
                refreshPlan()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-evaluate prefix, warm wineserver, and runtime state")

            Spacer(minLength: 12)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: GroupBox cards

    private func executionCard(_ currentPlan: GameLaunchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                planRow("Executable", value: LaunchDiagnostics.redactHome(currentPlan.exePath), monospaced: true) {
                    statusPill(
                        currentPlan.exeExists ? "Found" : "Missing",
                        color: currentPlan.exeExists ? .green : .red
                    )
                }
                planRow("Architecture", value: currentPlan.architecture, monospaced: true)
                planRow(
                    "Detected APIs",
                    value: currentPlan.detectedAPIs.isEmpty
                        ? "Win32 / Auto-detect"
                        : currentPlan.detectedAPIs.joined(separator: ", ")
                )
                planRow("Engine", value: "\(currentPlan.resolvedEngine) (requested: \(currentPlan.requestedEngine))", monospaced: true) {
                    statusPill(
                        currentPlan.resolvedEngine == "unavailable" ? "Unavailable" : "Resolved",
                        color: currentPlan.resolvedEngine == "unavailable" ? .red : .blue
                    )
                }
                planRow("Selection Reason", value: currentPlan.engineReason)
                planRow("Graphics Pipeline", value: currentPlan.graphicsPipelineSummary)
                planRow("Perf / DX9", value: "profile=\(currentPlan.perfProfile) · dx9=\(currentPlan.dx9Backend)", monospaced: true)
            }
            .padding(.top, 4)
        } label: {
            Label("Execution & Graphics Pipeline", systemImage: "cpu")
                .font(.headline)
        }
    }

    private func framePacingCard(_ currentPlan: GameLaunchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                planRow("Upscaling Plan", value: currentPlan.upscalingPlan)
                planRow(
                    "Detected Upscalers",
                    value: currentPlan.detectedUpscalers.isEmpty
                        ? "None detected"
                        : currentPlan.detectedUpscalers.joined(separator: ", ")
                )
                planRow("FPS Cap", value: currentPlan.fpsCap > 0 ? "\(currentPlan.fpsCap) FPS" : "Uncapped")
                if !currentPlan.fpsCapEnvPreview.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FPS Cap Environment Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        envListBox(currentPlan.fpsCapEnvPreview, redactValues: false)
                    }
                }
                planRow(
                    "Display & HUD",
                    value: "Retina HiDPI: \(currentPlan.retinaEnabled ? "On" : "Off") · Metal Performance HUD: \(currentPlan.hudEnabled ? "On" : "Off")"
                )
            }
            .padding(.top, 4)
        } label: {
            Label("Frame Pacing & Upscaling", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
        }
    }

    private func prefixAndCacheCard(_ currentPlan: GameLaunchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                planRow("Prefix Name", value: currentPlan.prefixName, monospaced: true) {
                    statusPill(
                        currentPlan.prefixExists ? "Exists" : "Will APFS-Clone",
                        color: currentPlan.prefixExists ? .green : .blue
                    )
                }
                planRow("Prefix Path", value: LaunchDiagnostics.redactHome(currentPlan.prefixPath), monospaced: true)
                planRow(
                    "Wineserver",
                    value: currentPlan.wineserverWarm
                        ? "Warm (persistent wineserver running for instant launch)"
                        : "Cold (will start on launch)"
                ) {
                    statusPill(
                        currentPlan.wineserverWarm ? "Warm" : "Cold",
                        color: currentPlan.wineserverWarm ? .green : .secondary
                    )
                }
                planRow("Shader Cache Key", value: currentPlan.shaderCacheKey, monospaced: true)
                planRow("Shader Cache Dir", value: LaunchDiagnostics.redactHome(currentPlan.shaderCacheDir), monospaced: true) {
                    statusPill(
                        currentPlan.shaderCacheExists ? "Exists" : "New",
                        color: currentPlan.shaderCacheExists ? .green : .secondary
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Prefix & Shader Cache", systemImage: "externaldrive.badge.timemachine")
                .font(.headline)
        }
    }

    private func sandboxControllerEnvCard(_ currentPlan: GameLaunchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                planRow("Sandbox", value: currentPlan.sandboxSummary) {
                    statusPill(
                        currentPlan.sandboxEnabled ? "Seatbelt On" : "Off",
                        color: currentPlan.sandboxEnabled ? .teal : .secondary
                    )
                }
                planRow("Controller", value: "\(currentPlan.controllerPreset) · key=\(currentPlan.controllerProfileKey)") {
                    statusPill(
                        currentPlan.controllerHasOverrides ? "Overrides Active" : "Stock",
                        color: currentPlan.controllerHasOverrides ? .purple : .secondary
                    )
                }
                planRow(
                    "Extra Args",
                    value: currentPlan.extraArgs.isEmpty ? "None" : currentPlan.extraArgs.joined(separator: " "),
                    monospaced: !currentPlan.extraArgs.isEmpty
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sanitized Custom Environment")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if currentPlan.sanitizedCustomEnv.isEmpty {
                        Text("None")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        envListBox(currentPlan.sanitizedCustomEnv, redactValues: true)
                    }
                }

                if !currentPlan.blockedCustomEnvKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "shield.lefthalf.filled.slash")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Blocked Environment Keys (stripped for host isolation)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        HStack(spacing: 6) {
                            ForEach(currentPlan.blockedCustomEnvKeys, id: \.self) { key in
                                Text(key)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .foregroundStyle(.orange)
                                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Sandbox, Controller & Custom Environment", systemImage: "lock.shield")
                .font(.headline)
        }
    }

    private func warningsCard(_ currentPlan: GameLaunchPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(currentPlan.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .padding(.top, 1)
                        Text(LaunchDiagnostics.redactHome(warning))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Warnings (\(currentPlan.warnings.count))", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Row & helper components

    private func planRow<Accessory: View>(
        _ label: String,
        value: String,
        monospaced: Bool = false,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 126, alignment: .trailing)

            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            accessory()
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private func envListBox(_ env: [String: String], redactValues: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(env.keys.sorted(), id: \.self) { key in
                let rawValue = env[key] ?? ""
                let displayValue = redactValues ? LaunchDiagnostics.redactHome(rawValue) : rawValue
                Text("\(key)=\(displayValue)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func preflightCard(_ report: PreflightReport) -> some View {
        let headerColor: Color = {
            switch report.overallStatus {
            case .pass: return .green
            case .warn: return .orange
            case .fail: return .red
            }
        }()
        return GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(report.checks) { item in
                    let tint: Color = {
                        switch item.status {
                        case .pass: return .green
                        case .warn: return .orange
                        case .fail: return .red
                        }
                    }()
                    let icon: String = {
                        switch item.status {
                        case .pass: return "checkmark.circle.fill"
                        case .warn: return "exclamationmark.triangle.fill"
                        case .fail: return "xmark.octagon.fill"
                        }
                    }()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(tint)
                            .font(.callout)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                                statusPill(item.status.displayLabel, color: tint)
                            }
                            Text(LaunchDiagnostics.redactHome(item.summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let fix = item.remediation, !fix.isEmpty {
                                Text("Fix: \(LaunchDiagnostics.redactHome(fix))")
                                    .font(.caption2)
                                    .foregroundStyle(tint)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            HStack(spacing: 8) {
                Label("Pre-Flight Readiness", systemImage: "checklist")
                statusPill(
                    report.canLaunch
                        ? (report.warnCount > 0 ? "READY (\(report.warnCount) WARN)" : "READY (\(report.passCount)/\(report.checks.count))")
                        : "BLOCKED (\(report.failCount) FAIL)",
                    color: headerColor
                )
            }
        }
    }

    // MARK: Actions

    private func refreshPlan() {
        plan = LaunchPlanInspector.inspect(entry: liveEntry, hardware: vm.gpuInfo)
        preflight = PreflightChecker.check(entry: liveEntry, hardware: vm.gpuInfo)
    }

    private func copyMarkdown(_ currentPlan: GameLaunchPlan) {
        let md = LaunchPlanInspector.formatMarkdown(currentPlan)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        vm.statusMessage = "Copied launch plan Markdown for \(currentPlan.title)."
        copiedMarkdown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedMarkdown = false
        }
    }
}
