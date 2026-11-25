# DirectMetal M1 Pro Environment Audit

Generated: `2026-11-25T14:31:06Z`

## Hardware & OS

- **macOS Version:** 26.1 (Build `25B78`)
- **Kernel:** `Darwin MacBookPro.lan 25.1.0 Darwin Kernel Version 25.1.0: Mon Oct 20 19:32:41 PDT 2025; root:xnu-12377.41.6~2/RELEASE_ARM64_T6000 arm64`
- **CPU:** Apple M1 Pro (8 cores)
- **Unified Memory:** 16 GB (`17179869184` bytes)
- **Rosetta 2 (x86_64):** `x86_64`
- **GPU / Metal Info:**
```
Chipset Model: Apple M1 Pro
Total Number of Cores: 14
Metal Support: Metal 4
```

## Xcode, Metal SDK & Toolchain

- **Developer Dir:** `/Applications/Xcode.app/Contents/Developer`
- **Xcode:** Xcode 26.1.1 Build version 17B100
- **macOS SDK:** 26.1 (`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.1.sdk`)
- **Metal 4 Headers:** Yes (`MTL4CommandQueue.h`)
- **MetalFX Headers:** Yes (`MetalFX.h`)
- **Fast Sync Header:** Yes (`os/os_sync_wait_on_address.h`)
- **MetalToolchain Component:** `Asset Path: /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/68d8db6212b48d387d071ff7b905df796658e713.asset/AssetData;Build Version: 17B54;Status: installed;Toolchain Identifier: com.apple.dt.toolchain.Metal.32023;Toolchain Search Path: /private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.2.54.0.LboqpC;`
- **`xcrun -f metal`:** `/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.2.54.0.LboqpC/Metal.xctoolchain/usr/bin/metal`
- **`xcrun metal --version`:** `Apple metal version 32023.830 (metalfe-32023.830.2) Target: air64-apple-darwin25.1.0 `
- **`xcrun -f metallib`:** `/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.2.54.0.LboqpC/Metal.xctoolchain/usr/bin/metallib`
- **`clang++`:** `Apple clang version 17.0.0 (clang-1700.4.4.1)`
- **`swiftc`:** `swift-driver version: 1.127.14.1 Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8 clang-1700.4.4.1)`

## CLI & Build Tools

| Tool | Status | Path | Version |
| :--- | :--- | :--- | :--- |
| `brew` | Found | `/opt/homebrew/bin/brew` | `Homebrew 7.0.16` |
| `cmake` | Found | `/opt/homebrew/bin/cmake` | `cmake version 3.31.3` |
| `ninja` | Found | `/opt/homebrew/bin/ninja` | `1.13.2` |
| `meson` | Found | `/opt/homebrew/bin/meson` | `1.12.1` |
| `pkg-config` | Found | `/opt/homebrew/bin/pkg-config` | `2.5.1` |
| `dxc` | Found | `/usr/local/bin/dxc` | `libdxcompiler.dylib: 1.9(dev;5049-d72f75ee)` |
| `python3` | Found | `/opt/homebrew/bin/python3` | `Python 3.15.2` |
| `uv` | Found | `/Users/amoham42/.langflow/uv/uv` | `uv 0.9.13 (7ca92dcf6 2025-11-26)` |
| `git` | Found | `/usr/bin/git` | `git version 2.50.1 (Apple Git-155)` |
| `gh` | Found | `/opt/homebrew/bin/gh` | `gh version 2.103.0 (2026-10-21)` |

- **Python Diff Venv (`.venv`):** Ready (`numpy 2.5.5, Pillow 13.0.0`)
- **Git Origin:** `https://github.com/amoham42/DirectMetal.git`
- **GitHub CLI Auth:** `github.com ✓ Logged in to github.com account amoham42 (keyring) - Active account: true - Git operations protocol: https - Token: gho_************************************ - Token scopes: 'gist', 'read:org', 'repo', 'workflow' `
