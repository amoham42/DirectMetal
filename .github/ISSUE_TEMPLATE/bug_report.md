---
name: Bug Report
about: Report a crash, rendering regression, launcher issue, or sandbox/runtime bug in DirectMetal
title: "[Bug]: "
labels: ["bug"]
---

## Summary

A clear, concise description of the bug and what you expected to happen instead.

## Hardware & Runtime Environment

- **Apple Silicon Mac:** (e.g., MacBook Pro M1 Pro 16 GB / Mac mini M4 24 GB)
- **macOS Version & Build (`sw_vers`):** (e.g., macOS 26.7.1 `26A...` or macOS 15.x)
- **Package Variant:** `DirectMetal-Lite.app` / Offline `DirectMetal.app` / Source build
- **Runtime Status (`DirectMetal runtime status`):**

<details>
<summary>Paste <code>DirectMetal info</code> output</summary>

```json
Paste output of: /Applications/DirectMetal-Lite.app/Contents/MacOS/DirectMetal info
```

</details>

## Workload / Game Details (if applicable)

- **Title & Storefront:** (e.g., Hades — Steam / Standalone, or conformance binary)
- **Executable & Architecture:** (`x64` / `x86` from `DirectMetal inspect <exe>`)
- **Graphics API & Upscaler:** (`D3D9` / `D3D10` / `D3D11` / `D3D12`, `DLSS` / `FSR` / `XeSS` / `MetalFX`)
- **Launch Flags / Saved Library Settings:** (e.g., `--engine arm64ec --perf-mode ultra --upscale quality --sandbox`)

## Steps to Reproduce

1.
2.
3.

## Diagnostics & Logs

Paste terminal `stderr` output, Metal HUD observations, or Seatbelt sandbox denials if `--sandbox` was active. Never include proprietary game binaries, license keys, or personal paths/tokens.

```text
Paste relevant terminal output here
```
