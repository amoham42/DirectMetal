import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shortcut Export Types

enum ShortcutFormat: String, Codable, CaseIterable, Sendable {
    case app
    case command
}

struct ShortcutExportResult: Codable, Equatable, Sendable {
    let format: ShortcutFormat
    let outputPath: String
    let gameID: String
    let title: String
    let hasCustomIcon: Bool
}

enum ShortcutExporterError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidDestination(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidDestination(let message):
            return "Invalid shortcut destination: \(message)"
        case .writeFailed(let message):
            return "Failed to write shortcut: \(message)"
        }
    }
}

// MARK: - Shortcut Exporter

/// Exports standalone macOS `.app` bundles and `.command` launcher scripts for games
/// in the DirectMetal library.
enum ShortcutExporter {
    static let fallbackFileName = "DirectMetal Game"
    static let maxFileNameLength = 80
    static let standardBinaryFallbacks: [String] = [
        "/Applications/DirectMetal-Lite.app/Contents/MacOS/DirectMetal",
        "/Applications/DirectMetal.app/Contents/MacOS/DirectMetal",
    ]

    /// Produces a safe macOS filename stem from a game title:
    /// strips path separators (`/`, `\`, `:`), control characters, and leading dots,
    /// trims whitespace, collapses runs of spaces, caps length to 80 characters,
    /// and falls back to `"DirectMetal Game"` if empty.
    static func sanitizeFileName(_ title: String) -> String {
        var filtered = String()
        filtered.reserveCapacity(title.count)
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":" {
                continue
            }
            if scalar.properties.generalCategory == .control {
                continue
            }
            filtered.unicodeScalars.append(scalar)
        }

        var collapsed = String()
        collapsed.reserveCapacity(filtered.count)
        var previousWasSpace = false
        for ch in filtered {
            if ch.isWhitespace {
                if !previousWasSpace {
                    collapsed.append(" ")
                    previousWasSpace = true
                }
            } else {
                collapsed.append(ch)
                previousWasSpace = false
            }
        }

        var cleaned = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = cleaned.first, first == "." || first.isWhitespace {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count > maxFileNameLength {
            cleaned = String(cleaned.prefix(maxFileNameLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? fallbackFileName : cleaned
    }

    /// POSIX single-quote escaping (`'` -> `'\''`), safe against `$()`, backticks,
    /// newlines, semicolons, and quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `&`, `<`, `>`, `"`, and `'` for XML / Info.plist generation.
    static func xmlEscape(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Resolves the DirectMetal CLI/app executable path to embed in generated shortcuts.
    static func resolveDirectMetalBinary(override: String? = nil) -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let mainExec = Bundle.main.executablePath, looksLikeDirectMetalBinary(mainExec) {
            return mainExec
        }

        let fm = FileManager.default
        for candidate in standardBinaryFallbacks where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let firstArg = CommandLine.arguments.first, !firstArg.isEmpty {
            return firstArg
        }

        return "DirectMetal"
    }

    /// Default destination folder: `~/Applications/DirectMetal Games` (`HOME`-aware).
    static func defaultShortcutsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("DirectMetal Games", isDirectory: true)
    }

    /// Dispatches to either `.app` bundle or `.command` script export.
    static func export(
        for entry: GameLibraryEntry,
        format: ShortcutFormat,
        into directory: URL? = nil,
        directMetalBinary: String? = nil,
        overwrite: Bool = true
    ) throws -> ShortcutExportResult {
        let destination = directory ?? defaultShortcutsDirectory()
        switch format {
        case .app:
            return try exportAppBundle(
                for: entry,
                into: destination,
                directMetalBinary: directMetalBinary,
                overwrite: overwrite
            )
        case .command:
            return try exportCommandScript(
                for: entry,
                into: destination,
                directMetalBinary: directMetalBinary,
                overwrite: overwrite
            )
        }
    }

    /// Exports a macOS `.app` launcher bundle for `entry` into `directory`.
    static func exportAppBundle(
        for entry: GameLibraryEntry,
        into directory: URL,
        directMetalBinary: String? = nil,
        overwrite: Bool = true
    ) throws -> ShortcutExportResult {
        let destDir = try prepareDestinationDirectory(directory)
        let fileStem = sanitizeFileName(entry.title)
        let targetURL = destDir.appendingPathComponent("\(fileStem).app", isDirectory: false)
        let fm = FileManager.default

        if !overwrite, fm.fileExists(atPath: targetURL.path) {
            throw ShortcutExporterError.writeFailed("Shortcut already exists at \(targetURL.path)")
        }

        let stagingURL = destDir.appendingPathComponent(
            ".DirectMetalShortcut-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        defer {
            if fm.fileExists(atPath: stagingURL.path) {
                try? fm.removeItem(at: stagingURL)
            }
        }

        let contentsURL = stagingURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        } catch {
            throw ShortcutExporterError.writeFailed(
                "Could not create app bundle structure in \(destDir.path): \(error.localizedDescription)"
            )
        }

        let binary = resolveDirectMetalBinary(override: directMetalBinary)
        let launchScript = makeLaunchScript(binaryPath: binary, gameID: entry.id)
        let launchURL = macOSURL.appendingPathComponent("launch", isDirectory: false)

        do {
            try Data(launchScript.utf8).write(to: launchURL, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: launchURL.path
            )
        } catch {
            throw ShortcutExporterError.writeFailed(
                "Could not write launcher executable at \(launchURL.path): \(error.localizedDescription)"
            )
        }

        // Best-effort custom icon generation; never fails the shortcut export.
        let hasCustomIcon = writeBestEffortIcon(for: entry, resourcesURL: resourcesURL)

        let displayTitle = stripXMLIllegalControlScalars(entry.title).isEmpty
            ? fileStem
            : stripXMLIllegalControlScalars(entry.title)
        let bundleID = "com.directmetal.shortcut.\(stripXMLIllegalControlScalars(entry.id))"
        let plistContent = makeInfoPlist(
            displayName: displayTitle,
            bundleIdentifier: bundleID,
            hasCustomIcon: hasCustomIcon
        )
        let plistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let pkgInfoURL = contentsURL.appendingPathComponent("PkgInfo", isDirectory: false)

        do {
            try Data(plistContent.utf8).write(to: plistURL, options: .atomic)
            try Data("APPL????".utf8).write(to: pkgInfoURL, options: .atomic)
        } catch {
            throw ShortcutExporterError.writeFailed(
                "Could not write Info.plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }

        do {
            if fm.fileExists(atPath: targetURL.path) {
                guard overwrite else {
                    throw ShortcutExporterError.writeFailed("Shortcut already exists at \(targetURL.path)")
                }
                try fm.removeItem(at: targetURL)
            }
            try fm.moveItem(at: stagingURL, to: targetURL)
        } catch let err as ShortcutExporterError {
            throw err
        } catch {
            throw ShortcutExporterError.writeFailed(
                "Could not finalize app bundle at \(targetURL.path): \(error.localizedDescription)"
            )
        }

        return ShortcutExportResult(
            format: .app,
            outputPath: targetURL.path,
            gameID: entry.id,
            title: entry.title,
            hasCustomIcon: hasCustomIcon
        )
    }

    /// Exports a clickable macOS `.command` shell script for `entry` into `directory`.
    static func exportCommandScript(
        for entry: GameLibraryEntry,
        into directory: URL,
        directMetalBinary: String? = nil,
        overwrite: Bool = true
    ) throws -> ShortcutExportResult {
        let destDir = try prepareDestinationDirectory(directory)
        let fileStem = sanitizeFileName(entry.title)
        let targetURL = destDir.appendingPathComponent("\(fileStem).command", isDirectory: false)
        let fm = FileManager.default

        if !overwrite, fm.fileExists(atPath: targetURL.path) {
            throw ShortcutExporterError.writeFailed("Shortcut already exists at \(targetURL.path)")
        }

        let binary = resolveDirectMetalBinary(override: directMetalBinary)
        let script = makeLaunchScript(binaryPath: binary, gameID: entry.id)

        do {
            try Data(script.utf8).write(to: targetURL, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: targetURL.path
            )
        } catch {
            throw ShortcutExporterError.writeFailed(
                "Could not write command script at \(targetURL.path): \(error.localizedDescription)"
            )
        }

        return ShortcutExportResult(
            format: .command,
            outputPath: targetURL.path,
            gameID: entry.id,
            title: entry.title,
            hasCustomIcon: false
        )
    }

    // MARK: - Private Helpers

    private static func looksLikeDirectMetalBinary(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowerPath = trimmed.lowercased()
        if lowerPath.contains(".xctest") {
            return false
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        if name.contains("xctest") || name.contains("test") {
            return false
        }
        return name == "directmetal"
            || name.hasPrefix("directmetal-")
            || name.hasPrefix("directmetal_")
    }

    private static func prepareDestinationDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL else {
            throw ShortcutExporterError.invalidDestination("Destination URL must be a file URL: \(directory.absoluteString)")
        }
        let normalized = directory.standardizedFileURL
        let path = normalized.path
        guard !path.isEmpty else {
            throw ShortcutExporterError.invalidDestination("Destination directory path is empty.")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw ShortcutExporterError.invalidDestination("Destination exists and is not a directory: \(path)")
            }
            return normalized
        }

        do {
            try fm.createDirectory(at: normalized, withIntermediateDirectories: true)
            return normalized
        } catch {
            throw ShortcutExporterError.invalidDestination(
                "Could not create destination directory \(path): \(error.localizedDescription)"
            )
        }
    }

    private static func makeLaunchScript(binaryPath: String, gameID: String) -> String {
        let quotedBinary = shellQuote(binaryPath)
        let quotedLite = shellQuote(standardBinaryFallbacks[0])
        let quotedFull = shellQuote(standardBinaryFallbacks[1])
        let quotedID = shellQuote(gameID)

        return """
        #!/bin/sh
        set -eu

        DM_BIN=\(quotedBinary)
        if [ ! -x "$DM_BIN" ]; then
            if [ -x \(quotedLite) ]; then
                DM_BIN=\(quotedLite)
            elif [ -x \(quotedFull) ]; then
                DM_BIN=\(quotedFull)
            elif command -v DirectMetal >/dev/null 2>&1; then
                DM_BIN="$(command -v DirectMetal)"
            else
                echo "DirectMetal binary not found: $DM_BIN" >&2
                exit 127
            fi
        fi

        exec "$DM_BIN" library play \(quotedID)

        """
    }

    private static func makeInfoPlist(
        displayName: String,
        bundleIdentifier: String,
        hasCustomIcon: Bool
    ) -> String {
        let escapedName = xmlEscape(displayName)
        let escapedBundleID = xmlEscape(bundleIdentifier)
        let iconEntry = hasCustomIcon
            ? "    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n"
            : ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleDisplayName</key>
            <string>\(escapedName)</string>
            <key>CFBundleExecutable</key>
            <string>launch</string>
        \(iconEntry)    <key>CFBundleIdentifier</key>
            <string>\(escapedBundleID)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(escapedName)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>15.0</string>
            <key>LSUIElement</key>
            <true/>
        </dict>
        </plist>

        """
    }

    private static func stripXMLIllegalControlScalars(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let v = scalar.value
            let allowed = (v == 0x09 || v == 0x0A || v == 0x0D || v >= 0x20) && v != 0x7F
            if allowed {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Best-Effort Icon Generation

    private static func writeBestEffortIcon(for entry: GameLibraryEntry, resourcesURL: URL) -> Bool {
        guard let image = GameArtworkManager.shared.loadArtwork(for: entry, style: .icon),
              let pngData = renderSquarePNG(from: image, dimension: 512)
        else {
            return false
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns", isDirectory: false)
        let tempPNG = fm.temporaryDirectory.appendingPathComponent(
            "dm-shortcut-icon-\(UUID().uuidString).png",
            isDirectory: false
        )
        defer {
            try? fm.removeItem(at: tempPNG)
        }

        // Primary path: invoke /usr/bin/sips to build a standard macOS .icns from the square PNG.
        if (try? pngData.write(to: tempPNG, options: .atomic)) != nil,
           runSipsToICNS(inputPNG: tempPNG, outputICNS: icnsURL),
           isNonEmptyFile(at: icnsURL) {
            return true
        }

        // Fallback path: wrap the 512x512 PNG directly in a native ICNS container ('ic09').
        let icnsData = makePNGICNSContainer(png512Data: pngData)
        if (try? icnsData.write(to: icnsURL, options: .atomic)) != nil,
           isNonEmptyFile(at: icnsURL) {
            return true
        }

        try? fm.removeItem(at: icnsURL)
        return false
    }

    private static func renderSquarePNG(from image: NSImage, dimension: Int) -> Data? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              cgImage.width > 0,
              cgImage.height > 0,
              dimension > 0
        else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        let canvas = CGFloat(dimension)
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let scale = min(canvas / srcW, canvas / srcH)
        let drawW = (srcW * scale).rounded()
        let drawH = (srcH * scale).rounded()
        let drawRect = CGRect(
            x: ((canvas - drawW) / 2.0).rounded(),
            y: ((canvas - drawH) / 2.0).rounded(),
            width: drawW,
            height: drawH
        )
        ctx.draw(cgImage, in: drawRect)

        guard let squareCG = ctx.makeImage() else {
            return nil
        }

        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else {
            return nil
        }

        CGImageDestinationAddImage(destination, squareCG, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func runSipsToICNS(inputPNG: URL, outputICNS: URL) -> Bool {
        let sipsPath = "/usr/bin/sips"
        guard FileManager.default.isExecutableFile(atPath: sipsPath) else {
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sipsPath)
        proc.arguments = ["-s", "format", "icns", inputPNG.path, "--out", outputICNS.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Wraps a 512x512 PNG payload in an Apple `.icns` container (`icns` + `ic09` chunk).
    private static func makePNGICNSContainer(png512Data: Data) -> Data {
        let chunkLength = UInt32(8 + png512Data.count)
        let totalLength = UInt32(8 + Int(chunkLength))
        var out = Data()
        out.reserveCapacity(Int(totalLength))
        out.append(contentsOf: [0x69, 0x63, 0x6E, 0x73]) // "icns"
        out.append(contentsOf: bigEndianBytes(totalLength))
        out.append(contentsOf: [0x69, 0x63, 0x30, 0x39]) // "ic09" (512x512 PNG)
        out.append(contentsOf: bigEndianBytes(chunkLength))
        out.append(png512Data)
        return out
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func isNonEmptyFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }
}
