# DirectMetal Engine & Feature Compatibility Matrix

This matrix maps DirectMetal's verified Phase 0–4 test coverage (**25 / 25 conformance tests passing**, Mean SSIM **`0.999844`**, Min PSNR **`54.32 dB`** vs. Windows 11 + NVIDIA RTX 3070 Laptop GPU ground truth) to the rendering, compute, shader, host I/O, and isolation primitives required by major PC game engines.

> **Methodology & Honesty Note:** Status ratings below reflect verification of synthetic **API + SM 6.0 DXIL engine-pattern workloads** (`tests/conformance/d3d11/`, `d3d12/`, `engine_patterns/`) executed on Apple M1 Pro (`macOS 26.1`, `Metal 4 / Metal 3`, Feature Level `11_1`) under DirectMetal (`ARM64EC+FEX` and `Rosetta 2`), **not** proprietary commercial game binaries. Kernel-mode Windows anti-cheat drivers (`.sys`) are outside macOS execution scope; DirectMetal provides a strictly opt-in user/platform attestation SDK (`directmetal.attestation.v1`) without spoofing OS checks.

---

## 1. Verified Engine-Class SM 6.0 DXIL Pattern Coverage

All 6 engine-class tests in [tests/conformance/engine_patterns/](../tests/conformance/engine_patterns/) compile strictly to SM 6.0 (`vs_6_0`, `ps_6_0`, `cs_6_0`) signed DXIL via WinSDK `10.0.26100.0` `dxc.exe` and execute on Apple M1 Pro under **ARM64EC+FEX with Seatbelt `--sandbox` confinement**:

| Test ID | Engine Workload Pattern | Shader Model | PSNR (dB) | SSIM | Checksum / Accuracy |
| :--- | :--- | :--- | ---: | ---: | :--- |
| `eng_01_deferred_gbuffer` | 3-MRT G-Buffer (`RGBA8` + 2x `RGBA16F`) + `D32_FLOAT` + Cook-Torrance GGX PBR + ACES | `vs_6_0 / ps_6_0` | `60.95` | `0.999419` | Max diff `1 LSB` |
| `eng_02_shadow_pcf` | Depth-only `D32_FLOAT` shadow pass (`R32_TYPELESS`) + `SamplerComparisonState` 3x3 PCF | `vs_6_0 / ps_6_0` | `66.77` | `0.999979` | Max diff `1 LSB` |
| `eng_03_gpu_cull_indirect` | Compute frustum/diamond culling + `InterlockedAdd` + `ExecuteIndirect` `pCountBuffer` | `cs_6_0 + vs_6_0 / ps_6_0` | `Exact (inf)` | `1.000000` | GPU & pixel checksum `EXACT` (`0x000000181106c74c`) |
| `eng_04_hdr_bloom_tonemap` | `R16G16B16A16_FLOAT` HDR RT -> separable compute bloom -> ACES composite | `vs_6_0 / cs_6_0 / ps_6_0` | `71.60` | `0.999974` | Max diff `1 LSB` |
| `eng_05_wave_ops` | `WaveActiveSum` / `WavePrefixSum` / `WaveActiveBitXor` / `WaveIsFirstLane` + Root Constants | `cs_6_0` | `67.95` | `0.999994` | GPU reduction checksum `EXACT` (`0x00000000015f0000`) |
| `eng_06_bindless` | SM 6.0 `Texture2D<float4>[16]` SRV table (`space0`) + `NonUniformResourceIndex` + `space1` root SRV | `vs_6_0 / ps_6_0` | `64.17` | `0.999977` | Max diff `1 LSB` |

### 1024x1024 Multi-Pass Deferred PBR Benchmark (`eng_bench_deferred_pbr`)

| Platform / Execution Mode | Mean Frame Time | Avg FPS | 1%-Low FPS | GPU Mean (ms) | Throughput (MP/s) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Windows RTX 3070** (Native SM 6.0 DXIL) | `0.248 ms` | `4030.9` | `2153.8` | `0.114 ms` | `4226.7` |
| **Apple M1 Pro Rosetta 2** (Mullion DXIL -> Metal) | `0.814 ms` | `1227.9` | `283.0` | `0.378 ms` | `1287.6` |
| **Apple M1 Pro ARM64EC+FEX (Seatbelt Sandboxed)** (`run_phase4_verify.sh`) | `0.715 ms` | `1398.1` | `624.0` | `0.421 ms` | `1466.0` |

*Confinement check:* ARM64EC+FEX under `sandbox-exec` delivers **`1.14x` higher avg FPS** and **`2.20x` higher 1%-low FPS** than Rosetta 2 on `eng_bench_deferred_pbr` while keeping Seatbelt kernel confinement active.

---

## 2. Architecture Mapping to Major Game Engines

| Engine | Core D3D11/D3D12 Pipeline Requirements | Covered Verified Tests | Host / Apple Silicon Optimizations | Known Gaps / Unverified Features |
| :--- | :--- | :--- | :--- | :--- |
| **Unreal Engine 4 / 5** | Deferred G-Buffer MRTs, CSM/PCF shadows, compute culling + `ExecuteIndirect`, HDR bloom + ACES, SM 6.0 wave intrinsics, MetalFX upscaling | `eng_01`, `eng_02`, `eng_03`, `eng_04`, `eng_05`, `d3d12_06`–`09`, `dm_metalfx_bench` | `MTLBinaryArchive` (`17.07x` warm Mullion load), UMA zero-copy (`1.51x`), `os_sync_wait_on_address` sync | UE5 Nanite `SM 6.6` `ResourceDescriptorHeap`, Lumen hardware raytracing (DXR 1.1), FL `12_0+` virtual shadow sparse heaps (`Mullion` reports FL `11_1` on macOS 26.1) |
| **Unity (Built-in / URP / HDRP)** | D3D11/D3D12 forward+ & deferred passes, MSAA resolve, instanced draws, GPU culling + `ExecuteIndirect`, compute post-processing | `d3d11_01`–`10`, `d3d12_01`–`09`, `eng_01`–`04` | APFS CoW per-title prefix cloning (`0.41 ms`), CoreAudio (`12.21 ms`), `GameController.framework` | Mono/.NET JIT RWX paths with Hardened Runtime + FEX-Emu; DXR tier 1.1 |
| **RE Engine** | High-frequency SM 6.0 DXIL compute + deferred lighting, wave intrinsics, `NonUniformResourceIndex` texture arrays, FSR/MetalFX | `eng_01`, `eng_04`, `eng_05`, `eng_06`, `dm_upscale_shims` | Seatbelt per-game confinement + opt-in attestation SDK; TBDR `MTLStorageModeMemoryless` (`2.71x`) | Vendor anti-tamper / kernel DRM checks on desktop Windows titles |
| **REDengine 4** | Multi-RT PBR G-Buffer, HDR `RGBA16F` lighting + ACES filmic tonemap, compute bloom/post-FX, upscaler shims (DLSS/FSR/XeSS -> MetalFX) | `eng_01`, `eng_04`, `d3d12_05`–`09`, `dm_metalfx_bench` | MetalFX Spatial (`1.72x`–`2.55x`) & Temporal FP16 (`1.10x`, `55.95 dB` PSNR), shader archive caching | Path-tracing overdrive (DXR + Shader Execution Reordering) |
| **Frostbite** | D3D12 multi-pass fence synchronization, depth shadow maps + PCF comparison samplers, indirect draw arguments | `d3d12_08`, `d3d12_09`, `eng_02`, `eng_03`, `eng_05` | ARM64EC+FEX host thunking (`1.39x` D3D12 avg / `1.69x` 1%-low vs Rosetta 2) | Kernel anti-cheat (`.sys`) used in multiplayer modes |
| **Source 2** | Clustered lighting, SM 6.0 wave intrinsics, compute post-FX, low-latency frame pacing + host audio/input | `d3d11_06`–`10`, `eng_01`, `eng_04`, `eng_05` | `os_sync_wait_on_address` (`235 ms` vs `288 ms` pthread / `328 ms` pipe), CoreAudio `48 kHz` | VAC/multiplayer attestation integration requires explicit Valve/server opt-in (`DirectMetal attest`) |
| **id Tech** | Bindless texture tables (`NonUniformResourceIndex`), GPU-driven `ExecuteIndirect` visibility culling, high-FPS deferred + post-FX | `eng_01`, `eng_03`, `eng_04`, `eng_06`, `d3d12_07`–`09` | Zero `MULLION_D3D12_FLEXIBLE` blend hazard (fixed in `mullion.conf`), Metal 4/3 pipeline archives | Native Vulkan/idTech 7–8 titles should use native Vulkan/MoltenVK outside DirectMetal D3D10/11/12 scope |

---

## 3. Hardened Sandbox & Opt-In Attestation Summary

- **Kernel Isolation ([sandbox/profiles/directmetal_game.sb.tmpl](../sandbox/profiles/directmetal_game.sb.tmpl)):**
  - Enforced via macOS `/usr/bin/sandbox-exec`.
  - Blocks sibling Wine prefixes (`EPERM` on read/write), `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, keychains, and browser credential stores, plus arbitrary writes under `$HOME` (`5/5` assertions verified in [dm_sandbox_test.c](../sandbox/dm_sandbox/tests/dm_sandbox_test.c)).
  - Permits `file-read-metadata` on the parent `Prefixes` directory (`realpath` traversal required by `wineserver`), full RW inside the cloned target prefix and per-title shader cache, and optional IP network restriction (`--sandbox-offline`) while preserving `AF_UNIX`/Mach IPC.
- **Platform Attestation SDK ([sandbox/dm_attestation/](../sandbox/dm_attestation/) & `DirectMetal attest`):**
  - Measures authentic macOS security signals without spoofing: **SIP** (`csrutil status` -> `enabled`), **Signed System Volume** (`csrutil authenticated-root status` -> `enabled`), **`SecStaticCode` CDHash & binary SHA-256**, **sandbox flag**, and **`DCAppAttestService.shared.isSupported`** (honestly reports `false` on macOS desktop targets).
  - Signs canonical JSON claims with an ephemeral `ECDSA P-256 SHA-256 X9.62` keypair (`Security.framework` / `CryptoKit`) bound to server nonces; rejects mismatched nonces and tampered claims.

---

## 4. Real-World Retail Game Verification (M1 Pro)

Real Windows retail games transferred from `LAPTOP-FRD51BOR` (`D:\`) and tested live on Apple M1 Pro (`macOS 26.1` `25B78`):

| Game (Executable) | Size / Arch / API | DirectMetal Path | Live Verified Result on M1 Pro |
| :--- | :--- | :--- | :--- |
| **Need for Speed: Hot Pursuit** (`NFS11.exe`) | `7.84 GB` / x86 / **D3D9** | Rosetta 2 + WineD3D GL + Auto Virtual Desktop (`1280×720`) | **PASS** — Booted cleanly, wrote `config.NFS11Save`, active `800×600` window (`782 MB` RSS), **66% GPU** (`729 MiB` active GPU mem), ran `2h+` continuously |
| **Hades** (`x64\Hades.exe`) | `11.08 GB` / x64 / **D3D11** | **ARM64EC + FEX-Emu + Mullion Direct-to-Metal D3D11** | **PASS (First Try)** — Booted to main menu & wrote `Profile1.sjson` in **`4.04 s`**, full Retina **`1512×982`** (`libMTLHud` active), `1.28 GB` RSS, **56% GPU** (`512 MiB` GPU mem) |
| **REANIMAL** (`REANIMAL.exe`, Unreal Engine 5) | `15.94 GB` / x64 / **D3D12** | **ARM64EC + FEX-Emu + Mullion Direct-to-Metal D3D12** | **PASS (First Try)** — Initialized `D3D12Device` + Mullion compute pipelines + `libMTLHud`, `1280×720` window, `2.20 GB` RSS, **82% Device / 81% Renderer GPU** (`2.58 GiB` active GPU mem, `recoveryCount=0`) |
| **Team Fortress 2** (`tf_win64.exe`, Source) | `31.01 GB` / x64 / **D3D9** | Rosetta 2 + WineD3D GL (`AppleMetalOpenGLRenderer`) | **PASS** — Created `"Team Fortress 2 - Direct3D 9 - 64 Bit"` (`1280×720`), loaded `stdshader_dx9.dll` + `CoreAudio`, **59–60% GPU** (`731–803 MB` GPU mem) |
| **Prince of Persia: Forgotten Sands** (`Prince of Persia.exe`) | `1.60 GB` / x86 / **D3D9** | Rosetta 2 + WineD3D GL (`.bind` SteamStub + UPlay) | **Needs Steam Login** — Empirically popped `"Steam Error"` dialog without an active Steam session (no DRM bypass) |
| **Official Windows Steam** (`steam.exe`) | Installed via `scripts/setup_steam.sh` | Rosetta 2 prefix (`steam`) | **PASS** — Silent installer succeeded in `4.3 s`; `steam.exe` boots cleanly for SteamStub titles (`Hades II`, `Assetto Corsa`, `Prince of Persia`) |

### Key Real-Game Fixes Landed During Verification
1. **Retina Fullscreen Mode Rejection (`DISP_CHANGE_BADMODE`, `hr 0x8876086a`):** Pure-D3D9 games (`isD3D9 && !isD3D11 && !isD3D12`) auto-enable a `1280×720` Wine Virtual Desktop (`--desktop <WxH>|off`), while DX11/DX12 titles that merely delay-load `d3d9.dll` (like UE5 `REANIMAL.exe`) launch natively without a virtual desktop.
2. **MoltenVK `1.1.323` D3D9 Compatibility:** Because DXVK (`v1.10.3`/`v2.4.1`) requests unsupported `geometryShader`/`shaderCullDistance` and WineD3D Vulkan requests unsupported `VK_EXT_external_memory_host` on MoltenVK, `--dx9-backend auto` routes pure-D3D9 titles to `WINE_D3D_CONFIG="renderer=gl"` (`d3d9=b`).
3. **Remaining `D:\` Library Status (Not Yet Transferred / Blocked):**
   - **Counter-Strike 2** (`70.09 GB`, x64 DX11, no `.bind`): Feasible, requires freeing ~35 GB of local cache space before transfer.
   - **Hades II** (`10.97 GB`, x64) & **Assetto Corsa** (`25.63 GB`, x64 DX11): Both carry `.bind` SteamStub DRM — ready to run once the user signs into the installed DirectMetal `steam` prefix.
   - **Apex Legends** (`67.78 GB`): Blocked by `EAAntiCheat` kernel anti-cheat.
   - **Halo Infinite** (`67.76 GB`): Requires D3D12 FL `12_0+` + anti-cheat.
   - **Red Dead Redemption 2** (`119.51 GB`): Exceeds available free disk space + Rockstar Launcher DRM.


