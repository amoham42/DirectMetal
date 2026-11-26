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
| **Apple M1 Pro Rosetta 2** (Mullion DXIL -> Metal) | `0.732 ms` | `1367.1` | `266.9` | `0.281 ms` | `1433.5` |
| **Apple M1 Pro ARM64EC+FEX (Seatbelt Sandboxed, `balanced`)** | `0.646 ms` | `1547.9` | `798.5` | `0.281 ms` | `1623.1` |
| **Apple M1 Pro ARM64EC+FEX (Seatbelt Sandboxed, `--perf-mode ultra`)** | `0.613 ms` | `1630.2` | `1110.9` | `0.281 ms` | `1709.4` |

*Confinement, FEX & Ultra perf tuning:* Disabling FEX `ProfileStats` (`"ProfileStats": "0"`) + `--perf-mode ultra` (`d3d11/d3d12.timestampQueries=False`, `MULLION_D3D12_PARALLEL_COMMANDS=1`, `MULLION_D3D12_ENCODE_THREADS=4`) under `sandbox-exec` delivers:
- **`d3d11_bench_frame`**: **`3434.4 FPS`** (`0.291 ms`, **`2667.4 FPS` 1%-low** — **`+25.9%` 1%-low over `balanced`**, **`78.5%` of native RTX 3070 1%-low**!)
- **`d3d12_bench_frame`**: **`2874.8 FPS`** (`0.348 ms`, **`2355.7 FPS` 1%-low** — **`+28.4%` 1%-low over `balanced`**, **`64.7%` of native RTX 3070 1%-low**!)
- **`eng_bench_deferred_pbr` (1024×1024 SM 6.0, `--sandbox`)**: **`1630.2 FPS`** (`0.613 ms`, **`1110.9 FPS` 1%-low** — **`+39.1%` 1%-low over `balanced`** and **`4.16×` Rosetta 2 1%-low** with **0.0% sandbox overhead**!)

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
- **Platform Attestation SDK v2 ([sandbox/dm_attestation/](../sandbox/dm_attestation/) & `DirectMetal attest [--pid <pid>]` / `verify-attest`):**
  - Both the Swift launcher and the standalone C/Obj-C++ SDK (`libdm_attestation.a`) use a **persistent, non-exportable Apple Silicon Secure Enclave P-256 hardware key** (`CryptoKit.SecureEnclave.P256.Signing.PrivateKey` / `kSecAttrTokenIDSecureEnclave`, `key_class: "secure-enclave-persistent"`, identical `key_id_sha256` across runs).
  - Measures authentic macOS hardware & live runtime signals without spoofing: **SIP** (`enabled`), **Signed System Volume** (`enabled`), **Hardened Runtime (`--options runtime`, `hardened_runtime: true`)**, **`DCDevice.current.isSupported` (`true`)**, **`kern.bootsessionuuid`**, dynamic **`SecCodeCopySelf` (`kSecCSDynamicInformation`, `cs_status_flags_hex: 0x22010301`, `cs_valid: true`, `cs_runtime: true`, `cs_debugged: false`)**, live child process inspection via **`SecCodeCopyGuestWithAttributes` (`--pid <pid>` → `target_pid_cs_valid`, `target_pid_code_identifier`, `target_pid_cdhash`)**, **`_dyld_image_count()` non-system image SHA-256 digest** (`1` non-system binary), **`SecStaticCode` CDHash**, and honest **`DCAppAttestService.shared.isSupported` (`false`)** + explicit `integrity_scope: "launcher-strong,native-runtime-measured,guest-jit-unattested"`.
  - Signs canonical JSON claims (`directmetal.attestation.v2`) with hardware ECDSA P-256 SHA-256 X9.62 bound to server nonces; `DirectMetal verify-attest <bundle.json> [--nonce <hex>]` and `dm_attestation_test` verify both v1/v2 bundles and reject mismatched nonces or tampered claims.

---

## 4. Real-World Retail Game Verification & Live Frame-Time Telemetry (M1 Pro)

Real Windows retail games transferred from `LAPTOP-FRD51BOR` (`D:\`) and verified live on Apple M1 Pro (`macOS 26.1` `25B78`) using [dm_fps_probe.mm](../tools/dm_fps_probe/dm_fps_probe.mm) (`CAMetalLayer` hardware present intervals) and `DirectMetal.app` (`5.8 GB` stripped, Hardened Runtime):

| Game (Executable) | Size / Arch / API | Zero-Config DirectMetal Path | Live Verified Result & Frame-Time Telemetry (M1 Pro) |
| :--- | :--- | :--- | :--- |
| **Hades** (`x64\Hades.exe`) | `11.08 GB` / x64 / **D3D11** | **ARM64EC + FEX-Emu + Mullion Direct-to-Metal D3D11** (`--sandbox` verified) | **PASS (`120.00 FPS` locked ProMotion)** — `1512×982` native Retina, `8.333 ms` median, **`107.62 FPS` 1%-low** (`111.15 FPS` 1%-low / `8.957 ms` p99 with `--upscale quality` MetalFX Spatial), `1,350` measured presents, `1.64 GB` RSS, **0 Seatbelt denials** inside `--sandbox` |
| **REANIMAL** (`REANIMAL.exe`, Unreal Engine 5) | `15.94 GB` / x64 / **D3D12 & D3D11** | **ARM64EC + FEX-Emu + Mullion + Bundled `d3d12_guard.dll` + Auto DLSS → Metal 4 MetalFX Temporal** (`--sandbox --perf-mode ultra` verified) | **PASS (`3 / 3` Fresh-Prefix Zero-Config DX12 Metal 4!)** — Bundled [d3d12_guard.c](../graphics/dm_d3d12_placed_guard/d3d12_guard.c) intercepts Mullion's `CreatePlacedResource: E_INVALIDARG (d3d12_device.cpp:1790)` on UE5's 32 KiB offsets (`32768`, `294912`, `360448`) and promotes them cleanly to `CreateCommittedResource` with **0% overhead on valid calls** (verified `3/3` brand-new `--reset-prefix --sandbox --upscale performance --perf-mode ultra` launches!). Auto-routes DLSS → **`MetalFX: temporal upscaling 1248×812 → 1512×984 (Metal 4)`** (`74.52 FPS` mean full Retina `1512×982`, `8.437 ms` p50, `92%` GPU, `recoveryCount=0`); `-dx11` (`1280×720`): **`99.79 FPS`** |
| **Team Fortress 2** (`tf_win64.exe`, Source) | `31.01 GB` / x64 / **D3D9** | **ARM64EC + FEX-Emu + Native ARM64X `DXVK 3.1.1 (MetalVulkan)` → Vulkan 1.4 → Mesa KosmicKrisp → Metal** | **PASS (Zero-Config, 100% Native ARM64 Host)** — Auto-detects `bin/x64/shaderapidx9.dll`, unlocks native **ARM64X `DXVK 3.1.1` (`aarch64 clang 23.1.4`, 8 compiler threads)** via `VK_LAYER_DIRECTMETAL_mvk_compat` (`fillModeNonSolid` index `13`): **`14%` GPU utilization** (down from `68%`!), **`225 MiB` GPU memory** (down from `1,160 MB`!), `0` errors, zero Rosetta 2 |
| **Need for Speed: Hot Pursuit** (`NFS11.exe`) | `7.84 GB` / x86 / **D3D9** | Rosetta 2 + WineD3D GL (default) **or** `--dx9-backend dxvk` (**DXVK → MoltenVK → Metal** via `DM_VK_COMPAT_HOST_IMPORT=1`) | **PASS (Zero-Config + DXVK Metal Path Unlocked)** — WineD3D GL default: `66%` GPU, `758 MB` RSS, `recoveryCount=0`. With `--dx9-backend dxvk` + narrowed `DM_VK_COMPAT_HOST_IMPORT=1`: eliminates `VK_ERROR_OUT_OF_HOST_MEMORY`, creates `CAMetalLayer: WineMetalView` (`800×600`, `18%` GPU, `510 MiB` GPU mem; 3 minor MoltenVK shader warnings). Updating to `macOS 26.4+` (`26.7.3`) further enables native ARM64 WoW64 + KosmicKrisp |
| **Prince of Persia: Forgotten Sands** (`Prince of Persia.exe`) | `1.60 GB` / x86 / **D3D9** | Rosetta 2 + WineD3D GL (`.bind` SteamStub + UPlay) | **Needs Steam Login** — Empirically popped `"Steam Error"` dialog without an active Steam session (no DRM bypass) |
| **Official Windows Steam** (`steam.exe`) | Installed via `scripts/setup_steam.sh` | Rosetta 2 prefix (`steam`) | **PASS** — Silent installer succeeded in `4.3 s`; `steam.exe` boots cleanly for SteamStub titles (`Hades II`, `Assetto Corsa`, `Prince of Persia`) |

### Key Real-Game & Ceiling Breakthroughs Landed
1. **D3D12 Placed-Resource Alignment Guard ([d3d12_guard.c](../graphics/dm_d3d12_placed_guard/d3d12_guard.c) + [d3d12_guard.def](../graphics/dm_d3d12_placed_guard/d3d12_guard.def)):**
   - Bundled into both ARM64EC and Rosetta 2 `base-prefix`es (`system32/d3d12.dll` → `d3d12_mullion.dll` with exact Windows ordinals `@101..@108`), hooking `ID3D12Device::CreatePlacedResource / 1 / 2` (vtable slots `29/69/77`).
   - Zero overhead on spec-aligned calls (`25/25` conformance passing on both ARM64EC and Rosetta 2); transparently promotes UE5's misaligned 32 KiB RDG transient allocations (`d3d12_device.cpp:1790`) to `CreateCommittedResource`, turning `REANIMAL` (UE5 DX12 Metal 4 + Metal 4 MetalFX Temporal) into **`3 / 3` (100%) zero-config fresh-prefix passes** on macOS 26.1!
2. **Universal Vulkan Compatibility Layer ([dm_vk_compat_layer.c](../graphics/dm_vk_compat/dm_vk_compat_layer.c), `VK_LAYER_DIRECTMETAL_mvk_compat`):**
   - Advertises `fillModeNonSolid` (`VkPhysicalDeviceFeatures[13]`) when `DM_VK_COMPAT_ADVERTISE_FILLMODE=1`, unlocking **native ARM64X `DXVK 3.1.1 (MetalVulkan)` + Mesa KosmicKrisp** (cutting `Team Fortress 2` GPU load from `68%` → **`14%`** and GPU memory from `1,160 MB` → **`225 MiB`**).
   - Passes through `VK_EXT_external_memory_host`, clears `nullDescriptor = 0` (unlocking modern `DXVK 2.6.2`), and strips host-allocation flags (`0x80 | 0x100`) on `vkCreateBuffer`/`vkCreateImage` (`DM_VK_COMPAT_HOST_IMPORT=1`), unlocking **32-bit `NFS11.exe` on DXVK → MoltenVK → Metal** on macOS 26.1 with zero `VK_ERROR_OUT_OF_HOST_MEMORY`.
3. **Sub-Native Metal 4 MetalFX Temporal + D3D12 Spatial Upscaling:** [PEInspector.swift](../app/DirectMetalApp/PEInspector.swift) scans PE imports and UE5 plugin directories (`Engine/Plugins/Marketplace`) for `nvngx_dlss`, `amd_fidelityfx`, and `libxess`; [RuntimeLauncher.swift](../app/DirectMetalApp/RuntimeLauncher.swift) maps `--upscale` to **`METALSHARP_DLSS_SCALE`** (`1248×812 → 1512×984` Metal 4 MetalFX Temporal on `REANIMAL`) and emits both `d3d11.metalSpatialUpscale*` and `d3d12.metalSpatialUpscale*` + `d3d12.samplerLodBias`.
4. **`--perf-mode ultra` + FEX `ProfileStats: "0"` Optimization:** Skipping per-frame timestamp counter passes (`d3d11/d3d12.timestampQueries=False`) + parallel D3D12 command encoding + `FEX_PROFILESTATS=0` boosted `d3d11_bench_frame` to **`3434.4 FPS` (`2667.4` 1%-low = `78.5%` of RTX 3070 1%-low)**, `d3d12_bench_frame` to **`2874.8 FPS` (`2355.7` 1%-low = `64.7%` of RTX 3070 1%-low)**, and sandboxed `eng_bench_deferred_pbr` to **`1630.2 FPS` (`1110.9` 1%-low = `4.16×` Rosetta 2 1%-low)**.
5. **Portable SHA-256 Verified Local + Cloud Shader Cache ([ShaderCacheManager.swift](../app/DirectMetalApp/ShaderCacheManager.swift)):** `DirectMetal cache export|import` + SwiftUI GUI export/import buttons package and verify per-file SHA-256 manifests keyed by `(gpu_family, macos_build)` (cold `1118.9 FPS` → imported HTTP cloud cache **`1409.9 FPS`**, `+49.3%` 1%-low).
6. **Hardware-Backed Secure Enclave Attestation v2 (Swift + C/Obj-C++ SDK) + Stripped Hardened `.app` (`5.8 GB`, `-1.4 GB`):** Persistent non-exportable Apple Silicon Secure Enclave P-256 key, `--pid <pid>` live child process `SecCodeCopyGuestWithAttributes` inspection, dynamic `SecCodeCopySelf` + `_dyld_image_count` verification, `--options runtime` Hardened Runtime (verified blocking `DYLD_INSERT_LIBRARIES`), and live SwiftUI Hardware Security status card.
5. **Remaining `D:\` Library Status (Not Yet Transferred / Blocked):**
   - **Counter-Strike 2** (`70.09 GB`, x64 DX11, no `.bind`): Feasible, requires freeing ~35 GB of local cache space before transfer.
   - **Hades II** (`10.97 GB`, x64) & **Assetto Corsa** (`25.63 GB`, x64 DX11): Both carry `.bind` SteamStub DRM — ready to run once the user signs into the installed DirectMetal `steam` prefix.
   - **Apex Legends** (`67.78 GB`): Blocked by `EAAntiCheat` kernel anti-cheat.
   - **Halo Infinite** (`67.76 GB`): Requires D3D12 FL `12_0+` + anti-cheat.
   - **Red Dead Redemption 2** (`119.51 GB`): Exceeds available free disk space + Rockstar Launcher DRM.


