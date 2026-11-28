# DirectMetal Benchmarks & Verification Methodology

All performance and visual-conformance measurements in DirectMetal are produced on real Apple Silicon hardware and compared pixel-for-pixel against a native **Windows 11 + NVIDIA GeForce RTX 3070** ground-truth oracle.

## 1. Conformance & Throughput Across Apple Silicon

| Machine | GPU Family | macOS | Conformance vs. RTX 3070 | Mean SSIM | Min PSNR | D3D12 `FL 12_2` | Deferred PBR (1024²) | Warm Launch (`--warm-server`) |
| :--- | :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| **Windows 11 Reference** | NVIDIA RTX 3070 (8 GB) | `10.0.26200` | Ground-Truth Oracle | `1.000000` | `inf` | `9,227 FPS` (`0.108 ms`) | `4,031 FPS` (`0.248 ms`) | — |
| **Apple M1 Pro** (`MacBookPro18,3`) | `Apple7` (14-core, 16 GB UMA) | `27.2.1` (`26B131`) | **`25 / 25` (100%)** | `0.999841` | `53.86 dB` | **`2,694 FPS`** (`0.738 s` wall) | **`1,569 FPS`** (`0.665 s` wall) | **`70 ms`** (`10.0×`) |
| **Apple M4** (`Mac16,1`, Lite App) | `Apple9` (10-core, 16 GB UMA) | `26.7.1` (`25G241`) | **`25 / 25` (100%)** | `0.999844` | `53.86 dB` | **`4,490 FPS`** (`0.490 s` wall) | **`2,092 FPS`** (`0.433 s` wall) | **`100 ms`** (`10.7×`) |

- **Conformance breakdown (`25 / 25`):** `10 / 10` D3D11 (`FL 11_1`), `9 / 9` D3D12 (`FL 12_2`), and `6 / 6` SM 6.0 DXIL Engine Patterns (Deferred G-Buffer, PCF Shadows, GPU Indirect Culling, HDR Bloom/Tonemap, Wave Ops, Bindless Descriptors).
- **Zero sandbox overhead:** Running `eng_bench_deferred_pbr` inside the macOS Seatbelt kernel sandbox (`--sandbox`) measured **`2,095.5 FPS`** on Apple M4 vs. **`2,092.0 FPS`** unsandboxed (within noise).

## 2. Apple Silicon Subsystem Microbenchmarks

| Subsystem | Metric | Apple M1 Pro (`Apple7`) | Apple M4 (`Apple9`) | Notes |
| :--- | :--- | ---: | ---: | :--- |
| **NT Sync (`os_sync_wait_on_address`)** | 200k wakeups | `289.44 ms` (`1.447 µs/op`) | `213.55 ms` (`1.068 µs/op`) | `1.23×` faster than Unix pipe IPC |
| **APFS CoW Prefix (`clonefile(2)`)** | Full Wine prefix clone | `0.413 ms` | `0.252 ms` | Zero extra disk blocks on APFS |
| **Base Prefix Hydration** | Dehydrated `0.62 MiB` → full prefix | `~151 ms` | `~110 ms` | One-time per runtime fingerprint |
| **UMA Zero-Copy (`MTLStorageModeShared`)** | CPU→GPU transfer | `0.454 ms` (`10.77 GB/s`) | — | `1.51×` faster, `-66.2%` RAM vs. staging |
| **TBDR Coalescing + `Memoryless`** | 9-pass G-Buffer → 1 pass | `0.394 ms`, `0.00 MiB` DRAM | — | `2.71×` faster, `-64.75 MiB` DRAM |
| **`MTLBinaryArchive` Pipeline Cache** | 24 PSO warm load | `1.32 ms` (**`66.7×`** vs. `88.18 ms`) | `1.00 ms` (**`254.1×`** vs. `252.81 ms`) | `24 / 24` (`100%`) strict archive hits |
| **MetalFX Spatial Quality (`720p→1080p`)** | 1.5× upscale | `281.0 FPS` (**`1.72×`**) | — | `PSNR 51.23 dB`, `SSIM 0.9941` |
| **MetalFX Temporal Quality (`720p→1080p`)** | 1.5× temporal | `180.5 FPS` (**`1.10×`**) | — | `PSNR 55.95 dB`, `SSIM 0.9991` |

## 3. Packaging & Delivery Size Benchmarks

| Artifact | Uncompressed `.app` | Compressed `.dmg` | Install / Hydration Time |
| :--- | ---: | ---: | :--- |
| **`DirectMetal-Lite.app`** (recommended) | **`2.9 MB`** | **`2.8 MiB`** (ULFO) | `11.86 s` (LAN) / `75.9 s` (GitHub CDN) |
| **`DirectMetal.app` Offline** (dehydrated + hardlink-deduped) | **`3.7 GB`** *(down from `7.5 GB`, `-50.7%`)* | **`1.3 GB`** (ULFO) / **`1.0 GB`** (ULMO LZMA) | Offline instant (`~151 ms` APFS clone) |

## 4. Reproducing Locally

```bash
# 1. Run all 8 native C/Obj-C++ subsystem benchmarks, unit tests & app smoke checks (~35s)
make ci

# 2. Verify system readiness & hardware telemetry
./dist/DirectMetal-Lite.app/Contents/MacOS/DirectMetal doctor
./dist/DirectMetal-Lite.app/Contents/MacOS/DirectMetal info

# 3. Run D3D11 / D3D12 / Engine conformance & throughput benchmarks (requires built tests/dx_conformance)
python3 tools/run_mac_conformance.py --suite all
```

See [COMPATIBILITY.md](../COMPATIBILITY.md) for the complete 25-test per-case PSNR/SSIM table and [ENGINE_COMPATIBILITY_MATRIX.md](ENGINE_COMPATIBILITY_MATRIX.md) for retail game telemetry.
