# Security Policy

## Supported Versions

Security fixes are released on the latest `1.x` release line targeting Apple Silicon (`arm64`) Macs running macOS 15.0 Sequoia and newer:

| Version | Supported | Target Platform |
| :--- | :--- | :--- |
| `1.0.x` | Yes | Apple Silicon (`M1`–`M5+`), macOS 15.0+ |
| `< 1.0` | No | Pre-release development snapshots |

---

## Responsible Disclosure

**Please do not open public GitHub issues for suspected security vulnerabilities** (such as Seatbelt sandbox escapes, archive path-traversal bugs, SHA-256 or code-signature verification bypasses, or Secure Enclave attestation flaws).

Instead, report vulnerabilities privately through **[GitHub Private Vulnerability Reporting](https://github.com/amoham42/DirectMetal/security/advisories/new)** on this repository.

Include:
1. Affected component (`app/DirectMetalApp/`, `sandbox/dm_sandbox`, `sandbox/dm_attestation`, `ShaderCacheManager`, `RuntimeManager`, etc.) and commit SHA or release tag.
2. macOS version/build (`sw_vers`) and Apple Silicon hardware model.
3. Minimal reproduction steps or proof-of-concept.

We aim to acknowledge reports within **72 hours**, provide a triage assessment within **7 days**, and coordinate a fix and credit prior to public disclosure.

---

## DirectMetal Security & Trust Model

DirectMetal runs untrusted Windows PE executables (`x86_64` and `x86`) translated through ARM64EC + FEX-Emu (or Rosetta 2) atop Wine and Metal. Its defense-in-depth architecture separates launcher integrity, per-game filesystem/network confinement, supply-chain verification, and opt-in hardware attestation.

### 1. Per-Game Kernel Seatbelt Sandbox (`sandbox/`)

When launched with `--sandbox` or `--sandbox-offline` (or `enableSandbox: true` in the Game Library), DirectMetal renders `sandbox/profiles/directmetal_game.sb.tmpl` and executes the game under macOS kernel Seatbelt (`sandbox-exec` / `libdm_sandbox.a`):

- **Cross-Game Isolation:** Denies `file-read*` and `file-write*` across `~/Library/Application Support/DirectMetal/Prefixes` (`EPERM`), permitting `file-read-metadata` on the parent directory solely for `realpath()` traversal and full read-write access only inside the active game's APFS CoW prefix (`${TARGET_PREFIX}`).
- **Credential & Personal Data Protection:** Explicitly blocks read/write access (`EPERM`) to `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/Library/Keychains`, `~/Library/Cookies`, `~/Library/Safari`, and Chrome/Firefox profile directories.
- **Home Write Confinement:** Denies arbitrary writes under `$HOME`, allowing writes exclusively to the target prefix, per-title shader cache (`${SHADER_CACHE_DIR}`), explicit capture output directory, and `~/Library/Caches`.
- **Optional Offline Mode (`--sandbox-offline`):** Blocks outbound and inbound IP sockets while keeping local `AF_UNIX` and Mach IPC alive for `wineserver` and Metal/CoreAudio services.

### 2. Hardware-Backed Attestation v2 (`SandboxAttestation.swift` & `libdm_attestation.a`)

DirectMetal provides an **opt-in**, privacy-preserving attestation protocol (`directmetal.attestation.v2`) via `DirectMetal attest [--pid <pid>] --nonce <hex>` and `DirectMetal verify-attest`:

- **Secure Enclave Hardware Key:** Claims are signed (`ECDSA-P256-SHA256-X962`) over canonical sorted JSON (`payload_canonical`) using a persistent, non-exportable **Apple Silicon Secure Enclave P-256** private key (`key_class: "secure-enclave-persistent"`), falling back to labeled ephemeral software keys only if Secure Enclave hardware is unavailable.
- **Measured Platform & Process Claims:** Binds a verifier's challenge `nonce` to `sip_enabled`, `ssv_sealed`, `boot_session_uuid` (`kern.bootsessionuuid`), `dc_device_supported`, `dc_app_attest_supported`, static `SecStaticCode` `cdhash` and executable SHA-256, dynamic `SecCodeCopySelf` flags (`CS_VALID`, `CS_RUNTIME`, `CS_DEBUGGED`), `_dyld_image_count()` non-system dylib SHA-256 digest, and optional live child process inspection via `SecCodeCopyGuestWithAttributes`.
- **Explicit Integrity Scope:** Every bundle declares `"integrity_scope": "launcher-strong,native-runtime-measured,guest-jit-unattested"` — honestly distinguishing verified native macOS binaries from mutable x86-64 guest JIT pages inside a Wine process.

### 3. Supply-Chain & Artifact Verification

- **On-Demand Runtime Installer (`RuntimeManager.swift`):** `DirectMetal-Lite.app` streams runtime downloads through `CryptoKit.SHA256` and rejects any archive whose digest does not match the pinned 64-character SHA-256 checksum before extraction. Extracted `MetalSharp-Wine.app` bundles are verified with `codesign --verify --strict --deep` (preserving Apple Developer ID signatures and `com.apple.developer.cross-architecture-support`) before atomic `rename()` installation.
- **Double SHA-256 Cloud Shader Cache (`ShaderCacheManager.swift`):** `DirectMetal cache sync` verifies (1) the outer `.dmcache.tar.gz` SHA-256 digest against `directmetal.shadercache.index.v1` before invoking `tar`, (2) every relative file path against `..` or absolute `/` path-traversal attempts, and (3) every individual inner file's SHA-256 digest and `(gpu_family, macos_build)` compatibility against `directmetal.shadercache.v1` `manifest.json`.
- **Hardened Runtime (`sandbox/DirectMetal.entitlements`):** App bundles are signed with `--options runtime`. Entitlements (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`) are scoped strictly to what Wine/FEX x86-64 guest execution and Vulkan layer loading require; `com.apple.security.get-task-allow` and `cs.disable-executable-page-protection` are never enabled.

### 4. Explicit Non-Goals & Platform Boundaries

DirectMetal **never** bypasses, disables, or spoofs:
- macOS **System Integrity Protection (SIP)**, **Signed System Volume (SSV)**, **Gatekeeper**, or **TCC** user privacy prompts.
- Commercial **game DRM** (such as SteamStub, Epic, or publisher ownership checks — users must run games they legitimately own with their storefront client when required).
- Windows **Ring-0 kernel anti-cheat drivers (`.sys`)** or hypervisor checks; multiplayer support relies strictly on studio opt-in to user-space attestation (`DirectMetal attest`).
