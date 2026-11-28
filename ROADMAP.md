# DirectMetal Roadmap

## Phase 0 — Environment & Conformance Harness
- [x] Verify M1 Pro macOS toolchain (Xcode, Metal CLI `gpucapture`/`gpudebug`, CMake, Meson, LLVM, Rust/C++).
- [x] Establish automated Windows RTX 3070 reference test runner (compile D3D11/D3D12 micro-tests, capture reference PNGs + GPU timings).
- [x] Stand up automated visual diff pipeline (`PSNR`/`SSIM`) comparing Windows RTX 3070 ground truth vs. M1 Pro Metal output.

## Phase 1 — Vertical Slice (Unified Direct-to-Metal Runtime)
- [x] Build reproducible macOS Wine core with `msync` + `os_sync_wait_on_address` fast-path experiments.
- [x] Integrate open-source direct-to-Metal D3D10/11 (**DXMT**) and D3D12 (**Mullion**) pipelines into a single unified build.
- [x] Package a self-contained `.app` runner with APFS copy-on-write per-game prefixes and zero manual backend selection.
- [x] Boot external retail DX9/DX11/DX12 commercial games *(verified live on M1 Pro: Need for Speed: Hot Pursuit DX9, Hades DX11 ARM64EC+Mullion, REANIMAL UE5 DX12 ARM64EC+Mullion, Team Fortress 2 Source DX9 x64, plus official Windows Steam client)*.

## Phase 2 — Apple Silicon Deep Optimizations
- [x] Implement UMA zero-copy buffer allocator (`MTLStorageModeShared` fast paths for dynamic/upload/readback heaps).
- [x] Implement TBDR render-pass coalescing & `MTLStorageModeMemoryless` transient attachment detection.
- [x] Build `MTLBinaryArchive` local + cloud shader cache storage, SHA-256 verified export/import (`DirectMetal cache export|import`), and pre-warming pipeline keyed by Apple Silicon GPU family.
- [x] Add transparent DLSS/FSR/XeSS → **MetalFX** upscaling bridge (verified live Metal 4 MetalFX Temporal on UE5 `REANIMAL` via `nvngx.dll` + MetalFX Spatial on `Hades`).

## Phase 3 — Post-Rosetta Native ARM64 Host
- [x] Transition host runtime to native ARM64EC + FEX-Emu thunking so only game x86-64 code is translated.
- [x] Benchmark and close frame-time & 1%-low gaps against native Windows baselines. *(3-way RTX 3070 vs. Rosetta 2 vs. ARM64EC+FEX tracked in `COMPATIBILITY.md`)*

## Phase 4 — Compatibility Matrix & Attested Sandbox
- [x] Expand automated game/engine compatibility matrix (Unreal Engine 4/5, Unity, RE Engine, REDengine, Frostbite, Source 2, id Tech). *(SM 6.0 DXIL `eng_01`–`eng_06` + `eng_bench_deferred_pbr` and [docs/ENGINE_COMPATIBILITY_MATRIX.md](docs/ENGINE_COMPATIBILITY_MATRIX.md) verified **25/25**)*
- [x] Prototype hardened per-game isolation sandbox and platform-attested anti-cheat verification SDK. *(Stripped Hardened Runtime `--options runtime`, Seatbelt `dm_sandbox` `5/5` + live sandboxed `Hades`/`REANIMAL` + `dm_attestation` / `DirectMetal attest` & `verify-attest` ECDSA P-256 verified)*

## Phase 5 — Consumer Release, Cross-Chip Verification & Ecosystem (`v1.0` – `v1.1`)
- [x] Ship **`DirectMetal-Lite.app` (`2.9 MB` / `2.8 MiB` DMG)** with on-demand SHA-256 + `codesign`-verified ARM64EC runtime installer and dehydrated base-prefix hydration (`~150 ms`).
- [x] Ship verified **App & Runtime Self-Updater** (`update check|apply`, `runtime update`) with live `v1.0.0 → v1.0.1` GitHub Releases verification.
- [x] Cross-verify full stack on **Apple M1 Pro (`Apple7`)** and **Apple M4 (`Apple9`)**: `25/25` conformance (`SSIM 0.99984`), `4,490 FPS` D3D12, `2,092 FPS` Deferred PBR, and multi-chip **Cloud Shader Cache CDN** (`Apple7` + `Apple9`).
- [x] Expand storefront auto-discovery (**Steam, GOG Galaxy, Epic Games Store, Heroic**), **75 validated community game profiles**, pure-Swift PE icon extraction, playtime tracking, **Favorites pinning**, **Spotlight/Dock `.app` shortcuts**, portable library backup/restore, and interactive **`GCController` remapper**.
- [x] Ship native **Poster Gallery (`⌘2`)**, **`⌘K` Quick-Launch Command Palette**, **Per-Game FPS Cap / ProMotion VRR frame-pacing** & sanitized custom env vars, **System Health, Shader Cache & Built-in Apple Silicon Benchmark Sheet (`⌘D`, `DirectMetal doctor`, `DirectMetal bench`)**, **APFS Prefix Manager & Orphaned Prefix Pruning (`⇧⌘P`, `prefix stats|prune`)**, **Structured Launch History (`⇧⌘H`, `DirectMetal history`)**, Homebrew Cask (`Casks/directmetal.rb`), root CMake superbuild (`10/10` CTest), and **GitHub Actions `macos-15` CI** (`76+` automated tests across Swift, Python, and C/Obj-C++).

## Phase 6 — Next Horizons
- [x] Live Metal Performance HUD overlay layout customization inside the SwiftUI launcher (`⇧⌘M`, `DirectMetal hud`) + crash log triage (`diagnose-log`) & privacy-redacted diagnostics support bundle export (`support-bundle`).
- [ ] Apple Developer ID notarization in automated GitHub Releases CI (zero quarantine prompt out of the box).
- [ ] Expanded multi-chip community Cloud Shader Cache coverage (`Apple8` M2, `Apple9` M3/M4, `Apple10` M5) and automated game compatibility test reports.
