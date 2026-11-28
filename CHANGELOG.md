# Changelog

All notable changes to **DirectMetal** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-27

Initial stable Apple Silicon (`arm64`) release of DirectMetal, verified on **Apple M1 Pro (`macOS 27.2.1` `26B131`)** and **Apple M4 (`macOS 26.7.1`)** against native **Windows 11 + NVIDIA RTX 3070** ground-truth reference captures.

### Added

- **Direct-to-Metal Conformance (`25 / 25` — `100.0%` Pass Rate):**
  - `10 / 10` D3D11 (`Feature Level 11_1`), `9 / 9` D3D12 (`Feature Level 12_2`), and `6 / 6` D3D12 Shader Model 6.0 DXIL Engine Pattern workloads (`eng_01_deferred_gbuffer` through `eng_06_bindless`) verified pixel-accurate against RTX 3070 reference captures (`Mean SSIM = 0.999841`, `Min PSNR = 53.86–54.32 dB`) via `tools/diff_harness.py`.
- **100% Post-Rosetta ARM64EC + FEX-Emu Execution (`MetalSharp-Wine v10.5`):**
  - Native `arm64` host execution (`Wine 11.22` + `USync 6` + `Mullion 2702d6e1` + `DXVK 3.1.1` + `KosmicKrisp 26.99.99`) preserving `com.apple.developer.cross-architecture-support` for both 64-bit and 32-bit Windows executables with zero Rosetta 2 dependency on `macOS 26.4+` / `27.2.1`.
  - `--perf-mode ultra` delivering `4,114.4 FPS` (`3,279.8` 1%-low) on `d3d11_bench_frame`, `3,112.1 FPS` (`2,489.4` 1%-low) on `d3d12_bench_frame` (`FL 12_2`), and `1,658.4 FPS` (`1,400.9` 1%-low) on sandboxed `1024x1024` SM 6.0 Deferred PBR.
- **Apple Silicon Graphics, Memory & Upscaling Subsystems:**
  - **UMA Zero-Copy Allocator (`graphics/dm_metal_core`):** `MTLStorageModeShared` fast path (`1.51x` throughput, `-66.2%` memory footprint).
  - **TBDR Render-Pass Coalescer (`graphics/dm_metal_core`):** Transient attachment detection with `MTLStorageModeMemoryless` (`2.71x` speedup, `-64.75 MiB` DRAM bandwidth saved).
  - **D3D12 Placed-Resource Alignment Guard (`graphics/dm_d3d12_placed_guard`):** `d3d12_x64.dll` interceptor promoting misaligned UE5 32 KiB placed allocations to `CreateCommittedResource` with zero conformance overhead.
  - **Universal Vulkan Compatibility Layer (`graphics/dm_vk_compat`):** `VK_LAYER_DIRECTMETAL_mvk_compat` (`arm64` + `x86_64`) enabling ARM64X DXVK + KosmicKrisp and 32-bit MoltenVK host-memory paths.
  - **MetalFX Spatial & Metal 4 MetalFX Temporal Upscaling (`upscaling/`):** `dm_metalfx_bridge` (`1.72x`–`2.55x` FPS) plus automatic PE/plugin detection (`nvngx_dlss`, `amd_fidelityfx`, `libxess`) routing `--upscale` to sub-native Metal 4 MetalFX Temporal and D3D11/D3D12 spatial upscalers.
- **Compact `DirectMetal-Lite` & Offline App / DMG Distribution (`scripts/`):**
  - **`DirectMetal-Lite.app` (`2.3–2.9 MB` bundle, `2.8 MiB` DMG):** Ships native SwiftUI launcher, Vulkan compat layer, `d3d12_x64.dll` guard, community profiles, and streaming SHA-256 + `codesign --verify --strict --deep` on-demand runtime installer (`RuntimeManager.swift`, `DirectMetal runtime install|status|remove`).
  - **Offline `DirectMetal.app` (`3.7 GB`) & Compressed DMGs:** Dehydrated golden base-prefix (`0.62 MiB`, hydrated via parallel APFS `clonefile()` in `~151 ms`), atomic hardlink deduplication (`-75.70 MiB`), `1.3 GB` fast ULFO (LZFSE) DMG, and `1.0 GB` `--ultra-compress` ULMO (LZMA) DMG with optional Apple Developer ID signing and `notarytool` stapling.
- **Consumer Game Library, Warm `wineserver` Pool & Native Peripherals (`app/DirectMetalApp/`, `runtime/`):**
  - Two-pane SwiftUI **Game Library** and CLI (`DirectMetal library scan|list|show|set|add|remove|play`) with Steam/prefix/folder auto-discovery, community game profiles (`runtime/profiles/game_profiles.json`), cached `PEInspector` (`0.02 ms`), Apple Silicon P-Core QoS, and dirty-checked Retina PPI scaling.
  - **Persistent Warm `wineserver` Pool (`WineserverPool`, `--warm-server`):** Reduces repeat game/conformance launch overhead from `0.85 s` to `0.07–0.22 s` (`3.8x–10x` faster).
  - **Native ARM64 Host Sync, Prefix & I/O (`runtime/`):** `dm_sync` (`os_sync_wait_on_address`), `dm_prefix` (`~0.41 ms` APFS CoW cloning), and `dm_host_io` (`CoreAudio` + `GameController.framework` controller telemetry).
- **Pre-Compiled `MTLBinaryArchive` & Cloud Shader Cache CDN (`shaders/`):**
  - Local `MTLBinaryArchive` pipeline cache (`66.7x` unit PSO load, `17.07x` warm Mullion D3D12 startup) and double SHA-256 verified Cloud Shader Cache indexing, export, import, and sync (`scripts/publish_shader_cache.sh`, `DirectMetal cache export|import|sync`).
- **Seatbelt Isolation Sandbox & Secure Enclave Attestation v2 (`sandbox/`):**
  - Per-game `sandbox-exec` confinement (`5/5` kernel `EPERM` assertions in `dm_sandbox_test`) with optional `--sandbox-offline` network isolation.
  - Persistent Apple Silicon Secure Enclave P-256 `directmetal.attestation.v2` challenge-response (`DirectMetal attest [--pid <pid>]` / `verify-attest` + `libdm_attestation.a`) with dynamic code-signing, `kern.bootsessionuuid`, and loaded dylib digest verification.
- **CI/CD Pipeline & Contributor Experience:**
  - GitHub Actions Apple Silicon CI (`.github/workflows/ci.yml`) and tag/dispatch Release pipeline (`.github/workflows/release.yml`), self-documenting `Makefile`, local CI gate (`scripts/run_ci_local.sh`), MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `.editorconfig`, and issue/PR templates.
