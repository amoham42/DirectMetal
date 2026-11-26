# DirectMetal Architecture

## Design Principles

1. **Apple Silicon Only (M1+ / ARM64):** No Intel Mac, no OpenGL, no X11, no multi-backend user toggles.
2. **Direct-to-Metal:** Translate DXBC/DXIL and D3D10/11/12 state objects directly to Metal 3/4 concepts (`MTLArgumentEncoder` / bindless argument buffers, `MTLBinaryArchive`, mesh shaders, MetalFX).
3. **Zero-Copy UMA & TBDR First:** Treat unified memory and on-chip tile SRAM as first-class invariants in the resource allocator and command-list translator.
4. **Native ARM64 Host Stack:** Minimize translated x86-64 surface area; execute Win32/NT sync, I/O, audio, input, and Metal command encoding natively on ARM64.
5. **Reference-Verified Compatibility:** Every graphics feature, shader instruction, and sync primitive is verified against native Windows x64 + RTX 3070 ground-truth captures.

## Subsystem Map

| Layer | Responsibility | Key Technologies |
| :--- | :--- | :--- |
| `app/` | Single signed `.app` bundle, zero-config launcher, game auto-detection, Metal HUD overlay | Swift / SwiftUI, Metal HUD, APFS CoW prefixes |
| `runtime/` | Stripped macOS Wine/Win32 core, fast NT sync, thunking boundary | Wine ARM64EC/WoW64, `os_sync_wait_on_address`, `msync`, Rosetta 2 / FEX-Emu |
| `graphics/` | Direct D3D10/11/12 → Metal translation, UMA allocator, TBDR pass merger, D3D12 placed-resource alignment guard (`dm_d3d12_placed_guard`), universal Vulkan compat layer (`dm_vk_compat`) | DXMT (D3D10/11), Mullion (D3D12), DXVK 3.1.1 ARM64X + KosmicKrisp (D3D9 x64), `d3d12_guard.dll` |
| `shaders/` | Pipeline compilation, offline & runtime `MTLBinaryArchive` cache management | Metal Shader Converter / LLVM DXIL→AIR, GPU-family cache keys |
| `upscaling/` | Transparent DLSS / FSR / XeSS → MetalFX interceptor DLLs | `nvngx_dlss` / `ffx_fsr` shims → `MetalFX` |
| `sandbox/` | Hardened per-game isolation container + attestation protocol for anti-cheat opt-in | Hardened Runtime, SIP/App Attest verification |
| `tests/` | Cross-platform D3D11/D3D12 visual, shader, and sync conformance suite | MSVC/DXC test binaries, SSIM/PSNR frame diffing (RTX 3070 vs M1 Pro) |
