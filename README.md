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

Initial repository bootstrap — setting up the cross-machine build, D3D conformance harness, and Phase 1 vertical slice. See [ARCHITECTURE.md](ARCHITECTURE.md) and [ROADMAP.md](ROADMAP.md) for the engineering plan.
