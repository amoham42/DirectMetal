# Contributing to DirectMetal

Thank you for contributing to **DirectMetal** — the unified, Apple Silicon–first DirectX 9/10/11/12 compatibility runtime and launcher for macOS.

---

## Prerequisites

DirectMetal targets Apple Silicon hardware exclusively (`arm64`, M1 and newer):

- **Hardware:** Apple Silicon Mac (`M1` / `M2` / `M3` / `M4` / `M5`)
- **OS:** macOS 15.0 Sequoia or newer (`macOS 26.4+` recommended for 100% post-Rosetta ARM64EC + FEX execution of both 64-bit and 32-bit titles)
- **Xcode Command Line Tools:** `xcode-select --install` (`swiftc`, `clang`, `clang++`, `codesign`, `hdiutil`, Metal SDK headers)
- **CMake (>= 3.20):** `brew install cmake ninja` (builds native C/Obj-C++ runtime, graphics, shader cache, upscaling, and sandbox libraries)
- **Python (>= 3.10):** Used by build deduplication/dehydration scripts and the PSNR/SSIM visual diff harness (`pip install pillow numpy`)
- **Optional Cross-Compiler:** `llvm-mingw` (`x86_64-w64-mingw32-clang`) in `PATH` or `.directmetal_cache/toolchains/llvm-mingw/` when rebuilding `graphics/dm_d3d12_placed_guard/d3d12_guard.c` (`d3d12_x64.dll`)

---

## 60-Second Quick Dev Loop

```bash
# 1. Lint shell scripts, Python tools, JSON configs, and workflow YAMLs
make lint

# 2. Build & run C/Obj-C++ subsystem tests + Python visual-diff unit tests
make test

# 3. Compile & sign compact DirectMetal-Lite.app (~2.3–2.9 MB) into dist/
make app-lite
./dist/DirectMetal-Lite.app/Contents/MacOS/DirectMetal info

# 4. Run the full local CI gate before opening a PR
make ci
```

Run `make help` at any time to list all build, packaging, conformance, and cleanup targets.

---

## Repository Directory Map

| Path | Description |
| :--- | :--- |
| `app/DirectMetalApp/` | Native `arm64` Swift / SwiftUI launcher (`DirectMetalGUI.swift`), CLI (`main.swift`), `GameLibraryManager`, `RuntimeManager`, `RuntimeLauncher`, `PEInspector`, `BasePrefixHydrator`, `ShaderCacheManager`, `SandboxAttestation`, and controller/peripheral telemetry |
| `graphics/dm_metal_core/` | Native Objective-C++ Metal 3/4 device probe, UMA zero-copy allocator (`MTLStorageModeShared`), and TBDR render-pass coalescer (`MTLStorageModeMemoryless`) |
| `graphics/dm_d3d12_placed_guard/` | Win64 `d3d12.dll` shim (`d3d12_guard.c`) that promotes misaligned UE5 32 KiB placed-resource allocations to `CreateCommittedResource` |
| `graphics/dm_vk_compat/` | Universal `arm64`/`x86_64` Vulkan layer (`VK_LAYER_DIRECTMETAL_mvk_compat`) for DXVK / KosmicKrisp / MoltenVK compatibility |
| `runtime/dm_sync/` | Fast NT event/semaphore synchronization built on `os_sync_wait_on_address` |
| `runtime/dm_prefix/` | Zero-copy per-game Wine prefix cloning via APFS `clonefile()` (`~0.41 ms`) |
| `runtime/dm_host_io/` | Native ARM64 CoreAudio latency probe and `GameController.framework` input telemetry |
| `runtime/config/` & `runtime/profiles/` | Default `mullion.conf` tuning and community per-game presets (`game_profiles.json`) |
| `shaders/dm_shader_cache/` | `MTLBinaryArchive` pipeline cache manager keyed by `(build_hash, gpu_family, macos_build)` |
| `upscaling/` | `dm_metalfx_bridge` (`MTLFXSpatialScaler` / `MTLFXTemporalScaler`) and DLSS/FSR/XeSS interceptor shims |
| `sandbox/` | Hardened Runtime entitlements (`DirectMetal.entitlements`), Seatbelt template (`directmetal_game.sb.tmpl`), `dm_sandbox`, and Secure Enclave Attestation v2 (`dm_attestation`) |
| `tests/` | D3D11, D3D12, and SM 6.0 DXIL Engine conformance sources plus Windows 11 + NVIDIA RTX 3070 ground-truth captures (`tests/reference/rtx3070/`) |
| `tools/` | Pixel-accurate Wang-Bovik SSIM / PSNR visual diff harness (`diff_harness.py`, `test_diff_harness.py`) and `CAMetalLayer` frame-time probe (`dm_fps_probe`) |
| `scripts/` | App bundler (`package_app.sh`), ULFO/ULMO DMG builder (`build_dmg.sh`), prefix dehydrator, hardlink deduplicator, Cloud Shader Cache publisher (`publish_shader_cache.sh`), and local CI runner (`run_ci_local.sh`) |

---

## Contributing a Game Compatibility Profile

Community per-game presets live in `runtime/profiles/game_profiles.json` and are bundled into `Contents/Resources/game_profiles.json` by `scripts/package_app.sh` so games run out-of-the-box with zero manual tuning.

1. **Inspect the Windows executable** to record its PE architecture (`x64` / `x86`), imported DirectX APIs, upscaler DLLs, and deterministic `buildHash`:
   ```bash
   ./dist/DirectMetal-Lite.app/Contents/MacOS/DirectMetal inspect "/path/to/Game.exe"
   ```
2. **Verify optimal runtime flags** on Apple Silicon (`--engine`, `--perf-mode`, `--dx9-backend`, `--upscale`, `--retina`, `--sandbox`):
   ```bash
   ./dist/DirectMetal-Lite.app/Contents/MacOS/DirectMetal run "/path/to/Game.exe" --perf-mode ultra --hud --sandbox
   ```
3. **Add or update the entry** in `runtime/profiles/game_profiles.json` with clean 2-space indentation, matching by executable name (and optional `buildHash` when build-specific).
4. **Validate JSON syntax & packaging:**
   ```bash
   make lint && make app-lite
   ```
5. Include your Apple Silicon model, `sw_vers`, resolution, and measured FPS / 1%-low telemetry in your pull request (or open a **Game Compatibility Report** issue).

---

## Running the RTX 3070 Visual Diff Harness

Every rendering, shader translation, and upscaling change is evaluated against native **Windows 11 + NVIDIA RTX 3070** reference captures in `tests/reference/rtx3070/` (`PSNR >= 40.0 dB` and `SSIM >= 0.995` required across all 25 conformance tests):

```bash
# Set up Python environment for Pillow + NumPy
python3 -m venv .venv
.venv/bin/pip install pillow numpy

# Run synthetic PSNR / SSIM / report unit tests
.venv/bin/python tools/test_diff_harness.py

# Compare candidate Apple Silicon captures against RTX 3070 ground truth
.venv/bin/python tools/diff_harness.py \
  --ref tests/reference/rtx3070 \
  --cand captures/m1pro \
  --save-diffs captures/diffs \
  --json-out captures/m1pro/diff_report.json

# Or run the full end-to-end macOS conformance capture + diff pipeline
make conformance
```

---

## Code Style & Engineering Guidelines

- **Formatting:** Follow `.editorconfig` (`UTF-8`, `LF` line endings, 4-space indentation for Swift/C/C++/Obj-C++/Python/CMake, 2-space indentation for Shell/YAML/JSON, tabs for `Makefile`).
- **Swift (`app/DirectMetalApp/`):** Target `arm64-apple-macos15.0` cleanly under `-O -whole-module-optimization` with zero external SwiftPM dependencies so `package_app.sh` builds standalone with Xcode Command Line Tools.
- **C / C++ / Objective-C++ (`graphics/`, `runtime/`, `shaders/`, `upscaling/`, `sandbox/`):** C11 and C++17 / Obj-C++17 (`-fobjc-arc`). Compile cleanly under `-Wall -Wextra` (`-Werror` in security-critical `sandbox/` modules). Keep `assert()` checks side-effect-safe.
- **Shell & Python (`scripts/`, `tools/`):** Start Bash scripts with `#!/usr/bin/env bash` and `set -euo pipefail`. Keep `scripts/*.py` on the Python 3 standard library; keep `pillow`/`numpy` confined to `tools/diff_harness.py` and conformance runners.
- **Security & Honesty:** Never weaken Seatbelt deny rules, skip SHA-256 or `codesign` verification by default, or spoof OS/hardware attestation signals. Never commit proprietary game binaries, copyrighted assets, or signing credentials.

---

## Pull Request Checklist

- [ ] `./scripts/run_ci_local.sh` (`make ci`) passes end-to-end
- [ ] `git status` is clean (`dist/`, `build/`, and temporary captures removed via `make clean`)
- [ ] New CLI flags or JSON schema fields preserve backward compatibility with existing user libraries and caches
- [ ] Measured hardware/OS verification output is included in the PR description
