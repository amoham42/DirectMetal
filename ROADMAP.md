# DirectMetal Roadmap

## Phase 0 — Environment & Conformance Harness
- [x] Verify M1 Pro macOS toolchain (Xcode, Metal CLI `gpucapture`/`gpudebug`, CMake, Meson, LLVM, Rust/C++).
- [x] Establish automated Windows RTX 3070 reference test runner (compile D3D11/D3D12 micro-tests, capture reference PNGs + GPU timings).
- [x] Stand up automated visual diff pipeline (`PSNR`/`SSIM`) comparing Windows RTX 3070 ground truth vs. M1 Pro Metal output.

## Phase 1 — Vertical Slice (Unified Direct-to-Metal Runtime)
- [x] Build reproducible macOS Wine core with `msync` + `os_sync_wait_on_address` fast-path experiments.
- [x] Integrate open-source direct-to-Metal D3D10/11 (**DXMT**) and D3D12 (**Mullion**) pipelines into a single unified build.
- [x] Package a self-contained `.app` runner with APFS copy-on-write per-game prefixes and zero manual backend selection.
- [ ] Pass 100% of Phase 0 D3D11 + D3D12 core rendering conformance tests (19/19 passing) and boot initial real-world DX11/DX12 titles.

## Phase 2 — Apple Silicon Deep Optimizations
- [x] Implement UMA zero-copy buffer allocator (`MTLStorageModeShared` fast paths for dynamic/upload/readback heaps).
- [x] Implement TBDR render-pass coalescing & `MTLStorageModeMemoryless` transient attachment detection.
- [x] Build `MTLBinaryArchive` shader cache storage & pre-warming pipeline keyed by Apple Silicon GPU family.
- [x] Add transparent DLSS/FSR/XeSS → **MetalFX** upscaling bridge.

## Phase 3 — Post-Rosetta Native ARM64 Host
- [x] Transition host runtime to native ARM64EC + FEX-Emu thunking so only game x86-64 code is translated.
- [x] Benchmark and close frame-time & 1%-low gaps against native Windows baselines. *(3-way RTX 3070 vs. Rosetta 2 vs. ARM64EC+FEX tracked in `COMPATIBILITY.md`)*

## Phase 4 — Compatibility Matrix & Attested Sandbox
- [ ] Expand automated game/engine compatibility matrix (Unreal Engine 4/5, Unity, RE Engine, REDengine, Frostbite, Source 2, id Tech).
- [ ] Prototype hardened per-game isolation sandbox and platform-attested anti-cheat verification SDK.
