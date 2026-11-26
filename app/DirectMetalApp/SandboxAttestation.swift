import CryptoKit
import Darwin
import DeviceCheck
import Foundation
import MachO
import Security

struct AttestationStatus: Codable {
    let macosVersion: String
    let macosBuild: String
    let hardwareModel: String
    let bootSessionUuid: String
    let sipEnabled: Bool
    let ssvSealed: Bool
    let secureEnclaveAvailable: Bool
    let dcDeviceSupported: Bool
    let dcAppAttestSupported: Bool
    let codeSigned: Bool
    let hardenedRuntime: Bool
    let csStatusFlagsHex: String
    let csValid: Bool
    let csRuntime: Bool
    let csDebugged: Bool
    let dyldImageCount: Int
    let nonSystemImages: [String]
    let nonSystemImagesSha256: String
    let sandboxActive: Bool
    let codeIdentifier: String
    let cdhash: String
    let binaryPath: String
    let binarySha256: String

    enum CodingKeys: String, CodingKey {
        case macosVersion = "macos_version"
        case macosBuild = "macos_build"
        case hardwareModel = "hardware_model"
        case bootSessionUuid = "boot_session_uuid"
        case sipEnabled = "sip_enabled"
        case ssvSealed = "ssv_sealed"
        case secureEnclaveAvailable = "secure_enclave_available"
        case dcDeviceSupported = "dc_device_supported"
        case dcAppAttestSupported = "dc_app_attest_supported"
        case codeSigned = "code_signed"
        case hardenedRuntime = "hardened_runtime"
        case csStatusFlagsHex = "cs_status_flags_hex"
        case csValid = "cs_valid"
        case csRuntime = "cs_runtime"
        case csDebugged = "cs_debugged"
        case dyldImageCount = "dyld_image_count"
        case nonSystemImages = "non_system_images"
        case nonSystemImagesSha256 = "non_system_images_sha256"
        case sandboxActive = "sandbox_active"
        case codeIdentifier = "code_identifier"
        case cdhash
        case binaryPath = "binary_path"
        case binarySha256 = "binary_sha256"
    }
}

struct ChildProcessIntegrity: Codable {
    let pid: Int32
    let codeSigned: Bool
    let csStatusFlagsHex: String
    let csValid: Bool
    let csRuntime: Bool
    let csDebugged: Bool
    let codeIdentifier: String
    let cdhash: String
}

enum DirectMetalAttestation {
    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    private static func runStdout(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus, text)
        } catch {
            return (-1, "")
        }
    }

    private static func sha256Hex(fileAt path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func secureEnclaveKeyURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("DirectMetal", isDirectory: true)
            .appendingPathComponent("attest.sekey")
    }

    private static func loadOrCreateSecureEnclaveKey() -> SecureEnclave.P256.Signing.PrivateKey? {
        guard SecureEnclave.isAvailable else { return nil }
        let url = secureEnclaveKeyURL()
        let fm = FileManager.default
        if let blob = try? Data(contentsOf: url),
           let existing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
            return existing
        }
        guard let fresh = try? SecureEnclave.P256.Signing.PrivateKey() else {
            return nil
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fresh.dataRepresentation.write(to: url, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Even if persistence fails (e.g. read-only FS), key still signs inside Secure Enclave
        }
        return fresh
    }

    private static func collectLoadedImages() -> (total: Int, nonSystem: [String], digest: String) {
        let count = Int(_dyld_image_count())
        var nonSys: [String] = []
        for i in 0..<count {
            if let cName = _dyld_get_image_name(UInt32(i)) {
                let s = String(cString: cName)
                if !s.hasPrefix("/System/") && !s.hasPrefix("/usr/lib/") {
                    nonSys.append(s)
                }
            }
        }
        nonSys.sort()
        let joined = nonSys.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return (count, nonSys, digest)
    }

    private static func collectDynamicCSStatus() -> (flags: UInt32, valid: Bool, runtime: Bool, debugged: Bool) {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let sc = selfCode else {
            return (0, false, false, false)
        }
        var infoRef: CFDictionary?
        let dynFlags = SecCSFlags(rawValue: kSecCSDynamicInformation)
        let scStatic = unsafeBitCast(sc, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(scStatic, dynFlags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any],
              let status = dict[kSecCodeInfoStatus as String] as? UInt32 else {
            return (0, false, false, false)
        }
        let valid = (status & 0x0000_0001) != 0       // CS_VALID
        let runtime = (status & 0x0001_0000) != 0     // CS_RUNTIME
        let debugged = (status & 0x1000_0000) != 0    // CS_DEBUGGED
        return (status, valid, runtime, debugged)
    }

    static func collectStatus(targetBinaryPath: String? = nil, sandboxActive: Bool = false) -> AttestationStatus {
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let buildStr = sysctlString("kern.osversion")
        let hwModel = sysctlString("hw.model")
        let bootUUID = sysctlString("kern.bootsessionuuid")

        let csr = runStdout("/usr/bin/csrutil", ["status"])
        let sipEnabled = (csr.status == 0) && csr.output.contains("enabled")

        let ssv = runStdout("/usr/bin/csrutil", ["authenticated-root", "status"])
        let ssvSealed = (ssv.status == 0) && ssv.output.contains("enabled")

        let seAvail = SecureEnclave.isAvailable
        let dcDevSupported = DCDevice.current.isSupported
        let dcAppAttestSupported = DCAppAttestService.shared.isSupported

        let rawPath = (targetBinaryPath?.isEmpty == false)
            ? targetBinaryPath!
            : (Bundle.main.executablePath ?? CommandLine.arguments[0])
        let resolvedPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        let binHash = sha256Hex(fileAt: resolvedPath)

        var codeSigned = false
        var hardenedRuntime = false
        var codeIdentifier = ""
        var cdhashHex = ""

        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: resolvedPath) as CFURL
        if SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess, let sc = staticCode {
            let validity = SecStaticCodeCheckValidity(sc, SecCSFlags(), nil)
            var infoRef: CFDictionary?
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            if SecCodeCopySigningInformation(sc, flags, &infoRef) == errSecSuccess,
               let dict = infoRef as? [String: Any] {
                if let ident = dict[kSecCodeInfoIdentifier as String] as? String, validity == errSecSuccess {
                    codeSigned = true
                    codeIdentifier = ident
                }
                if let sigFlags = dict[kSecCodeInfoFlags as String] as? UInt32 {
                    hardenedRuntime = (sigFlags & 0x0001_0000) != 0
                }
                if let unique = dict[kSecCodeInfoUnique as String] as? Data {
                    cdhashHex = unique.map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        let dynCS = collectDynamicCSStatus()
        let imgs = collectLoadedImages()

        return AttestationStatus(
            macosVersion: osStr,
            macosBuild: buildStr,
            hardwareModel: hwModel,
            bootSessionUuid: bootUUID,
            sipEnabled: sipEnabled,
            ssvSealed: ssvSealed,
            secureEnclaveAvailable: seAvail,
            dcDeviceSupported: dcDevSupported,
            dcAppAttestSupported: dcAppAttestSupported,
            codeSigned: codeSigned,
            hardenedRuntime: hardenedRuntime,
            csStatusFlagsHex: String(format: "0x%08x", dynCS.flags),
            csValid: dynCS.valid,
            csRuntime: dynCS.runtime,
            csDebugged: dynCS.debugged,
            dyldImageCount: imgs.total,
            nonSystemImages: imgs.nonSystem,
            nonSystemImagesSha256: imgs.digest,
            sandboxActive: sandboxActive,
            codeIdentifier: codeIdentifier,
            cdhash: cdhashHex,
            binaryPath: resolvedPath,
            binarySha256: binHash
        )
    }

    static func inspectRunningProcess(pid: Int32) -> ChildProcessIntegrity {
        var guest: SecCode?
        let attrs: [String: Any] = [kSecGuestAttributePid as String: NSNumber(value: pid)]
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, SecCSFlags(), &guest) == errSecSuccess,
              let g = guest else {
            return ChildProcessIntegrity(
                pid: pid, codeSigned: false, csStatusFlagsHex: "0x00000000",
                csValid: false, csRuntime: false, csDebugged: false,
                codeIdentifier: "", cdhash: ""
            )
        }
        let gStatic = unsafeBitCast(g, to: SecStaticCode.self)
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(gStatic, flags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any] else {
            return ChildProcessIntegrity(
                pid: pid, codeSigned: false, csStatusFlagsHex: "0x00000000",
                csValid: false, csRuntime: false, csDebugged: false,
                codeIdentifier: "", cdhash: ""
            )
        }
        let status = (dict[kSecCodeInfoStatus as String] as? UInt32) ?? 0
        let ident = (dict[kSecCodeInfoIdentifier as String] as? String) ?? ""
        var cdhash = ""
        if let unique = dict[kSecCodeInfoUnique as String] as? Data {
            cdhash = unique.map { String(format: "%02x", $0) }.joined()
        }
        return ChildProcessIntegrity(
            pid: pid,
            codeSigned: !ident.isEmpty,
            csStatusFlagsHex: String(format: "0x%08x", status),
            csValid: (status & 0x0000_0001) != 0,
            csRuntime: (status & 0x0001_0000) != 0,
            csDebugged: (status & 0x1000_0000) != 0,
            codeIdentifier: ident,
            cdhash: cdhash
        )
    }

    static func generateSignedBundle(
        status: AttestationStatus,
        nonceHex: String,
        targetPid: Int32? = nil
    ) throws -> (json: String, verified: Bool) {
        let seKey = loadOrCreateSecureEnclaveKey()
        let keyClass: String
        let pubX963: Data

        if let seKey = seKey {
            keyClass = "secure-enclave-persistent"
            pubX963 = seKey.publicKey.x963Representation
        } else {
            keyClass = "software-ephemeral"
            pubX963 = Data() // overwritten below
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        var claims: [String: Any] = [
            "nonce": nonceHex,
            "timestamp_utc": ts,
            "macos_version": status.macosVersion,
            "macos_build": status.macosBuild,
            "hardware_model": status.hardwareModel,
            "boot_session_uuid": status.bootSessionUuid,
            "sip_enabled": status.sipEnabled,
            "ssv_sealed": status.ssvSealed,
            "secure_enclave_available": status.secureEnclaveAvailable,
            "dc_device_supported": status.dcDeviceSupported,
            "dc_app_attest_supported": status.dcAppAttestSupported,
            "code_signed": status.codeSigned,
            "hardened_runtime": status.hardenedRuntime,
            "cs_status_flags_hex": status.csStatusFlagsHex,
            "cs_valid": status.csValid,
            "cs_runtime": status.csRuntime,
            "cs_debugged": status.csDebugged,
            "dyld_image_count": status.dyldImageCount,
            "non_system_images_count": status.nonSystemImages.count,
            "non_system_images_sha256": status.nonSystemImagesSha256,
            "sandbox_active": status.sandboxActive,
            "code_identifier": status.codeIdentifier,
            "cdhash": status.cdhash,
            "binary_sha256": status.binarySha256,
            "integrity_scope": "launcher-strong,native-runtime-measured,guest-jit-unattested",
        ]
        if let pid = targetPid {
            let child = inspectRunningProcess(pid: pid)
            claims["target_pid"] = Int(child.pid)
            claims["target_pid_code_signed"] = child.codeSigned
            claims["target_pid_cs_status_flags_hex"] = child.csStatusFlagsHex
            claims["target_pid_cs_valid"] = child.csValid
            claims["target_pid_cs_runtime"] = child.csRuntime
            claims["target_pid_cs_debugged"] = child.csDebugged
            claims["target_pid_code_identifier"] = child.codeIdentifier
            claims["target_pid_cdhash"] = child.cdhash
        }

        let canonicalData = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let canonicalStr = String(data: canonicalData, encoding: .utf8) ?? "{}"

        let finalPubX963: Data
        let sigDER: Data
        if let seKey = seKey {
            finalPubX963 = pubX963
            sigDER = try seKey.signature(for: canonicalData).derRepresentation
        } else {
            let swKey = P256.Signing.PrivateKey()
            finalPubX963 = swKey.publicKey.x963Representation
            sigDER = try swKey.signature(for: canonicalData).derRepresentation
        }

        let keyId = SHA256.hash(data: finalPubX963).map { String(format: "%02x", $0) }.joined()

        let bundle: [String: Any] = [
            "schema": "directmetal.attestation.v2",
            "algorithm": "ECDSA-P256-SHA256-X962",
            "key_class": keyClass,
            "public_key_x963_b64": finalPubX963.base64EncodedString(),
            "key_id_sha256": keyId,
            "signature_b64": sigDER.base64EncodedString(),
            "payload_canonical": canonicalStr,
            "claims": claims,
        ]
        let outData = try JSONSerialization.data(
            withJSONObject: bundle,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let jsonStr = String(data: outData, encoding: .utf8) ?? "{}"
        let ok = verify(bundleJSON: jsonStr, expectedNonce: nonceHex)
        return (jsonStr, ok)
    }

    static func verify(bundleJSON: String, expectedNonce: String? = nil) -> Bool {
        guard let data = bundleJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schema"] as? String,
              (schema == "directmetal.attestation.v2" || schema == "directmetal.attestation.v1"),
              let pubB64 = root["public_key_x963_b64"] as? String,
              let sigB64 = root["signature_b64"] as? String,
              let canonical = root["payload_canonical"] as? String,
              let claims = root["claims"] as? [String: Any],
              let pubData = Data(base64Encoded: pubB64),
              let sigData = Data(base64Encoded: sigB64),
              let payloadData = canonical.data(using: .utf8),
              let signedClaims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return false
        }
        if let keyId = root["key_id_sha256"] as? String {
            let computed = SHA256.hash(data: pubData).map { String(format: "%02x", $0) }.joined()
            if computed != keyId { return false }
        }
        if !NSDictionary(dictionary: signedClaims).isEqual(to: claims) {
            return false
        }
        if let exp = expectedNonce, !exp.isEmpty {
            if (signedClaims["nonce"] as? String) != exp {
                return false
            }
        }
        do {
            let pubKey = try P256.Signing.PublicKey(x963Representation: pubData)
            let sig = try P256.Signing.ECDSASignature(derRepresentation: sigData)
            return pubKey.isValidSignature(sig, for: payloadData)
        } catch {
            return false
        }
    }
}

enum DirectMetalSandbox {
    private static let fallbackTemplate = """
(version 1)
(allow default)
(deny file-read* file-write*
  (subpath "${USER_HOME}/.ssh")
  (subpath "${USER_HOME}/.gnupg")
  (subpath "${USER_HOME}/.aws")
  (subpath "${USER_HOME}/.kube")
  (subpath "${USER_HOME}/Library/Keychains")
  (subpath "${USER_HOME}/Library/Cookies")
  (subpath "${USER_HOME}/Library/Safari")
  (subpath "${USER_HOME}/Library/Application Support/Google/Chrome")
  (subpath "${USER_HOME}/Library/Application Support/Firefox"))
(deny file-read* file-write*
  (subpath "${PREFIXES_ROOT}"))
(allow file-read-metadata
  (literal "${PREFIXES_ROOT}"))
(allow file-read* file-write*
  (subpath "${TARGET_PREFIX}"))
(deny file-write*
  (subpath "${USER_HOME}"))
(allow file-write*
  (subpath "${TARGET_PREFIX}")
  (subpath "${SHADER_CACHE_DIR}")
  (subpath "${OUTPUT_DIR}")
  (subpath "${USER_HOME}/Library/Caches"))
(allow file-read*
  (subpath "${GAME_DIR}")
  (subpath "${SHADER_CACHE_DIR}")
  (subpath "${OUTPUT_DIR}"))
${NETWORK_RULES}
"""

    static func canonicalPath(_ raw: String) -> String {
        var cur = URL(fileURLWithPath: raw)
        var tail: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: cur.path) && cur.path != "/" {
            tail.insert(cur.lastPathComponent, at: 0)
            cur.deleteLastPathComponent()
        }
        var resolved = cur.resolvingSymlinksInPath()
        for part in tail {
            resolved.appendPathComponent(part)
        }
        return resolved.path
    }

    private static func escapeSBPL(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func resolveTemplateString() -> String {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("directmetal_game.sb.tmpl"),
           let txt = try? String(contentsOf: resURL, encoding: .utf8) {
            return txt
        }
        let repoCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("sandbox/profiles/directmetal_game.sb.tmpl")
        if let txt = try? String(contentsOf: repoCandidate, encoding: .utf8) {
            return txt
        }
        return fallbackTemplate
    }

    static func inferOutputDir(from extraArgs: [String], explicit: String?, targetPrefix: String) -> String {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        for (idx, arg) in extraArgs.enumerated() {
            if (arg == "--out" || arg == "-o") && idx + 1 < extraArgs.count {
                let raw = extraArgs[idx + 1]
                let upper = raw.uppercased()
                if upper.hasPrefix("Z:\\") || upper.hasPrefix("Z:/") {
                    let posix = String(raw.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
                    return posix.hasPrefix("/") ? posix : "/\(posix)"
                }
            }
        }
        return targetPrefix
    }

    static func writeProfile(
        prefixesRoot: String,
        targetPrefix: String,
        gameDir: String,
        shaderCacheDir: String,
        outputDir: String,
        allowNetwork: Bool
    ) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let netRules = allowNetwork
            ? "(allow network*)"
            : "(deny network-outbound (remote ip))\n(deny network-inbound (local ip))\n(allow network* (local unix-socket))\n(allow network* (remote unix-socket))"

        var rendered = resolveTemplateString()
        let subs: [(String, String)] = [
            ("${USER_HOME}", escapeSBPL(canonicalPath(home))),
            ("${PREFIXES_ROOT}", escapeSBPL(canonicalPath(prefixesRoot))),
            ("${TARGET_PREFIX}", escapeSBPL(canonicalPath(targetPrefix))),
            ("${GAME_DIR}", escapeSBPL(canonicalPath(gameDir))),
            ("${SHADER_CACHE_DIR}", escapeSBPL(canonicalPath(shaderCacheDir))),
            ("${OUTPUT_DIR}", escapeSBPL(canonicalPath(outputDir))),
            ("${NETWORK_RULES}", netRules),
        ]
        for (k, v) in subs {
            rendered = rendered.replacingOccurrences(of: k, with: v)
        }

        let profileURL = URL(fileURLWithPath: targetPrefix, isDirectory: true)
            .appendingPathComponent(".directmetal_sandbox.sb")
        try rendered.write(to: profileURL, atomically: true, encoding: .utf8)
        return profileURL
    }
}
