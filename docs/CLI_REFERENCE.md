# DirectMetal CLI Reference

DirectMetal ships a single unified `arm64` binary inside `DirectMetal-Lite.app/Contents/MacOS/DirectMetal` (or `DirectMetal.app/Contents/MacOS/DirectMetal`). Launch it with no arguments to open the native SwiftUI GUI, or pass a subcommand for scripted/headless workflows.

```bash
DM="/Applications/DirectMetal-Lite.app/Contents/MacOS/DirectMetal"
```

---

## System Diagnostics & Shell Integration

| Command | Description |
| :--- | :--- |
| `DirectMetal doctor [--json]` | Run a 9-point Apple Silicon readiness check (GPU/Metal, macOS tier, ARM64EC runtime + `codesign`, graphics layers, base prefix, Display Retina/ProMotion/HDR, shader cache + profiles, controllers, SIP/SSV/Secure Enclave). Exits `0` if ok/warn, `1` on failure. |
| `DirectMetal info` | Print structured JSON hardware telemetry (`gpu_name`, `gpu_family`, `cache_key`, `working_set_gib`, `supports_metal4`, display DPI/Hz/EDR, controllers). |
| `DirectMetal completions zsh\|bash` | Output a native tab-completion script for `zsh` (`eval "$($DM completions zsh)"`) or `bash` (`eval "$($DM completions bash)"`). |
| `DirectMetal help` | Show concise CLI usage summary. |

---

## Game Library & Community Profiles

| Command | Description |
| :--- | :--- |
| `DirectMetal library scan [dir ...]` | Auto-discover Steam, GOG Galaxy, Epic Games Store, Heroic, and local Windows executables, inspect PE headers (`PEInspector`), and seed matching community profiles. |
| `DirectMetal library list [--json]` | List all saved games with API badges, architecture, store source, and prefix name. |
| `DirectMetal library add <exe> [--title <name>]` | Inspect and register a standalone Windows `.exe`. |
| `DirectMetal library set <id\|title> <key=val ...>` | Configure per-game overrides: `perf=balanced\|ultra\|lowlatency`, `engine=auto\|arm64ec\|rosetta`, `dx9=auto\|dxvk\|metalgl`, `upscale=off\|quality\|balanced\|performance`, `retina=true\|false`, `hud=true\|false`, `sandbox=true\|false`, `prefix=<name>`, `args=<string>`. |
| `DirectMetal library artwork <id\|title> [--style banner\|icon]` | Inspect resolved storefront artwork or embedded PE `.exe` icon provenance and dimensions. |
| `DirectMetal library play <id\|title> [--warm-server]` | Launch a library title using its saved settings (`--warm-server` uses the persistent `wineserver` pool for `70–100 ms` repeat launches). |
| `DirectMetal library remove <id\|title>` | Hide and remove a title from the library without deleting game files. |
| `DirectMetal profiles list [--json]` | List all built-in + user-overlay community game profiles (`runtime/profiles/game_profiles.json`). |
| `DirectMetal profiles match <exe>` | Show which community profile matches a given executable. |

---

## Direct Execution & Inspection

| Command | Description |
| :--- | :--- |
| `DirectMetal inspect <exe>` | Parse Windows PE32/PE32+ headers, imported & delay-loaded DLLs, graphics APIs (`D3D12`, `D3D11`, `D3D10`, `D3D9`, `Vulkan`, `OpenGL`), upscalers (`DLSS`, `FSR`, `XeSS`), and deterministic `buildHash`. |
| `DirectMetal run <exe> [options] [-- game args]` | Execute any Windows `.exe` directly. Options: `--prefix <name>`, `--engine auto\|arm64ec\|rosetta`, `--perf-mode balanced\|ultra\|lowlatency`, `--dx9-backend auto\|dxvk\|metalgl`, `--upscale quality\|balanced\|performance`, `--retina` / `--no-retina`, `--hud` / `--no-hud`, `--sandbox`, `--warm-server`, `--reset-prefix`. |
| `DirectMetal prefixes` | List all APFS Copy-on-Write prefixes managed by DirectMetal. |
| `DirectMetal server status\|stop` | Inspect or gracefully stop the background warm `wineserver` pool. |

---

## Runtime, Self-Updater & Cloud Shader Cache

| Command | Description |
| :--- | :--- |
| `DirectMetal runtime status [--json]` | Report whether `MetalSharp-Wine` is installed, its version, bundle path, and `codesign` status. |
| `DirectMetal runtime install [--url <zip>] [--sha256 <hex>]` | Download, streaming SHA-256 verify, and `codesign`-check the ARM64EC runtime for `DirectMetal-Lite.app`. |
| `DirectMetal runtime update` | Check and install newer `MetalSharp-Wine` releases with `SHA256SUMS` verification. |
| `DirectMetal update check [--json]` | Check GitHub Releases for newer DirectMetal app and `MetalSharp-Wine` versions. |
| `DirectMetal update apply [--url <dmg>] [--sha256 <hex>] [--target-app <path>]` | Download, SHA-256 verify, `codesign --verify --deep --strict` check, and atomically swap the installed `.app` bundle. |
| `DirectMetal cache status` | Report local shader cache directory, title count, file count, and disk usage. |
| `DirectMetal cache list [--json]` | List each local shader cache entry with size, file count, and whether it matches the current Apple Silicon GPU / macOS build. |
| `DirectMetal cache prune [--dry-run] [--json]` | Reclaim disk space by removing stale shader caches built for older macOS builds or other GPU families (preserves current-host and unkeyed caches). |
| `DirectMetal cache export <out.tar.gz> [--entry <filter>]` | Export local Metal binary shader archives with a parallel-hashed SHA-256 `manifest.json`. |
| `DirectMetal cache import <path\|url> [--force]` | Import and SHA-256 verify a shader cache archive (`--force` overrides GPU/macOS build checks). |
| `DirectMetal cache sync <index.json\|url> --exe <exe> [--force]` | Fetch a Cloud Shader Cache index, select the exact `gpuFamily`/`macosBuild` match, double-SHA-256 verify, and install. |

---

## Controller Remapping & Hardware Attestation

| Command | Description |
| :--- | :--- |
| `DirectMetal controller list` | List connected `GCController` gamepads and saved remapping profiles. |
| `DirectMetal controller show [profile] [--json]` | Print active remappings, deadzones, haptics, and generated `SDL_GAMECONTROLLERCONFIG`. |
| `DirectMetal controller set <profile> <key=val ...>` | Configure presets (`xbox`, `playstation`, `nintendoSwap`, `bumperTriggerSwap`, `southpaw`), `left-deadzone=0..35`, `right-deadzone=0..35`, `haptics=true\|false`, or individual button swaps. |
| `DirectMetal controller reset <profile>` | Reset a controller profile to defaults. |
| `DirectMetal attest [--pid <pid>] [--nonce <hex>] [--sandbox]` | Emit a Secure Enclave ECDSA P-256 signed hardware attestation report (SIP, SSV, hardware model, GPU, sandbox state). |
| `DirectMetal verify-attest <report.json> [--nonce <hex>]` | Cryptographically verify an attestation report's ECDSA P-256 signature and challenge nonce. |

---

## Environment Variables

| Variable | Effect |
| :--- | :--- |
| `DIRECTMETAL_RUNTIME_ROOT` | Override the path to `MetalSharp-Wine.app` / runtime resources. |
| `DIRECTMETAL_PREFIX_ROOT` | Override the root directory for APFS CoW prefixes (`~/Library/Application Support/DirectMetal/Prefixes`). |
| `DIRECTMETAL_SHADER_CACHE_ROOT` | Override the Metal shader cache directory (`~/Library/Caches/DirectMetal/Shaders`). |
| `DIRECTMETAL_LIBRARY_DIR` | Override the library & config directory (`~/Library/Application Support/DirectMetal`). |
| `DIRECTMETAL_DISABLE_PE_CACHE=1` | Bypass the disk-backed `PEInspector` stat-validated cache. |
| `DIRECTMETAL_UPDATE_URL` | Override the GitHub Releases JSON endpoint used by `update check` / `update apply`. |
