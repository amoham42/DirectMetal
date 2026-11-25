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

**Phases 0–4 verified on Apple Silicon (`M1 Pro`, macOS `26.1` `25B78`) against Windows 11 + NVIDIA RTX 3070 ground truth:**

- **Visual & Compute Conformance:** **25 / 25 (100.0%)** passing (`10/10` D3D11, `9/9` D3D12, `6/6` D3D12 SM 6.0 DXIL Engine Patterns) — Mean SSIM `0.999844`, Min PSNR `54.32 dB` (see [COMPATIBILITY.md](COMPATIBILITY.md) and [docs/ENGINE_COMPATIBILITY_MATRIX.md](docs/ENGINE_COMPATIBILITY_MATRIX.md)).
- **Apple Silicon Optimizations:** UMA `MTLStorageModeShared` (`1.51x`, `-66.2%` mem), TBDR `MTLStorageModeMemoryless` (`2.71x`, `-64.75 MiB` DRAM), local + cloud SHA-256 verified `MTLBinaryArchive` (`66.7x` unit PSO / `17.07x` end-to-end warm cache / `DirectMetal cache export|import`), live Metal 4 MetalFX Temporal (`REANIMAL` UE5 via `nvngx.dll`) & MetalFX Spatial (`1.72x`–`2.55x`), and APFS CoW per-game prefixes (`0.41 ms`).
- **Post-Rosetta Execution & Real Retail Games:** Native ARM64 host I/O + Wine ARM64EC + FEX-Emu (`2410.3 FPS` D3D11, `1391.3 FPS` / `729.5` 1%-low sandboxed `1024x1024` Deferred PBR = `2.44x` Rosetta 2 1%-low) + hardware-accelerated 64-bit DXVK D3D9 via Mesa KosmicKrisp + `VK_LAYER_DIRECTMETAL_mvk_compat`. Verified live on **Hades** (`120.00 FPS` locked, `--sandbox`), **REANIMAL** (UE5 DX12 `70.17 FPS` w/ Metal 4 MetalFX Temporal & DX11 `99.79 FPS`), **Team Fortress 2** (ARM64EC+FEX+DXVK+KosmicKrisp), and **Need for Speed: Hot Pursuit** (DX9).
- **Per-Game Isolation & Hardened Attestation:** Stripped `5.8 GB` Hardened Runtime (`--options runtime`, `hardened_runtime: true`) `.app` bundle, macOS Seatbelt sandbox (`DirectMetal run --sandbox`, `5/5` kernel `EPERM` tests), and opt-in ECDSA P-256 challenge-response attestation + verifier CLI (`DirectMetal attest` / `DirectMetal verify-attest`).

### Quickstart

```bash
# Build stripped Hardened Runtime .app, inspect GPU/games, manage cloud shader caches, attest & verify, or launch sandboxed
./scripts/package_app.sh
./dist/DirectMetal.app/Contents/MacOS/DirectMetal info
./dist/DirectMetal.app/Contents/MacOS/DirectMetal cache export /tmp/title.dmcache.tar.gz
./dist/DirectMetal.app/Contents/MacOS/DirectMetal cache import https://example.com/title.dmcache.tar.gz
./dist/DirectMetal.app/Contents/MacOS/DirectMetal attest --nonce aabbccdd00112233 --sandbox > /tmp/attest.json
./dist/DirectMetal.app/Contents/MacOS/DirectMetal verify-attest /tmp/attest.json --nonce aabbccdd00112233
./dist/DirectMetal.app/Contents/MacOS/DirectMetal run /path/to/game.exe --sandbox --upscale quality
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and [ROADMAP.md](ROADMAP.md) for the engineering plan.
