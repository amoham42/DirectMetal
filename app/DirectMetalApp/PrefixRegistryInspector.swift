import Foundation

// Fast, read-only Wine prefix registry inspector (`user.reg` & `system.reg`).
// Parses Wine's text registry hives directly without spawning `wineserver` or mutating disk,
// with bounded reads (32 MiB cap) and lossy UTF-8 decoding so oversized or corrupted hives never OOM.

// MARK: - Errors & Data Model

enum PrefixRegistryError: Error, LocalizedError, Equatable, Sendable {
    case prefixNotFound(String)
    case missingRegistryFiles(String)

    var errorDescription: String? {
        switch self {
        case .prefixNotFound(let path):
            return "Wine prefix directory not found at \(LaunchDiagnostics.redactHome(path))."
        case .missingRegistryFiles(let path):
            return "No Wine registry files (system.reg or user.reg) found in prefix \(LaunchDiagnostics.redactHome(path))."
        }
    }
}

struct PrefixRegistrySummary: Codable, Equatable, Sendable {
    let prefixName: String
    let prefixPath: String
    let hasSystemReg: Bool
    let hasUserReg: Bool
    let systemRegBytes: UInt64
    let userRegBytes: UInt64
    let windowsVersion: String?
    let logPixelsDPI: Int?
    let virtualDesktopName: String?
    let virtualDesktopResolution: String?
    let audioDriver: String?
    let dllOverrides: [String: String]
    let userSectionCount: Int
    let systemSectionCount: Int
    let warnings: [String]
}

// MARK: - Read-Only Wine Registry Inspector

enum PrefixRegistryInspector {
    /// Maximum bytes read per `.reg` file (32 MiB) so corrupted giant files never OOM.
    static let maxRegistryFileBytes: Int = 32 * 1024 * 1024
    /// Standard acceptable Windows LogPixels DPI range (72 DPI to 384 DPI / 400% scale).
    static let standardDPIRange: ClosedRange<Int> = 72...384

    /// Inspects `system.reg` and `user.reg` inside `prefixURL` without spawning Wine or mutating disk.
    static func inspect(prefixURL: URL, prefixName: String? = nil) throws -> PrefixRegistrySummary {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: prefixURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw PrefixRegistryError.prefixNotFound(prefixURL.path)
        }

        let resolvedName = (prefixName?.isEmpty == false) ? (prefixName ?? prefixURL.lastPathComponent) : prefixURL.lastPathComponent
        let systemRegURL = prefixURL.appendingPathComponent("system.reg")
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        let systemFile = probeRegularFile(at: systemRegURL, fileManager: fm)
        let userFile = probeRegularFile(at: userRegURL, fileManager: fm)

        guard systemFile.exists || userFile.exists else {
            throw PrefixRegistryError.missingRegistryFiles(prefixURL.path)
        }

        var warnings: [String] = []
        if !systemFile.exists {
            warnings.append("Missing system.reg — machine-wide Wine settings and Windows version metadata are unavailable.")
        }
        if !userFile.exists {
            warnings.append("Missing user.reg — per-user Wine settings (Retina DPI, DLL overrides, virtual desktop, audio driver) are unavailable.")
        }

        let systemHive = systemFile.exists
            ? loadAndParseHive(url: systemRegURL, fileName: "system.reg", fileSize: systemFile.bytes, warnings: &warnings)
            : ParsedHive()
        let userHive = userFile.exists
            ? loadAndParseHive(url: userRegURL, fileName: "user.reg", fileSize: userFile.bytes, warnings: &warnings)
            : ParsedHive()

        let windowsVersion =
            nonEmpty(userHive.wineVersion)
            ?? nonEmpty(systemHive.wineVersion)
            ?? nonEmpty(systemHive.ntProductName)
            ?? nonEmpty(systemHive.ntCurrentVersion)
            ?? nonEmpty(userHive.ntProductName)
            ?? nonEmpty(userHive.ntCurrentVersion)

        let logPixelsDPI =
            userHive.desktopLogPixels
            ?? userHive.fontsLogPixels
            ?? systemHive.desktopLogPixels
            ?? systemHive.fontsLogPixels

        let virtualDesktopName = nonEmpty(userHive.virtualDesktopName) ?? nonEmpty(systemHive.virtualDesktopName)
        let virtualDesktopResolution = resolveDesktopResolution(
            desktopName: virtualDesktopName,
            userDesktops: userHive.desktopResolutions,
            systemDesktops: systemHive.desktopResolutions
        )
        let audioDriver = userHive.audioDriver ?? systemHive.audioDriver

        var mergedOverridesByLower = systemHive.dllOverrides
        for (lowerKey, entry) in userHive.dllOverrides {
            mergedOverridesByLower[lowerKey] = entry
        }
        var dllOverrides: [String: String] = [:]
        dllOverrides.reserveCapacity(mergedOverridesByLower.count)
        for (_, entry) in mergedOverridesByLower {
            dllOverrides[entry.key] = entry.value
        }

        if let driver = audioDriver {
            let trimmed = driver.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                warnings.append("Audio driver is explicitly empty (disabled) in [Software\\Wine\\Drivers].")
            } else if trimmed.lowercased() == "none" || trimmed.lowercased() == "disabled" {
                warnings.append("Audio driver is explicitly disabled (\"\(trimmed)\") in [Software\\Wine\\Drivers].")
            }
        }
        if let dpi = logPixelsDPI, !standardDPIRange.contains(dpi) {
            warnings.append("Non-standard LogPixels DPI (\(dpi)); expected a value within \(standardDPIRange.lowerBound)...\(standardDPIRange.upperBound).")
        }
        if let desktopName = virtualDesktopName, virtualDesktopResolution == nil {
            warnings.append("Virtual desktop \"\(desktopName)\" is enabled, but no matching resolution was found in [Software\\Wine\\Explorer\\Desktops].")
        }

        return PrefixRegistrySummary(
            prefixName: resolvedName,
            prefixPath: prefixURL.path,
            hasSystemReg: systemFile.exists,
            hasUserReg: userFile.exists,
            systemRegBytes: systemFile.bytes,
            userRegBytes: userFile.bytes,
            windowsVersion: windowsVersion,
            logPixelsDPI: logPixelsDPI,
            virtualDesktopName: virtualDesktopName,
            virtualDesktopResolution: virtualDesktopResolution,
            audioDriver: audioDriver,
            dllOverrides: dllOverrides,
            userSectionCount: userHive.sectionCount,
            systemSectionCount: systemHive.sectionCount,
            warnings: warnings
        )
    }

    /// Resolves `prefixName` through `prefixManager` and inspects its Wine registry hives.
    static func inspect(prefixName: String, prefixManager: PrefixManager = PrefixManager()) throws -> PrefixRegistrySummary {
        try inspect(prefixURL: prefixManager.prefixURL(named: prefixName), prefixName: prefixName)
    }

    // MARK: - Formatters

    static func formatText(_ summary: PrefixRegistrySummary, home: String = NSHomeDirectory()) -> String {
        let r: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        var sections: [String] = []

        func formatSection(_ heading: String, _ rows: [(String, String)]) -> String {
            let labelWidth = max((rows.map { $0.0.count }.max() ?? 0) + 2, 18)
            var out = ["[\(heading)]"]
            for (label, value) in rows {
                let padded = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                out.append("  \(padded)\(value)")
            }
            return out.joined(separator: "\n")
        }

        let sysText = summary.hasSystemReg ? "present (\(formatBytes(summary.systemRegBytes)), \(summary.systemSectionCount) sections)" : "missing"
        let usrText = summary.hasUserReg ? "present (\(formatBytes(summary.userRegBytes)), \(summary.userSectionCount) sections)" : "missing"

        sections.append("DirectMetal Wine Prefix Registry — \(r(summary.prefixName))")
        sections.append(formatSection("Prefix & Registry Files", [
            ("Prefix Name", r(summary.prefixName)),
            ("Prefix Path", r(summary.prefixPath)),
            ("system.reg", sysText),
            ("user.reg", usrText),
        ]))
        sections.append(formatSection("Wine Configuration", [
            ("Windows Version", r(summary.windowsVersion ?? "default (unset)")),
            ("LogPixels DPI", formatDPI(summary.logPixelsDPI)),
            ("Virtual Desktop", r(formatVirtualDesktop(name: summary.virtualDesktopName, resolution: summary.virtualDesktopResolution))),
            ("Audio Driver", r(formatAudioDriver(summary.audioDriver))),
        ]))

        if summary.dllOverrides.isEmpty {
            sections.append("[DLL Overrides (0)]\n  (none)")
        } else {
            let sortedKeys = summary.dllOverrides.keys.sorted()
            sections.append(formatSection("DLL Overrides (\(sortedKeys.count))", sortedKeys.map { (r($0), r(summary.dllOverrides[$0] ?? "")) }))
        }

        if !summary.warnings.isEmpty {
            var warnLines = ["[Warnings (\(summary.warnings.count))]"]
            for warning in summary.warnings {
                warnLines.append("  ! \(r(warning))")
            }
            sections.append(warnLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func formatMarkdown(_ summary: PrefixRegistrySummary, home: String = NSHomeDirectory()) -> String {
        let r: (String) -> String = { LaunchDiagnostics.redactHome($0, home: home) }
        func cell(_ raw: String) -> String {
            r(raw)
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }

        let sysText = summary.hasSystemReg ? "Present (\(formatBytes(summary.systemRegBytes)), \(summary.systemSectionCount) sections)" : "**Missing**"
        let usrText = summary.hasUserReg ? "Present (\(formatBytes(summary.userRegBytes)), \(summary.userSectionCount) sections)" : "**Missing**"

        var lines: [String] = [
            "### DirectMetal Wine Prefix Registry — \(cell(summary.prefixName))",
            "",
            "| Field | Value |",
            "| :--- | :--- |",
            "| **Prefix Name** | `\(cell(summary.prefixName))` |",
            "| **Prefix Path** | `\(cell(summary.prefixPath))` |",
            "| **system.reg** | \(sysText) |",
            "| **user.reg** | \(usrText) |",
            "| **Windows Version** | `\(cell(summary.windowsVersion ?? "default (unset)"))` |",
            "| **LogPixels DPI** | \(cell(formatDPI(summary.logPixelsDPI))) |",
            "| **Virtual Desktop** | \(cell(formatVirtualDesktop(name: summary.virtualDesktopName, resolution: summary.virtualDesktopResolution))) |",
            "| **Audio Driver** | `\(cell(formatAudioDriver(summary.audioDriver)))` |",
            "",
            "#### DLL Overrides (\(summary.dllOverrides.count))",
            "",
        ]

        if summary.dllOverrides.isEmpty {
            lines.append("_None_")
        } else {
            lines.append("| DLL | Override |")
            lines.append("| :--- | :--- |")
            for key in summary.dllOverrides.keys.sorted() {
                lines.append("| `\(cell(key))` | `\(cell(summary.dllOverrides[key] ?? ""))` |")
            }
        }

        if !summary.warnings.isEmpty {
            lines.append("")
            lines.append("#### Warnings")
            lines.append("")
            for warning in summary.warnings {
                lines.append("- ⚠️ \(cell(warning))")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private File I/O

    private static func probeRegularFile(at url: URL, fileManager: FileManager) -> (exists: Bool, bytes: UInt64) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return (false, 0)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) } ?? 0
        return (true, size)
    }

    private static func loadAndParseHive(
        url: URL,
        fileName: String,
        fileSize: UInt64,
        warnings: inout [String]
    ) -> ParsedHive {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxRegistryFileBytes) ?? Data()
            if fileSize > UInt64(maxRegistryFileBytes) {
                let cap = formatBytes(UInt64(maxRegistryFileBytes))
                warnings.append("\(fileName) exceeds the \(cap) inspection limit (\(formatBytes(fileSize))); parsed the first \(cap) only.")
            }
            return parseRegistryData(data)
        } catch {
            warnings.append("Failed to read \(fileName): \(error.localizedDescription)")
            return ParsedHive()
        }
    }

    // MARK: - Private Wine .reg Parser

    private enum TrackedSection {
        case wine, windowsNTCurrentVersion, controlPanelDesktop, hardwareProfileFonts
        case wineExplorer, wineExplorerDesktops, wineDrivers, wineDllOverrides
    }

    private struct ParsedHive {
        var sectionCount: Int = 0
        var wineVersion: String?
        var ntCurrentVersion: String?
        var ntProductName: String?
        var desktopLogPixels: Int?
        var fontsLogPixels: Int?
        var virtualDesktopName: String?
        var desktopResolutions: [String: String] = [:]
        var audioDriver: String?
        var dllOverrides: [String: (key: String, value: String)] = [:]
    }

    private enum ParsedValue {
        case string(String), dword(Int), deleted
    }

    private static let trackedSections: [String: TrackedSection] = [
        "software\\wine": .wine,
        "software\\microsoft\\windows nt\\currentversion": .windowsNTCurrentVersion,
        "control panel\\desktop": .controlPanelDesktop,
        "system\\currentcontrolset\\hardware profiles\\current\\software\\fonts": .hardwareProfileFonts,
        "software\\wine\\explorer": .wineExplorer,
        "software\\wine\\explorer\\desktops": .wineExplorerDesktops,
        "software\\wine\\drivers": .wineDrivers,
        "software\\wine\\dlloverrides": .wineDllOverrides,
    ]

    private static func parseRegistryData(_ data: Data) -> ParsedHive {
        var result = ParsedHive()
        var currentSection: TrackedSection?
        var inContinuation = false

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = (count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0

            while index < count {
                let lineStart = index
                while index < count && bytes[index] != 0x0A { index += 1 }
                var lineEnd = index
                if index < count && bytes[index] == 0x0A { index += 1 }
                if lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }

                var start = lineStart
                while start < lineEnd && (bytes[start] == 0x20 || bytes[start] == 0x09) { start += 1 }
                var end = lineEnd
                while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09) { end -= 1 }

                if start == end { inContinuation = false; continue }
                if inContinuation { inContinuation = (bytes[end - 1] == 0x5C); continue }

                let first = bytes[start]
                if first == 0x3B || first == 0x23 { continue } // ';' comment or '#time=' / '#arch=' metadata

                if first == 0x5B { // '[' section header
                    var closeBracket = end - 1
                    while closeBracket > start && bytes[closeBracket] != 0x5D { closeBracket -= 1 }
                    if closeBracket > start && bytes[closeBracket] == 0x5D {
                        result.sectionCount += 1
                        let rawHeader = String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + 1)..<closeBracket]), as: UTF8.self)
                        currentSection = trackedSections[normalizeSectionName(rawHeader)]
                    }
                    continue
                }

                guard let section = currentSection else {
                    if bytes[end - 1] == 0x5C { inContinuation = true }
                    continue
                }

                if first == 0x22 { // '"' key-value entry
                    let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
                    if let (key, value) = parseKeyValueLine(line) {
                        applyEntry(key: key, value: value, to: &result, in: section)
                    } else if bytes[end - 1] == 0x5C {
                        inContinuation = true
                    }
                } else if bytes[end - 1] == 0x5C {
                    inContinuation = true
                }
            }
        }

        return result
    }

    private static func normalizeSectionName(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch == "\\" {
                let next = raw.index(after: idx)
                if next < raw.endIndex && raw[next] == "\\" {
                    out.append("\\")
                    idx = raw.index(after: next)
                    continue
                }
            }
            out.append(ch)
            idx = raw.index(after: idx)
        }
        var lower = out.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["hkey_current_user\\", "hkey_local_machine\\", "hkcu\\", "hklm\\"] {
            if lower.hasPrefix(prefix) {
                lower = String(lower.dropFirst(prefix.count))
                break
            }
        }
        return lower
    }

    private static func parseQuotedString(_ s: String, from start: String.Index) -> (value: String, nextIndex: String.Index)? {
        guard start < s.endIndex, s[start] == "\"" else { return nil }
        var idx = s.index(after: start)
        var out = ""
        out.reserveCapacity(32)

        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\"" { return (out, s.index(after: idx)) }
            if ch == "\\" {
                let next = s.index(after: idx)
                guard next < s.endIndex else { return nil }
                switch s[next] {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(s[next])
                }
                idx = s.index(after: next)
                continue
            }
            out.append(ch)
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func parseKeyValueLine(_ line: String) -> (key: String, value: ParsedValue)? {
        guard let (key, afterKey) = parseQuotedString(line, from: line.startIndex) else { return nil }
        var idx = afterKey
        while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") { idx = line.index(after: idx) }
        guard idx < line.endIndex, line[idx] == "=" else { return nil }
        idx = line.index(after: idx)
        while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return nil }

        if line[idx] == "\"" {
            guard let (strVal, _) = parseQuotedString(line, from: idx) else { return nil }
            return (key, .string(strVal))
        }
        let remainder = line[idx...]
        if remainder == "-" { return (key, .deleted) }
        if remainder.prefix(6).lowercased() == "dword:" {
            let hex = remainder.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard !hex.isEmpty, hex.count <= 8, let raw = UInt32(hex, radix: 16) else { return nil }
            return (key, .dword(Int(raw)))
        }
        if remainder.prefix(7).lowercased() == "str(2):" {
            let afterPrefix = remainder.dropFirst(7)
            if let (strVal, _) = parseQuotedString(line, from: afterPrefix.startIndex) {
                return (key, .string(strVal))
            }
        }
        return nil
    }

    private static func applyEntry(key: String, value: ParsedValue, to hive: inout ParsedHive, in section: TrackedSection) {
        let keyLower = key.lowercased()
        switch (section, keyLower, value) {
        case (.wine, "version", .string(let v)): hive.wineVersion = v
        case (.wine, "version", .deleted): hive.wineVersion = nil
        case (.windowsNTCurrentVersion, "currentversion", .string(let v)): hive.ntCurrentVersion = v
        case (.windowsNTCurrentVersion, "currentversion", .deleted): hive.ntCurrentVersion = nil
        case (.windowsNTCurrentVersion, "productname", .string(let v)): hive.ntProductName = v
        case (.windowsNTCurrentVersion, "productname", .deleted): hive.ntProductName = nil
        case (.controlPanelDesktop, "logpixels", .dword(let v)): hive.desktopLogPixels = v
        case (.controlPanelDesktop, "logpixels", .deleted): hive.desktopLogPixels = nil
        case (.hardwareProfileFonts, "logpixels", .dword(let v)): hive.fontsLogPixels = v
        case (.hardwareProfileFonts, "logpixels", .deleted): hive.fontsLogPixels = nil
        case (.wineExplorer, "desktop", .string(let v)): hive.virtualDesktopName = v
        case (.wineExplorer, "desktop", .deleted): hive.virtualDesktopName = nil
        case (.wineExplorerDesktops, _, .string(let v)): hive.desktopResolutions[keyLower] = v
        case (.wineExplorerDesktops, _, .deleted): hive.desktopResolutions.removeValue(forKey: keyLower)
        case (.wineDrivers, "audio", .string(let v)): hive.audioDriver = v
        case (.wineDrivers, "audio", .deleted): hive.audioDriver = nil
        case (.wineDllOverrides, _, .string(let v)): hive.dllOverrides[keyLower] = (key: key, value: v)
        case (.wineDllOverrides, _, .deleted): hive.dllOverrides.removeValue(forKey: keyLower)
        default: break
        }
    }

    // MARK: - Private Formatting & Resolution Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func resolveDesktopResolution(
        desktopName: String?,
        userDesktops: [String: String],
        systemDesktops: [String: String]
    ) -> String? {
        if let name = desktopName {
            let key = name.lowercased()
            if let res = nonEmpty(userDesktops[key]) ?? nonEmpty(systemDesktops[key]) { return res }
        }
        return nonEmpty(userDesktops["default"]) ?? nonEmpty(systemDesktops["default"])
    }

    private static func formatDPI(_ dpi: Int?) -> String {
        guard let dpi else { return "default (unset)" }
        return "\(dpi) DPI (\(Int((Double(dpi) / 96.0 * 100.0).rounded()))%)"
    }

    private static func formatVirtualDesktop(name: String?, resolution: String?) -> String {
        switch (name, resolution) {
        case (let n?, let r?): return "\(n) (\(r))"
        case (let n?, nil): return "\(n) (resolution unset)"
        case (nil, let r?): return "disabled (Default resolution: \(r))"
        case (nil, nil): return "disabled"
        }
    }

    private static func formatAudioDriver(_ driver: String?) -> String {
        guard let driver else { return "default (unset)" }
        let trimmed = driver.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "disabled (empty)" : trimmed
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 { return String(format: "%.1f KiB", kb) }
        let mb = kb / 1024.0
        if mb < 1024.0 { return String(format: "%.1f MiB", mb) }
        return String(format: "%.2f GiB", mb / 1024.0)
    }
}
