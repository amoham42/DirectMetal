## Summary

Describe what this pull request changes and why.

## Subsystem Touchpoints

- [ ] `app/DirectMetalApp/` — SwiftUI Game Library, CLI, `RuntimeManager`, `PEInspector`, or peripherals
- [ ] `graphics/` — `dm_metal_core` (UMA/TBDR), `dm_d3d12_placed_guard` (`d3d12_x64.dll`), or `dm_vk_compat`
- [ ] `runtime/` — `dm_sync`, `dm_prefix` (APFS CoW), `dm_host_io`, `mullion.conf`, or `runtime/profiles/game_profiles.json`
- [ ] `shaders/` — `dm_shader_cache` (`MTLBinaryArchive`) or Cloud Shader Cache CDN (`ShaderCacheManager` / `publish_shader_cache.sh`)
- [ ] `upscaling/` — `dm_metalfx_bridge` or DLSS/FSR/XeSS shims
- [ ] `sandbox/` — Seatbelt profile (`directmetal_game.sb.tmpl`), `dm_sandbox`, or Secure Enclave Attestation v2 (`dm_attestation`)
- [ ] `scripts/` / `tools/` / `.github/` — Build, DMG packaging, RTX 3070 visual diff harness, or CI/CD workflows
- [ ] Documentation / Community Profiles

## Verification & Measured Results

- **Hardware & OS Tested:** (e.g., Apple M1 Pro / M4, `sw_vers`)
- **Local CI Gate (`./scripts/run_ci_local.sh` / `make ci`):**
- **Visual Conformance / Benchmarks (if graphics, shader, or runtime code changed):**
  - PSNR / SSIM diff results (`tools/diff_harness.py`) or subsystem microbenchmark output:

## PR Checklist

- [ ] `./scripts/run_ci_local.sh` passes cleanly with zero regressions
- [ ] `DirectMetal-Lite.app` builds with Hardened Runtime and passes `codesign --verify --strict`
- [ ] No proprietary game binaries, credentials, or build artifacts (`dist/`, `build/`, `captures/`) are committed
- [ ] Security boundaries (Seatbelt confinement, SHA-256 verification, honest attestation claims) remain intact
