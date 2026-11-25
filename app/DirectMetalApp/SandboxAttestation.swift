import CryptoKit
import Darwin
import DeviceCheck
import Foundation
import Security

struct AttestationStatus: Codable {
    let macosVersion: String
    let macosBuild: String
    let hardwareModel: String
    let sipEnabled: Bool
    let ssvSealed: Bool
    let dcAppAttestSupported: Bool
    let codeSigned: Bool
    let hardenedRuntime: Bool
    let sandboxActive: Bool
    let codeIdentifier: String
    let cdhash: String
    let binaryPath: String
    let binarySha256: String

    enum CodingKeys: String, CodingKey {
        case macosVersion = "macos_version"
        case macosBuild = "macos_build"
        case hardwareModel = "hardware_model"
        case sipEnabled = "sip_enabled"
        case ssvSealed = "ssv_sealed"
        case dcAppAttestSupported = "dc_app_attest_supported"
        case codeSigned = "code_signed"
        case hardenedRuntime = "hardened_runtime"
        case sandboxActive = "sandbox_active"
        case codeIdentifier = "code_identifier"
        case cdhash
        case binaryPath = "binary_path"
        case binarySha256 = "binary_sha256"
    }
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

    static func collectStatus(targetBinaryPath: String? = nil, sandboxActive: Bool = false) -> AttestationStatus {
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let buildStr = sysctlString("kern.osversion")
        let hwModel = sysctlString("hw.model")

        let csr = runStdout("/usr/bin/csrutil", ["status"])
        let sipEnabled = (csr.status == 0) && csr.output.contains("enabled")

        let ssv = runStdout("/usr/bin/csrutil", ["authenticated-root", "status"])
        let ssvSealed = (ssv.status == 0) && ssv.output.contains("enabled")

        let dcSupported = DCAppAttestService.shared.isSupported

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
                    hardenedRuntime = (sigFlags & 0x00010000) != 0
                }
                if let unique = dict[kSecCodeInfoUnique as String] as? Data {
                    cdhashHex = unique.map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        return AttestationStatus(
            macosVersion: osStr,
            macosBuild: buildStr,
            hardwareModel: hwModel,
            sipEnabled: sipEnabled,
            ssvSealed: ssvSealed,
            dcAppAttestSupported: dcSupported,
            codeSigned: codeSigned,
            hardenedRuntime: hardenedRuntime,
            sandboxActive: sandboxActive,
            codeIdentifier: codeIdentifier,
            cdhash: cdhashHex,
            binaryPath: resolvedPath,
            binarySha256: binHash
        )
    }

    static func generateSignedBundle(status: AttestationStatus, nonceHex: String) throws -> (json: String, verified: Bool) {
        let privKey = P256.Signing.PrivateKey()
        let pubX963 = privKey.publicKey.x963Representation
        let keyId = SHA256.hash(data: pubX963).map { String(format: "%02x", $0) }.joined()
        let ts = ISO8601DateFormatter().string(from: Date())

        let claims: [String: Any] = [
            "nonce": nonceHex,
            "timestamp_utc": ts,
            "macos_version": status.macosVersion,
            "macos_build": status.macosBuild,
            "hardware_model": status.hardwareModel,
            "sip_enabled": status.sipEnabled,
            "ssv_sealed": status.ssvSealed,
            "dc_app_attest_supported": status.dcAppAttestSupported,
            "code_signed": status.codeSigned,
            "hardened_runtime": status.hardenedRuntime,
            "sandbox_active": status.sandboxActive,
            "code_identifier": status.codeIdentifier,
            "cdhash": status.cdhash,
            "binary_sha256": status.binarySha256,
        ]

        let canonicalData = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let canonicalStr = String(data: canonicalData, encoding: .utf8) ?? "{}"
        let signature = try privKey.signature(for: canonicalData)
        let sigDER = signature.derRepresentation

        let bundle: [String: Any] = [
            "schema": "directmetal.attestation.v1",
            "algorithm": "ECDSA-P256-SHA256-X962",
            "public_key_x963_b64": pubX963.base64EncodedString(),
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
              let schema = root["schema"] as? String, schema == "directmetal.attestation.v1",
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
