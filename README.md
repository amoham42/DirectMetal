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
- **Apple Silicon Optimizations:** UMA `MTLStorageModeShared` (`1.51x`, `-66.2%` mem), TBDR `MTLStorageModeMemoryless` (`2.71x`, `-64.75 MiB` DRAM), local + cloud SHA-256 verified `MTLBinaryArchive` (`66.7x` unit PSO / `17.07x` end-to-end warm cache / `DirectMetal cache export|import`), live sub-native **Metal 4 MetalFX Temporal** (`1248×812 → 1512×984` on UE5 `REANIMAL` via `METALSHARP_DLSS_SCALE` + `nvngx.dll`) & D3D11/D3D12 MetalFX Spatial (`1.72x`–`2.55x`), and APFS CoW per-game prefixes (`0.41 ms`).
- **Post-Rosetta Execution & Real Retail Games:** Native ARM64 host I/O + Wine ARM64EC + FEX-Emu (`ProfileStats=0`: **`3176.9 FPS`** D3D11 / `1265.9` 1%-low, **`2860.7 FPS`** D3D12 / `1796.6` 1%-low = **49.3% of native RTX 3070 1%-low**, **`1595.4 FPS`** / `1149.3` 1%-low sandboxed `1024×1024` Deferred PBR = **`4.31x` Rosetta 2 1%-low**!) + native **ARM64X `DXVK 3.1.1 (MetalVulkan)` + Mesa KosmicKrisp**. Verified live on **Hades** (`120.00 FPS` locked, `--sandbox`), **REANIMAL** (UE5 DX12 `74.52 FPS` full Retina w/ sub-native Metal 4 MetalFX Temporal & DX11 `99.79 FPS`), **Team Fortress 2** (native ARM64X DXVK 3.1.1 + KosmicKrisp at **`14%` GPU / `225 MiB` VRAM**), and **Need for Speed: Hot Pursuit** (WineD3D GL default + DXVK→MoltenVK→Metal via `DM_VK_COMPAT_HOST_IMPORT=1`).
- **Per-Game Isolation & Hardware-Backed Attestation v2:** Stripped `5.8 GB` Hardened Runtime (`--options runtime`, `hardened_runtime: true`) `.app` bundle, macOS Seatbelt sandbox (`DirectMetal run --sandbox`, `5/5` kernel `EPERM` tests), and **Attestation v2** (`DirectMetal attest` / `verify-attest`) backed by a persistent non-exportable **Apple Silicon Secure Enclave** P-256 hardware key, `DCDevice.isSupported`, `kern.bootsessionuuid`, dynamic `SecCodeCopySelf` status, and `_dyld_image_count` image verification.

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
