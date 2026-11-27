# DirectMetal

A unified, Apple Silicon–first (M1 and newer) DirectX compatibility runtime for macOS — designed as **one self-contained package** that runs Windows DirectX 10/11/12 games at near-native performance with zero manual tinkering.

## Vision

Instead of stacking multi-layer translators (`DirectX → Vulkan → MoltenVK → Metal`) and forcing users to configure bottles, wrappers, and backends, **DirectMetal** targets Apple Silicon hardware directly:

- **Direct-to-Metal Graphics (`D3D10/11/12 → Metal 3/4`):** Unified open-source Metal backend built around direct DXBC/DXIL → Metal IR translation (leveraging DXMT / Mullion architectures) with no Vulkan middleman.
- **Unified Memory (UMA) Zero-Copy:** Maps DirectX upload/readback/staging buffers onto `MTLStorageModeShared` pages to eliminate fake PCIe copies and cut memory pressure on 8 GB–16 GB Macs.
- **Tile-Based GPU (TBDR) Optimization:** Render-pass coalescing, aggressive `MTLLoadActionDontCare` / `MTLStoreActionDontCare`, and `MTLStorageModeMemoryless` transient targets to keep attachments inside on-chip tile memory.
- **Pre-Compiled Shader Cache (`MTLBinaryArchive`):** Keyed by `(game_build, apple_gpu_family, macos_version)` to eliminate shader compilation stutter across the fixed set of Apple Silicon GPU families (`Apple7` M1 through M4/M5+).
- **Native ARM64 Host + Thunked x86-64 Guest:** Keeps the Win32 runtime, sync primitives (`os_sync_wait_on_address` / Mach `msync`), Metal backend, MetalFX upscaling bridge, CoreAudio, and GameController native ARM64 while isolating x86-64 translation to game code only (Rosetta 2 today; ARM64EC + FEX-Emu long-term).
- **Platform-Attested Isolation Sandbox:** Signed, hardened per-game container designed for opt-in user-space anti-cheat attestation rooted in macOS hardware security (SIP / SSV / Hardened Runtime / App Attest).

## Hardware Verification Loop

Development uses a two-machine ground-truth testing pipeline:
- **Target Machine:** Apple Silicon Mac (`M1 Pro` baseline + `M4`) running native Metal builds, `gpucapture`/`gpudebug` profiling, and `MTLBinaryArchive` generation.
- **Reference Oracle:** Windows x64 laptop (AMD CPU + NVIDIA RTX 3070) running native DirectX 11/12 conformance suites, `dxc`/`fxc` shader compilation, and RenderDoc/PIX frame captures for pixel-accurate visual and performance regression diffs.

## Status

**Phases 0–4 verified on Apple Silicon (`M1 Pro`, macOS `27.2.1` `26B131`) against Windows 11 + NVIDIA RTX 3070 ground truth:**

- **Visual & Compute Conformance:** **25 / 25 (100.0%)** passing (`10/10` D3D11, `9/9` D3D12 **`FL 12_2`**, `6/6` D3D12 SM 6.0 DXIL Engine Patterns **`FL 12_2`**) — Mean SSIM `0.999841`, Min PSNR `54.32 dB` (see [COMPATIBILITY.md](COMPATIBILITY.md) and [docs/ENGINE_COMPATIBILITY_MATRIX.md](docs/ENGINE_COMPATIBILITY_MATRIX.md)).
- **Apple Silicon Optimizations:** UMA `MTLStorageModeShared` (`1.51x`, `-66.2%` mem), TBDR `MTLStorageModeMemoryless` (`2.71x`, `-64.75 MiB` DRAM), local + cloud SHA-256 verified `MTLBinaryArchive` (`66.7x` unit PSO / `17.07x` end-to-end warm cache / `DirectMetal cache export|import`), live sub-native **Metal 4 MetalFX Temporal** (`1248×812 → 1512×984` on UE5 `REANIMAL` via `METALSHARP_DLSS_SCALE` + `nvngx.dll`) & D3D11/D3D12 MetalFX Spatial (`1.72x`–`2.55x`), and APFS CoW per-game prefixes (`0.41 ms`).
- **100% Post-Rosetta ARM64EC + FEX Execution (`Wine 11.22` + `USync 6` + `Mullion 2702d6e1` + `MetalVulkan 7.0`):** Preserves Apple's signed `com.apple.developer.cross-architecture-support` entitlement for **both 64-bit and 32-bit Windows games** with zero Rosetta 2! With `--perf-mode ultra` on macOS `27.2.1`: **`4,114.4 FPS`** D3D11 (**`3,279.8` 1%-low = `96.5%` of native RTX 3070 1%-low!!**), **`3,112.1 FPS`** D3D12 **`FL 12_2`** (**`2,489.4` 1%-low = `68.4%` of RTX 3070 1%-low**), and **`1,658.4 FPS`** (**`1,400.9` 1%-low = `5.25×` Rosetta 2 1%-low**) sandboxed `1024×1024` SM 6.0 Deferred PBR! **4 / 4 live retail games run zero-config on 100% native ARM64EC+FEX:** **Hades** (`120.00 FPS` locked, `26%` GPU, `--sandbox`), **REANIMAL** (UE5 DX12 **`FL 12_2`** + bundled `d3d12_guard.dll` + Metal 4 MetalFX Temporal at **`47%` GPU**), **Team Fortress 2** (x64 D3D9, `DXVK 3.1.1` + `KosmicKrisp 26.99.99`, `19%` GPU), and **Need for Speed: Hot Pursuit** (32-bit x86 D3D9, **zero flags**, `DXVK 3.1.1` + `KosmicKrisp 26.99.99`, **`22%` GPU**, zero Rosetta 2!).
- **Per-Game Isolation & Hardware-Backed Attestation v2 (Swift + C/Obj-C++ SDK):** Hardened Runtime (`--options runtime`, `hardened_runtime: true`) `.app` bundle + upgraded SwiftUI GUI, macOS Seatbelt sandbox (`DirectMetal run --sandbox`, `5/5` kernel `EPERM` tests), and **Attestation v2** (`DirectMetal attest [--pid <pid>]` / `verify-attest` + `libdm_attestation.a`) backed by a persistent non-exportable **Apple Silicon Secure Enclave** P-256 hardware key, **`DCAppAttestService.isSupported: true`** & `DCDevice.isSupported: true` on macOS 27.2.1, `kern.bootsessionuuid`, live child-PID `SecCodeCopyGuestWithAttributes` inspection, dynamic `SecCodeCopySelf` status, and `_dyld_image_count` image verification.

- **Consumer Launcher, Slim `.app`, DMG Installer & Cloud Shader Cache CDN:** Two-pane SwiftUI **Game Library** (`GameLibraryManager.swift` + `DirectMetalGUI.swift` + `DirectMetal library scan|list|show|set|add|remove|play`) with Prefix/Steam/folder auto-discovery and per-game saved settings; generated native macOS squircle **`AppIcon.icns`** (`scripts/generate_icon.swift`); **slim 100% post-Rosetta `.app` default** (`./scripts/package_app.sh`, opt-in `--include-rosetta`); compressed **`DirectMetal-macOS-arm64.dmg`** (`1.9 GB`) with optional Developer ID signing & `notarytool` stapling (`scripts/build_dmg.sh`); and double SHA-256 verified cloud shader cache CDN indexing & sync (`scripts/publish_shader_cache.sh` + `DirectMetal cache sync <index.json>`).

### Quickstart

```bash
# Build slim 100% post-Rosetta DirectMetal.app + DMG installer
./scripts/package_app.sh
./scripts/build_dmg.sh

# Scan games into the persistent Game Library & launch with per-game saved settings
DM=./dist/DirectMetal.app/Contents/MacOS/DirectMetal
"$DM" library scan
"$DM" library list
"$DM" library set Hades perf=ultra retina=true hud=true sandbox=true
"$DM" library play Hades

# Publish & sync cloud shader caches (double SHA-256 verified)
./scripts/publish_shader_cache.sh --export-local --dir /tmp/cdn --base-url https://cdn.example.com/shaders
"$DM" cache sync https://cdn.example.com/shaders/index.json --exe /path/to/game.exe

# Hardware Secure Enclave + DCAppAttest attestation v2 & verification
"$DM" attest --pid $$ --nonce aabbccdd00112233 --sandbox > /tmp/attest.json
"$DM" verify-attest /tmp/attest.json --nonce aabbccdd00112233
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and [ROADMAP.md](ROADMAP.md) for the engineering plan.
