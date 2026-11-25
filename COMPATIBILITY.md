# DirectMetal Compatibility & Visual-Diff Matrix

Automated pixel-level accuracy (`PSNR` / `SSIM`) and frame-time comparison between **Windows x64 + NVIDIA RTX 3070** (ground-truth reference) and **Apple Silicon M1 Pro + DirectMetal (Metal 3/4)**.

## Summary

- **Conformance Pass Rate:** **19 / 19 (100.0%)**
- **Mean SSIM:** `0.999829` (pass threshold `>= 0.995000`)
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
| `d3d11_10_compute_uav` | **PASS** | 63.90 dB | 0.999826 | 1 | 0.00% | EXACT |  |

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

## Performance Benchmarks (RTX 3070 vs. M1 Pro)

| Suite | Reference Mean (ms) | Reference FPS | Reference 1%-Low FPS | DirectMetal Mean (ms) | DirectMetal FPS | DirectMetal 1%-Low FPS | M1 Pro / RTX 3070 FPS |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `d3d11_bench_frame` | 0.045 | 21962.6 | 3397.3 | 0.762 | 1311.9 | 280.6 | 6.0% |
| `d3d12_bench_frame` | 0.108 | 9227.2 | 3641.0 | 0.507 | 1973.4 | 436.0 | 21.4% |

## Native ARM64 Host Subsystem Microbenchmarks

- **NT Sync (os_sync_wait_on_address):** os_sync_wait_on_address : 173.08 ms total | 0.865 us/wakeup
- **POSIX Baseline (pthread_cond):** pthread_cond            : 292.31 ms total | 1.462 us/wakeup (1.69x vs os_sync)
- **IPC Baseline (unix pipe):** unix pipe (IPC baseline): 314.97 ms total | 1.575 us/wakeup (1.82x vs os_sync)
- **APFS CoW Prefix (clonefile):** [dm_prefix_test] APFS CoW clonefile time: 0.447 ms
