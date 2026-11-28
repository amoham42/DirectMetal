# How DirectMetal Compares

DirectMetal is designed specifically for **Apple Silicon (M1–M5)** Macs as a single, open-source (MIT) app + CLI without manual bottle management or Vulkan middlemen for DX10–12.

## Architectural Comparison

| Feature | **DirectMetal** | **Whisky** | **Kegworks** | **CrossOver** | **Apple GPTK (Raw)** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **License / Cost** | **MIT (Free & Open Source)** | GPLv3 (Archived / unmaintained) | LGPL / Open Source | Commercial (Paid) | Proprietary Eval License |
| **DirectX 10/11/12 Stack** | Direct-to-Metal 3/4 (`Mullion` / `DXMT`, `FL 12_2`) | D3DMetal (older GPTK) | D3DMetal / DXVK / DXMT | D3DMetal / DXVK / DXMT | D3DMetal |
| **Post-Rosetta ARM64EC + FEX** | **Native 64-bit & 32-bit** (macOS 26.4+) | Rosetta 2 only | Rosetta 2 / manual | Rosetta 2 + experimental | Rosetta 2 |
| **Installer Size** | **`2.8 MiB` Lite** (`1.3 GB` offline) | `~100+ MB` + manual GPTK | Engine downloads | `~1.5 GB` | `~2 GB` developer kit |
| **Per-Game Isolation** | **APFS CoW (`0.4 ms`) + Seatbelt Sandbox** | Manual Bottles | Manual Wrappers | Manual Bottles | Manual `WINEPREFIX` |
| **Shader Cache Sharing** | **Double SHA-256 Cloud CDN** (`MTLBinaryArchive`) | Local only | Local only | Local only | Local only |
| **Storefront Auto-Scan** | **Steam, GOG Galaxy, Epic** + PE `.exe` icons | Manual | Manual | Partial | None (CLI only) |
| **Warm Launch Pool** | **Yes (`70–100 ms` repeat launches)** | No | No | No | No |
| **Hardware Attestation** | **Secure Enclave P-256 v2** (`DirectMetal attest`) | No | No | No | No |
| **Controller Remapping** | **Built-in GUI + `SDL_GAMECONTROLLERCONFIG`** | None | None | Basic | None |
| **CLI Automation** | **Full JSON CLI** (`info`, `library`, `cache`, `controller`, `update`) | Minimal | Minimal | Limited | CLI only |

## When to Choose DirectMetal vs. Alternatives

- **Choose DirectMetal** if you want a **free, MIT-licensed, Apple Silicon–native** launcher with zero bottle tinkering, 100% post-Rosetta ARM64EC + FEX execution (including 32-bit games on macOS 26.4+), Metal 4 / `FL 12_2`, Seatbelt per-game sandboxing, warm `wineserver` launches, and full CLI automation.
- **Choose CrossOver** if you need paid commercial support, bundled Microsoft/Office productivity apps, or official upstream Wine enterprise maintenance on older macOS versions (macOS 13–14).
- **Choose Kegworks** if you want to hand-build standalone `.app` wrappers per game with custom WineCX engines on Intel or older macOS versions.

## Ground-Truth Verification Philosophy

Unlike wrappers that ship unmeasured config tweaks, every DirectMetal optimization is gated against:
1. **Pixel-accurate conformance (`25 / 25`)** compared directly against a physical **Windows 11 + NVIDIA RTX 3070** oracle (`Mean SSIM >= 0.9998`, `Min PSNR >= 54 dB`).
2. **Automated Apple Silicon CI** (`macos-15` Xcode 16 + local M1 Pro & Apple M4 verification) running all 8 native C/Obj-C++ subsystem tests and Swift unit tests.
