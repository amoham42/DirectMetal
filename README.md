# DirectMetal

[![Apple Silicon CI](https://github.com/amoham42/DirectMetal/actions/workflows/ci.yml/badge.svg)](https://github.com/amoham42/DirectMetal/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/amoham42/DirectMetal)](https://github.com/amoham42/DirectMetal/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Apple Silicon macOS 15+](https://img.shields.io/badge/Platform-Apple%20Silicon%20macOS%2015%2B-black.svg)](#status)

A unified, Apple Silicon–first (M1 through M4/M5) DirectX 9/10/11/12 compatibility runtime for macOS — shipping as a **`2.9 MB` `DirectMetal-Lite.app`** (with SHA-256 & Apple Developer ID verified on-demand runtime install) or a **`3.7 GB` self-contained offline `DirectMetal.app`** that runs 64-bit and 32-bit Windows games with zero manual tinkering.

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

**Phases 0–4 verified across two Apple Silicon generations (`Apple M1 Pro` on macOS `27.2.1` + `Apple M4` on macOS `26.7.1`) against Windows 11 + NVIDIA RTX 3070 ground truth:**

| Machine | GPU Family | macOS | Conformance vs RTX 3070 | D3D12 Ultra+Warm | Deferred PBR Ultra+Warm | Warm Launch (`hostname.exe`) |
| :--- | :--- | :--- | :--- | ---: | ---: | ---: |
| **Apple M1 Pro** (`MacBookPro18,3`) | `Apple7` (14-core) | `27.2.1` (`26B131`) | **`25 / 25`** (`Mean SSIM 0.999841`) | **`2,694 FPS`** (`0.738 s`) | **`1,569 FPS`** (`0.665 s`) | **`0.07 s`** (`10×`) |
| **Apple M4** (`Mac16,1`, `DirectMetal-Lite`) | `Apple9` (10-core) | `26.7.1` (`25G241`) | **`25 / 25`** (`Mean SSIM 0.999844`) | **`4,490 FPS`** (`0.490 s`) | **`2,092 FPS`** (`0.433 s`) | **`0.10 s`** (`10.7×`) |

- **Visual & Compute Conformance:** **25 / 25 (100.0%)** passing (`10/10` D3D11, `9/9` D3D12 **`FL 12_2`**, `6/6` D3D12 SM 6.0 DXIL Engine Patterns **`FL 12_2`**) — Mean SSIM `0.999841–0.999844`, Min PSNR `54.32 dB` (see [COMPATIBILITY.md](COMPATIBILITY.md) and [docs/ENGINE_COMPATIBILITY_MATRIX.md](docs/ENGINE_COMPATIBILITY_MATRIX.md)).
- **Apple Silicon Optimizations:** UMA `MTLStorageModeShared` (`1.51x`, `-66.2%` mem), TBDR `MTLStorageModeMemoryless` (`2.71x`, `-64.75 MiB` DRAM), local + cloud SHA-256 verified `MTLBinaryArchive` (`66.7x` unit PSO / `17.07x` end-to-end warm cache / `DirectMetal cache export|import`), live sub-native **Metal 4 MetalFX Temporal** (`1248×812 → 1512×984` on UE5 `REANIMAL` via `METALSHARP_DLSS_SCALE` + `nvngx.dll`) & D3D11/D3D12 MetalFX Spatial (`1.72x`–`2.55x`), and APFS CoW per-game prefixes (`0.41 ms`).
- **100% Post-Rosetta ARM64EC + FEX Execution (`Wine 11.22` + `USync 6` + `Mullion 2702d6e1` + `MetalVulkan 7.0`):** Preserves Apple's signed `com.apple.developer.cross-architecture-support` entitlement for **both 64-bit and 32-bit Windows games** with zero Rosetta 2! With `--perf-mode ultra` on macOS `27.2.1`: **`4,114.4 FPS`** D3D11 (**`3,279.8` 1%-low = `96.5%` of native RTX 3070 1%-low!!**), **`3,112.1 FPS`** D3D12 **`FL 12_2`** (**`2,489.4` 1%-low = `68.4%` of RTX 3070 1%-low**), and **`1,658.4 FPS`** (**`1,400.9` 1%-low = `5.25×` Rosetta 2 1%-low**) sandboxed `1024×1024` SM 6.0 Deferred PBR! **4 / 4 live retail games run zero-config on 100% native ARM64EC+FEX:** **Hades** (`120.00 FPS` locked, `26%` GPU, `--sandbox`), **REANIMAL** (UE5 DX12 **`FL 12_2`** + bundled `d3d12_guard.dll` + Metal 4 MetalFX Temporal at **`47%` GPU**), **Team Fortress 2** (x64 D3D9, `DXVK 3.1.1` + `KosmicKrisp 26.99.99`, `19%` GPU), and **Need for Speed: Hot Pursuit** (32-bit x86 D3D9, **zero flags**, `DXVK 3.1.1` + `KosmicKrisp 26.99.99`, **`22%` GPU**, zero Rosetta 2!).
- **Per-Game Isolation & Hardware-Backed Attestation v2 (Swift + C/Obj-C++ SDK):** Hardened Runtime (`--options runtime`, `hardened_runtime: true`) `.app` bundle + upgraded SwiftUI GUI, macOS Seatbelt sandbox (`DirectMetal run --sandbox`, `5/5` kernel `EPERM` tests), and **Attestation v2** (`DirectMetal attest [--pid <pid>]` / `verify-attest` + `libdm_attestation.a`) backed by a persistent non-exportable **Apple Silicon Secure Enclave** P-256 hardware key, **`DCAppAttestService.isSupported: true`** & `DCDevice.isSupported: true` on macOS 27.2.1, `kern.bootsessionuuid`, live child-PID `SecCodeCopyGuestWithAttributes` inspection, dynamic `SecCodeCopySelf` status, and `_dyld_image_count` image verification.

- **Consumer Launcher, `3.7 GB` Offline / `2.9 MB` Lite `.app`, `1.0 GB` ULMO / `2.8 MiB` Lite DMGs, Warm Launch Pool & Cloud Shader Cache CDN:** Two-pane SwiftUI **Game Library** (`GameLibraryManager.swift` + `DirectMetalGUI.swift` + `DirectMetal library scan|list|show|set|add|remove|play`) with Prefix/Steam/folder auto-discovery and per-game saved settings; lossless-optimized CoreGraphics **`AppIcon.icns`** (`1.57 MB → 1.18 MB`, `-25.0%`); **dehydrated base-prefix** (`scripts/dehydrate_base_prefix.py` shrinks `2,740 MiB` → **`0.62 MiB`**, `-99.98%`, hydrated on first launch via zero-copy parallel APFS `clonefile()` in **`151 ms`**) + atomic read-only **hardlink deduplication** inside `MetalSharp-Wine.app` (`scripts/dedup_bundle_hardlinks.py`, **`-75.70 MiB`** with `codesign --verify --strict --deep` intact) + Swift `-O -whole-module-optimization` + `strip -x` bringing offline `DirectMetal.app` down from **`7.5 GB` → `3.7 GB`** (`-50.7%`); **`DirectMetal-Lite.app` (`2.9 MB`, `2.8 MiB` DMG — `99.96%` smaller!)** with built-in SHA-256 & Apple Developer ID verified on-demand runtime installer (`RuntimeManager.swift` + `DirectMetal runtime install|status|remove`, **`11.86 s`** local HTTP install); fast Apple **ULFO (LZFSE)** offline DMG (**`1.3 GB`, `43.3 s` build**) and **`--ultra-compress` ULMO (LZMA)** offline DMG (**`1.0 GB` / `1,059.4 MiB`, `-45.5%`** vs `1.9 GB` UDZO) with optional Developer ID signing/`notarytool` stapling (`scripts/build_dmg.sh`); **persistent warm `wineserver` pool** (`WineserverPool`, `--warm-server`, GUI background pre-warm + clean quit shutdown) cutting repeat launches **`0.85 s` → `0.07–0.22 s`** (**`3.8×–10×` faster**) and full suite wall-clock runs **`1.84 s` → `0.665 s`** (**`2.77×` faster**); **Apple Silicon P-Core QoS** (`.userInteractive` + `.latencyCritical` activity), fast-path `d3d12_guard.c` (`-O3`), cached `PEInspector` (`0.02 ms`), dirty-checked Retina PPI registry writes, and `--perf-mode ultra` (`MULLION_D3D12_GPU_ERRORS=0`, `MULLION_D3D12_NATIVE16=1`, `FEX_TSOENABLED=0`, `FEX_DISABLETELEMETRY=1`, `FEX_EXTENDEDVOLATILEMETADATA=1`: **`4,090–4,185 FPS`** D3D11 / `3,103–3,263` 1%-low, **`2,694 FPS`** D3D12 / `2,189` 1%-low, **`1,568.9 FPS`** Deferred PBR / **`1,320.7`** 1%-low = **`3.54×`** Rosetta 2); and double SHA-256 verified cloud shader cache CDN indexing & sync (`scripts/publish_shader_cache.sh` + `DirectMetal cache sync <index.json>`).

### Quickstart

```bash
# Build offline DirectMetal.app (3.7 GB) + ULFO (1.3 GB) or ULMO (1.0 GB) DMG
./scripts/package_app.sh
./scripts/build_dmg.sh                     # fast ULFO (43s, 1.3 GB)
./scripts/build_dmg.sh --ultra-compress    # max-compression ULMO (1.0 GB)

# Or build DirectMetal-Lite.app (2.9 MB) + Lite DMG (2.8 MiB) with verified first-run runtime setup
./scripts/package_app.sh --lite
./scripts/build_dmg.sh --lite

# Scan games into the persistent Game Library & launch with per-game saved settings + warm server
DM=./dist/DirectMetal.app/Contents/MacOS/DirectMetal
"$DM" library scan
"$DM" library list
"$DM" library set Hades perf=ultra retina=true hud=true sandbox=true
"$DM" library play Hades --warm-server

# Manage verified ARM64EC runtime (Lite mode) & warm launch servers
"$DM" runtime status --json
"$DM" runtime install
"$DM" runtime stop-servers

# Publish & sync cloud shader caches (double SHA-256 verified)
./scripts/publish_shader_cache.sh --export-local --dir /tmp/cdn --base-url https://cdn.example.com/shaders
"$DM" cache sync https://cdn.example.com/shaders/index.json --exe /path/to/game.exe

# Hardware Secure Enclave + DCAppAttest attestation v2 & verification
"$DM" attest --pid $$ --nonce aabbccdd00112233 --sandbox > /tmp/attest.json
"$DM" verify-attest /tmp/attest.json --nonce aabbccdd00112233

# Inspect community game presets, display HDR/ProMotion & controllers, or check updates
"$DM" info
"$DM" profiles list
"$DM" update check

# Developer ergonomics (lint, C/Obj-C++ subsystem tests, Python diff tests & Lite smoke)
make help
make ci
```

## Contributing & Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — System architecture & DirectX-to-Metal stack
- [ROADMAP.md](ROADMAP.md) — Completed Phases 0–4 milestones
- [COMPATIBILITY.md](COMPATIBILITY.md) & [docs/ENGINE_COMPATIBILITY_MATRIX.md](docs/ENGINE_COMPATIBILITY_MATRIX.md) — Conformance & retail game matrix
- [CONTRIBUTING.md](CONTRIBUTING.md) — Developer setup, `Makefile` workflow, adding presets to `runtime/profiles/game_profiles.json`
- [SECURITY.md](SECURITY.md) — Seatbelt sandbox, Secure Enclave attestation & SHA-256 trust model
- [CHANGELOG.md](CHANGELOG.md) — Release history
- [LICENSE](LICENSE) — MIT License
