# Changelog

All notable changes to **DirectMetal** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-11-28

### Added

- **Interactive Launch Log Crash Triage (`⇧⌘L`, `LaunchLogAnalyzer.swift`, `LaunchLogTriageSheet.swift`, `LaunchLogTriageComponents.swift`, `DirectMetal diagnose-log`):** Single-pass Wine/DirectX/Metal log scanner and native macOS 15 SwiftUI triage viewer (drag-and-drop, file picker, clipboard paste, severity/category filters, redacted excerpts, DirectMetal-specific remediations, Markdown/text report export).
- **Live Metal Performance HUD Customizer (`⇧⌘M`, `MetalHUDConfig.swift`, `MetalHUDCustomizerSheet.swift`, `DirectMetal hud`):** Interactive overlay preset, corner alignment, scale, opacity, and DXVK HUD customizer with live 16:9 canvas preview wired directly into `MTL_HUD_*` launch environments.
- **Privacy-Redacted Diagnostics Support Bundle Exporter (`SupportBundleExporter.swift`, `DirectMetal support-bundle`):** One-click `.tar.gz` diagnostics bundle omitting secrets and raw home paths for GitHub bug reports.
- **Per-Game Configuration Diff, Baseline Reset & Launch Env/Args Linter (`ConfigDiffEngine.swift`, `LaunchEnvValidator.swift`, `DirectMetal library diff|reset-settings|lint`):** Shows `"N customized"` pills and real-time inline launch env/args advisories (catching blocked security keys, Linux/Proton no-ops like `MANGOHUD`/`PROTON_*`/`%command%`, HUD/FPS conflicts, and malformed quotes without ever echoing secrets).
- **7-Point Per-Game Pre-Flight Readiness Checker (`PreflightChecker.swift`, `LaunchPlanSheet.swift`, `DirectMetal library preflight`):** Fast, read-only launch readiness audit verifying executable presence, runtime resolution, kernel anti-cheat signatures (EAC/BattlEye/Vanguard), free disk headroom, APFS prefix state, graphics pipeline, and custom env.
- **Shader Cache Integrity Verifier & Safe Quarantine (`ShaderCacheVerifier.swift`, `DirectMetal cache verify [--quarantine]`):** Symlink-safe verifier recognizing real macOS `MTLBinaryArchive` (`0xCBFEBABE`), `MTLB`, SQLite `.db`/WAL/lock sidecars, DXVK caches, and JSON manifests; safely quarantines corrupt artifacts without wiping healthy caches.
- **Unified Storage Footprint & Reclamation Tab (`⌘D`, `StorageFootprintAnalyzer.swift`, `StorageFootprintTab.swift`, `DirectMetal storage`):** Symlink-safe 6-category disk footprint audit (prefixes, shader caches, `_quarantine`, save backups, user runtimes, metadata) with proportional stacked chart, prioritized reclamation tips, and 1-click cleanup actions.
- **200 Validated Community Game Profiles & Batch Library Sync (`ProfileBatchSync.swift`, `DirectMetal library sync-profiles`, `runtime/profiles/game_profiles.json`):** Doubled bundled community game profiles from `100` to **200** (`5` hardware-verified + `195` community presets across `216` unique executables) with safe library-wide batch sync preserving user customizations.
- **Per-Game Launch Stability Analytics & Pre-Reset Save Backup (`GameSessionAnalytics.swift`, `DirectMetal history stats`, `PrefixManagerSheet.swift`):** Stability tier classification, ARM64EC/Rosetta ratio, median APFS CoW latency, and one-click **"Backup Saves & Reset"** protection in the APFS Prefix Manager.
- **`dm_vk_compat` C11 Runtime Unit Test & 94-Test Verification Suite:** Added `graphics/dm_vk_compat/tests/dm_vk_compat_test.c` (testing the universal `arm64+x86_64` Vulkan layer via `dlopen` + loader chains + subprocess env toggles), shell/Homebrew Cask/`Info.plist` contract tests, and expanded automated coverage to **94 tests** (**50** Swift `-warnings-as-errors` + **26** Python + **7** PSNR/SSIM + **11** C/Obj-C++ CTest via `make ctest`).

### Changed

- **Complete Swift Modularization:** Split `MetalHUDConfig`, `LaunchPlanInspector`, `LaunchLogAnalyzer`, `LaunchLogTriageSheet`, and `main.swift` (`MaintenanceAndDiagnosticsCLI.swift`) so every Swift source file in `app/DirectMetalApp/` stays cleanly under 1,000 lines.

## [1.1.0] - 2026-11-28

### Added

- **Native macOS 15 Launcher Power-User Suite (`app/DirectMetalApp/`):**
  - **Game Poster Gallery (`⌘2`, `GameGridView.swift`):** Adaptive cover-art grid toggleable with Detail Inspector (`⌘1`), hover Play overlay, scrollable API badge pills, and context menus.
  - **Quick-Launch Command Palette (`⌘K`, `CommandPaletteSheet.swift`):** Fuzzy/word-boundary/CamelCase/diacritic-ranked launcher jumping straight to games (`↩` inspect, `⌘↩` play) and all launcher sheets/actions.
  - **Per-Game Favorites / Pinning (`isFavorite`):** Star pinning across sidebar rows, detail header, poster gallery cards, `★` filter chip, and CLI (`DirectMetal library set <game> favorite=true|false`).
  - **System Health, Shader Cache & Built-in Apple Silicon Benchmark Sheet (`⌘D`, `SystemHealthSheet.swift`, `ShaderCacheAndBenchTabs.swift`, `BenchmarkCLI.swift`):** 9-point health doctor (`DirectMetal doctor [--json]`), stale shader cache inspection & pruning (`DirectMetal cache list|prune`), and live Apple Silicon microbenchmarks (`DirectMetal bench [--json|--markdown]`: Metal UMA compute bandwidth, APFS CoW `clonefile`, ARMv8 hardware SHA-256, cached PE32+ inspection).
  - **APFS Prefix Manager, Orphaned Prefix Pruning & SHA-256 Save Backup/Restore (`⇧⌘P`, `PrefixManagerSheet.swift`, `SaveBackupManager.swift`):** Logical size & CoW telemetry (`DirectMetal prefix stats`), safe orphaned prefix pruning (`DirectMetal prefix prune [--dry-run]`), and SHA-256 verified Windows save-data export/restore (`DirectMetal prefix export-saves|import-saves`, with `O_NOFOLLOW` & path-traversal rejection).
  - **Structured Launch History (`⇧⌘H`, `LaunchHistoryStore.swift`, `DirectMetal history`):** Rolling 200-entry JSONL session log capturing exit codes, durations, engines, CoW clone latency, and sandbox state with Markdown export.
  - **Dry-Run Launch Plan Inspector (`⇧⌘I`, `LaunchPlanInspector.swift`, `DirectMetal library explain`):** Side-effect-free preview of resolved execution engine, graphics translator, MetalFX upscaling, FPS cap env, prefix, shader cache, controller profile, and blocked custom env keys.
  - **Community Game Profiles Browser (`⇧⌘B`, `ProfileBrowserSheet.swift`, `DirectMetal profiles match`):** Searchable in-app browser over **100 validated community game profiles** (`5` hardware-verified, `95` community presets) with one-click preset application.
  - **Spotlight & Dock `.app` / `.command` Shortcut Exporter (`ShortcutExporter.swift`, `DirectMetal library shortcut`):** Generates standalone `.app` launcher bundles (with game `.icns` artwork) or `.command` scripts with POSIX-safe escaping.
  - **Per-Game FPS Cap & ProMotion Frame-Pacing + Sanitized Custom Env Vars:** Per-game `0/30/40/60/90/120/144` FPS pacing (`dxgi.maxFrameRate`, `DXMT_FRAME_RATE_CAP`, `DXVK_FRAME_RATE`), sanitized custom env editor (blocking `WINEPREFIX`/`DYLD_*`/`LD_PRELOAD` and merging `WINEDLLOVERRIDES`/`MULLION_CONFIG`), playtime duration tracking, portable library + controller backup/restore (`DirectMetal library export|import`), `bumperTriggerSwap` controller preset, and native `zsh`/`bash` completions (`DirectMetal completions`).
- **Root CMake Superbuild & Comprehensive Test Coverage (`78` Automated Tests):**
  - Top-level `CMakeLists.txt` with `10/10` CTest native C/Obj-C++ subsystem tests (`-Wall -Wextra -Werror -Wformat=2`, Release `-DNDEBUG` safe), **39** Swift unit tests (`-warnings-as-errors`), **22** Python packaging/profile tests, and **7** PSNR/SSIM visual-diff tests.
  - Homebrew Cask (`Casks/directmetal.rb`) and reference docs (`docs/BENCHMARKS.md`, `docs/CLI_REFERENCE.md`, `docs/GAME_PROFILES_GUIDE.md`, `docs/SHADER_CACHE_CDN.md`).

### Changed & Optimized

- **Hot-Path Performance:** Parallel SHA-256 hashing (`DispatchQueue.concurrentPerform`) in `ShaderCacheManager` & `SaveBackupManager`; parallel multi-game folder scanning in `GameLibraryManager`; `O(1)` stat-cached `SteamLibraryLocator.manifestIndex`; `pthread_once` env caching & atomic dispatch in `dm_vk_compat_layer.c`; single-init cached forwarding in `d3d12_guard.c`; bounded exponential-backoff retry for transient runtime downloads in `RuntimeManager.swift`.
- **Full Swift Modularization:** Refactored monolithic Swift files (`main.swift`, `DirectMetalGUI.swift`, `GameLibraryManager.swift`, `RuntimeLauncher.swift`, `SystemHealthSheet.swift`, `ShaderCacheManager.swift`, `GameArtworkManager.swift`, `AppUpdater.swift`) into focused, maintainable modules.

### Fixed

- **Graphics & Inspection:** Fixed `UInt32` RVA overflow in `PEInspector.swift` (using `UInt64` arithmetic) and added `Vulkan`/`OpenGL` API detection; fixed `uint8` overflow wraparound in `tools/diff_harness.py` error heatmaps and vectorized 3-channel SSIM convolution.
- **Native Systems & Security:** Fixed 3 `CFErrorRef` leaks and `NSTask`/`NSPipe` deadlock in `dm_attestation.mm`; added `EINTR` timeout recomputation in `dm_sync.c` and `waitpid` retry in `dm_sandbox.c`; hardened Seatbelt SBPL escaping (newline stripping) and expanded deny list (`.netrc`, `.npmrc`, `.pypirc`, Brave/Edge/Arc); added RFC 8259 JSON escaping and `"/"`/`/.` delete guards in `dm_prefix.c`; fixed Release `-DNDEBUG` assertion elision across native C tests.

## [1.0.1] - 2026-11-27

### Added

- **Verified In-App & CLI Self-Updater (`AppUpdater.swift`, `DirectMetal update apply`, `DirectMetal runtime update`):**
  - Dual update checker monitoring both `amoham42/DirectMetal` and upstream `metalsharp/MetalSharp-Wine` releases in the GUI Updates sheet and `DirectMetal update check --json`.
  - Streams release `.dmg` downloads, enforces strict SHA-256 verification against `.sha256` sidecars, mounts read-only via `hdiutil`, verifies `codesign --verify --deep --strict`, checks Bundle ID and Signing Team ID identity match, atomically replaces the installed `.app` with automatic rollback on failure, and offers one-click relaunch.
- **GOG Galaxy & Epic Games Store Discovery + Artwork (`GameLibraryManager.swift`, `GameArtworkManager.swift`):**
  - Automatic scanning of GOG Galaxy (`goggame-*.info`, `webcache` cover art, `.ico` icons) and Epic Games Store (`Manifests/*.item`, Heroic `installed.json` + `images-cache/`, `.egstore/` markers) alongside Steam and Windows PE `.exe` icon extraction, with storefront badges in the GUI and `DirectMetal library artwork <game>`.
- **Interactive Controller Remapping, Deadzones & Live Input Tester (`ControllerMappingManager.swift`, `DirectMetal controller`):**
  - Global and per-game controller profiles (`xboxStandard`, `nintendoSwap`, `playstationDualSense`, `invertedLookY`, `custom`), per-button remapping, Left/Right stick deadzones (`0%–35%`), haptics toggle, live `GCController` input tester sheet in the GUI, and automatic `SDL_GAMECONTROLLERCONFIG` generation on launch.
- **Expanded Community Game Profiles & Multi-Chip Cloud Shader Cache (`runtime/profiles/game_profiles.json`):**
  - Expanded to 36 profiles across UE5, Unity, RE Engine, Frostbite, REDengine, and Source 2 (with honest `playable` vs `preset` status tags), plus combined `Apple7` (M1 Pro) + `Apple9` (M4) starter Cloud Shader Cache index.

### Fixed

- **macOS 15 SDK (Xcode 16) Compilation:** Replaced macOS 26-only `MTLGPUFamily.apple10` / `.metal4` / `supportsMetal4FX` compile-time symbols with runtime-safe raw enum values and dynamic Obj-C selector probes (`RuntimeLauncher.swift`, `dm_metal_device.mm`, `dm_metalfx_bridge.mm`), making GitHub Actions `macos-15` CI pass cleanly while retaining full Metal 4 runtime detection on macOS 26/27.
- **Strict Code Signing on `--include-rosetta` Bundles:** Stripped external symlinks (`dosdevices/z: -> /` and host home-directory links) from bundled Rosetta base prefixes in `scripts/package_app.sh` and restored `dosdevices/z: -> /` automatically on clone in `PrefixManager.swift`.

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
