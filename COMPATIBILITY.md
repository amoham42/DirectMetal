# DirectMetal Compatibility & Visual-Diff Matrix

Automated pixel-level accuracy (`PSNR` / `SSIM`) and frame-time comparison between **Windows x64 + NVIDIA RTX 3070** (ground-truth reference) and **Apple Silicon M1 Pro + DirectMetal (Metal 3/4)**.

## Summary

- **Conformance Pass Rate:** **25 / 25 (100.0%)**
- **Mean SSIM:** `0.999844` (pass threshold `>= 0.995000`)
- **Minimum PSNR:** `54.32 dB` (pass threshold `>= 40.00 dB`)

## Hardware & Runtime Metadata

| Machine | OS | CPU | GPU / Driver | Runtime |
| :--- | :--- | :--- | :--- | :--- |
| Reference (Windows) | Windows 11 Home 10.0.26200 | AMD Ryzen 7 5800H | NVIDIA GeForce RTX 3070 Laptop GPU (8 GB) (617.42 (32.0.16.1742)) | Native DirectX 11/12 |
| Target (Mac) | macOS 26.1 (25B78) | Apple M1 Pro (8 cores, 16 GB UMA) | Apple M1 Pro (14-core GPU) (Metal 4 / Metal 3) | DirectMetal (Wine 11.21 + Mullion v0.5-alpha.4) |

## D3D11 Conformance (10 / 10 Passed)

- **Reference Adapter:** `NVIDIA GeForce RTX 3070 Laptop GPU` (Feature Level `11_1`)
- **DirectMetal Adapter:** `Apple M1 Pro` (Feature Level `11_1`)

| Test | Result | PSNR | SSIM | Max Diff | >1 LSB % | Checksum | Notes |
| :--- | :--- | ---: | ---: | ---: | ---: | :---: | :--- |
| `d3d11_01_clear_color` | **PASS** | Exact (inf) | 1.000000 | 0 | 0.00% | - |  |
| `d3d11_02_triangle_interp` | **PASS** | 54.32 dB | 0.999693 | 1 | 0.00% | - |  |
| `d3d11_03_indexed_cbuffer` | **PASS** | Exact (inf) | 1.000000 | 0 | 0.00% | - |  |
| `d3d11_04_depth_stencil` | **PASS** | 68.51 dB | 0.999867 | 1 | 0.00% | - |  |
| `d3d11_05_alpha_blend` | **PASS** | 59.62 dB | 0.999969 | 1 | 0.00% | - |  |
| `d3d11_06_texture_sampling` | **PASS** | 55.77 dB | 0.999402 | 3 | 1.88% | - |  |
| `d3d11_07_mrt_postprocess` | **PASS** | 62.55 dB | 0.999479 | 1 | 0.00% | - |  |
| `d3d11_08_msaa_resolve` | **PASS** | 68.63 dB | 0.999982 | 1 | 0.00% | - |  |
| `d3d11_09_instancing` | **PASS** | 69.45 dB | 0.999990 | 1 | 0.00% | - |  |
| `d3d11_10_compute_uav` | **PASS** | 63.95 dB | 0.999828 | 1 | 0.00% | EXACT |  |

## D3D12 Conformance (9 / 9 Passed)

- **Reference Adapter:** `NVIDIA GeForce RTX 3070 Laptop GPU` (Feature Level `12_2`)
- **DirectMetal Adapter:** `Apple M1 Pro` (Feature Level `11_1`)

| Test | Result | PSNR | SSIM | Max Diff | >1 LSB % | Checksum | Notes |
| :--- | :--- | ---: | ---: | ---: | ---: | :---: | :--- |
| `d3d12_01_clear_rtv` | **PASS** | Exact (inf) | 1.000000 | 0 | 0.00% | - |  |
| `d3d12_02_triangle_pso` | **PASS** | 54.33 dB | 0.999676 | 1 | 0.00% | - |  |
| `d3d12_03_root_constants_cbv` | **PASS** | 65.49 dB | 0.999998 | 1 | 0.00% | - |  |
| `d3d12_04_depth_stencil_3d` | **PASS** | 67.65 dB | 0.999838 | 1 | 0.00% | - |  |
| `d3d12_05_srv_descriptor_table` | **PASS** | 64.36 dB | 0.999836 | 1 | 0.00% | - |  |
| `d3d12_06_multi_pso_blend` | **PASS** | 56.71 dB | 0.999987 | 2 | 6.25% | - |  |
| `d3d12_07_compute_uav` | **PASS** | 64.72 dB | 0.999841 | 1 | 0.00% | EXACT |  |
| `d3d12_08_multi_pass_fence` | **PASS** | 62.02 dB | 0.999359 | 1 | 0.00% | - |  |
| `d3d12_09_execute_indirect` | **PASS** | 65.24 dB | 0.999999 | 1 | 0.00% | - |  |

## D3D12-Engine Conformance (6 / 6 Passed)

- **Reference Adapter:** `NVIDIA GeForce RTX 3070 Laptop GPU` (Feature Level `12_2`)
- **DirectMetal Adapter:** `Apple M1 Pro` (Feature Level `11_1`)

| Test | Result | PSNR | SSIM | Max Diff | >1 LSB % | Checksum | Notes |
| :--- | :--- | ---: | ---: | ---: | ---: | :---: | :--- |
| `eng_01_deferred_gbuffer` | **PASS** | 60.95 dB | 0.999419 | 1 | 0.00% | - |  |
| `eng_02_shadow_pcf` | **PASS** | 66.77 dB | 0.999979 | 1 | 0.00% | - |  |
| `eng_03_gpu_cull_indirect` | **PASS** | Exact (inf) | 1.000000 | 0 | 0.00% | EXACT |  |
| `eng_04_hdr_bloom_tonemap` | **PASS** | 71.60 dB | 0.999974 | 1 | 0.00% | - |  |
| `eng_05_wave_ops` | **PASS** | 67.95 dB | 0.999994 | 1 | 0.00% | EXACT |  |
| `eng_06_bindless` | **PASS** | 64.17 dB | 0.999977 | 1 | 0.00% | - |  |

## Performance Benchmarks (RTX 3070 vs. M1 Pro)

| Suite | Reference Mean (ms) | Reference FPS | Reference 1%-Low FPS | DirectMetal Mean (ms) | DirectMetal FPS | DirectMetal 1%-Low FPS | M1 Pro / RTX 3070 FPS |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `d3d11_bench_frame` | 0.045 | 21962.6 | 3397.3 | 0.315 | 3176.2 | 2010.1 | 14.5% |
| `d3d12_bench_frame` | 0.108 | 9227.2 | 3641.0 | 0.362 | 2765.2 | 2020.2 | 30.0% |
| `eng_bench_deferred_pbr` | 0.248 | 4030.9 | 2153.8 | 0.678 | 1475.1 | 720.1 | 36.6% |

## Native ARM64 Host Subsystem Microbenchmarks

- **NT Sync (os_sync_wait_on_address):** os_sync_wait_on_address : 237.78 ms total | 1.189 us/wakeup
- **POSIX Baseline (pthread_cond):** pthread_cond            : 271.87 ms total | 1.359 us/wakeup (1.14x vs os_sync)
- **IPC Baseline (unix pipe):** unix pipe (IPC baseline): 308.98 ms total | 1.545 us/wakeup (1.30x vs os_sync)
- **APFS CoW Prefix (clonefile):** [dm_prefix_test] APFS CoW clonefile time: 0.409 ms

## Phase 2 — Apple Silicon Deep Optimizations (M1 Pro)

| Optimization Subsystem | Baseline | DirectMetal M1+ Optimized | Gain / Accuracy |
| :--- | :--- | :--- | :--- |
| **UMA Zero-Copy (`MTLStorageModeShared`)** | 0.686 ms (7.12 GB/s, 15.00 MiB) | 0.454 ms (10.77 GB/s, 5.06 MiB) | **1.51x** faster, **-66.2%** memory (bit-exact) |
| **TBDR Coalescing + `MTLStorageModeMemoryless`** | 9 passes, 1.068 ms, 64.75 MiB DRAM | 1 pass, 0.394 ms, 0.00 MiB DRAM | **2.71x** faster, **-64.75 MiB** DRAM (max_diff=0) |
| **`MTLBinaryArchive` Pipeline Cache** (`demo_v1_apple7_25B78_m4`) | Cold compile: 88.18 ms (24 PSOs) | Warm archive load: 1.32 ms (24/24 strict hits) | **66.7x** faster warm PSO load |
| **Mullion D3D12 End-to-End Cache (`dm_d3d12_conformance.exe`)** | Cold cache: 16.779 s | Warm cache: 0.983 s (378640 bytes) | **17.07x** end-to-end launch speedup |
| **MetalFX Spatial Quality (720p -> 1080p, 1.5x)** | Native 1080p: 6.126 ms (163.2 FPS) | Spatial Quality: 3.559 ms (281.0 FPS) | **1.72x** FPS (PSNR=51.23 dB, SSIM=0.9941) |
| **MetalFX Spatial Perf (540p -> 1080p, 2.0x)** | Native 1080p: 6.126 ms (163.2 FPS) | Spatial Perf: 2.403 ms (416.2 FPS) | **2.55x** FPS |
| **MetalFX Temporal Quality (720p -> 1080p, 1.5x)** | Native 1080p FP16: 6.111 ms | Temporal Quality: 5.540 ms (180.5 FPS) | **1.10x** FPS (PSNR=55.95 dB, SSIM=0.9991) |

## Phase 3 — Post-Rosetta Native ARM64EC + FEX-Emu Comparison (M1 Pro)

- **ARM64EC + FEX-Emu Conformance (vs. RTX 3070):** **19 / 19 (100.0%)** | Mean SSIM: `0.999829` | Min PSNR: `54.32 dB`
- **Native ARM64 Host I/O:** CoreAudio `MacBook Pro Speakers` (48000 Hz, 12.21 ms latency), GameController.framework `ready`

| Benchmark Suite | RTX 3070 (FPS / 1%-Low) | M1 Pro Rosetta 2 (FPS / 1%-Low) | M1 Pro ARM64EC+FEX TSO=1 (FPS / 1%-Low) | M1 Pro ARM64EC+FEX TSO=0 (FPS / 1%-Low) | ARM64EC TSO=1 vs Rosetta 2 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `d3d11_bench_frame` | 21962.6 / 3397.3 | 1336.4 / 280.2 | 1715.4 / 339.4 | 1743.3 / 186.1 | **1.28x** |
| `d3d12_bench_frame` | 9227.2 / 3641.0 | 1893.9 / 471.6 | 2630.7 / 796.0 | 2321.9 / 614.8 | **1.39x** |

## Phase 4 — Engine Patterns (SM 6.0 DXIL), Seatbelt Sandbox & Attestation (M1 Pro)

- **Engine Conformance (`eng_01`–`eng_06`, ARM64EC+FEX Sandboxed vs. RTX 3070):** **6 / 6 (100.0%)** | Mean SSIM: `0.999891` | Min PSNR: `60.95 dB`
- **Seatbelt Sandbox (`sandbox-exec`):** `5/5` kernel `EPERM` assertions passed (sibling prefix read blocked, `~/.ssh` blocked, unapproved `$HOME` writes blocked; target prefix + shader cache RW intact)
- **Opt-In Attestation (`ECDSA-P256-SHA256-X962`):** SIP=`True`, SSV=`True`, `DCAppAttestService.isSupported`=`False` (honest macOS capability), signature verified=`True`, tampered-claim rejected=`True`

| 1024x1024 Deferred PBR Benchmark | Mean Frame Time | FPS | 1%-Low FPS | GPU Mean (ms) | Throughput (MP/s) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Windows RTX 3070** (Native SM 6.0) | 0.248 ms | 4030.9 | 2153.8 | 0.114 ms | 4226.7 |
| **M1 Pro Rosetta 2** (Mullion DXIL->Metal) | 0.737 ms | 1357.1 | 259.5 | 0.298 ms | 1423.0 |
| **M1 Pro ARM64EC+FEX (Sandboxed)** | 0.638 ms | 1566.3 | 753.8 | 0.301 ms | 1642.4 |
