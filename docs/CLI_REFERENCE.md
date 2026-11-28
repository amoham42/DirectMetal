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
| `DirectMetal bench [--json\|--markdown]` | Run built-in Apple Silicon microbenchmarks (Metal UMA shared-memory compute bandwidth, APFS CoW `clonefile` latency, ARMv8 hardware SHA-256 throughput, and cached PE32+ inspection latency) and emit a shareable scorecard. |
| `DirectMetal history [--limit N] [--json\|--markdown] [--clear]` | Inspect, export, or clear persistent structured game launch history (`launch_history.jsonl`, auto-capped at 200 entries). |
| `DirectMetal history stats [--json\|--markdown]` | Aggregate per-game stability tiers (`Rock Solid`, `Mostly Stable`, `Needs Attention`), ARM64EC/Rosetta mix, and median APFS CoW clone speed from launch history. |
| `DirectMetal diagnose-log <logfile> [--json\|--markdown]` | Single-pass crash & error triage on a Wine/Mullion/DXMT/DXVK/Seatbelt log (detects anti-cheat, missing DLLs, Seatbelt EPERM, GPU OOM, D3D12 alignment, shader compile errors & suggests fixes). |
| `DirectMetal support-bundle [out.tar.gz] [--json]` | Export a privacy-redacted `.tar.gz` diagnostics bundle (`hardware.json`, redacted library summary, launch history, prefix/cache stats, `SUMMARY.md`) safe to attach to GitHub issues. |
| `DirectMetal storage [--json\|--markdown]` | Symlink-safe disk footprint audit across Wine prefixes, shader caches, `_quarantine`, save backups, user runtimes, and metadata with prioritized space-reclamation commands. |
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
| `DirectMetal library set <id\|title> <key=val ...>` | Configure per-game overrides: `perf=balanced\|ultra`, `engine=auto\|arm64ec\|rosetta`, `dx9=auto\|dxvk\|wined3d`, `upscale=off\|quality\|balanced\|performance`, `fps-cap=0\|30\|40\|60\|90\|120\|144`, `retina=true\|false`, `hud=true\|false`, `sandbox=true\|false`, `favorite=true\|false`, `prefix=<name>`, `args=<string>`, `env=<KEY=VAL ...>`. |
| `DirectMetal library diff <id\|title> [--json]` | Compare a game's current settings against its matched community profile (or DirectMetal defaults). |
| `DirectMetal library reset-settings <id\|title> [--json]` | Restore a game's launch settings back to its community preset or defaults while keeping playtime, favorites, and prefix intact. |
| `DirectMetal library sync-profiles [--dry-run] [--overwrite] [--json\|--markdown]` | Batch-apply newly matched community profiles across your library while protecting customized games (unless `--overwrite` is passed). |
| `DirectMetal library artwork <id\|title> [--style banner\|icon]` | Inspect resolved storefront artwork or embedded PE `.exe` icon provenance and dimensions. |
| `DirectMetal library play <id\|title> [--warm-server]` | Launch a library title using its saved settings (`--warm-server` uses the persistent `wineserver` pool for `70–100 ms` repeat launches). |
| `DirectMetal library explain <id\|title> [--json\|--markdown]` | Dry-run inspect a game's resolved engine, graphics translator, MetalFX upscaling, FPS cap env, prefix, shader cache, sandbox, and sanitized custom env without launching it. |
| `DirectMetal library lint <id\|title> [--json\|--markdown]` | Lint a game's `customEnv` and `extraArgs` for syntax errors, blocked security keys, Linux/Proton no-op vars (`MANGOHUD`, `PROTON_*`, `%command%`), setting conflicts, and secret advisories. |
| `DirectMetal library preflight <id\|title> [--json\|--markdown]` | Run a fast 7-point read-only launch readiness check (executable, runtime, kernel anti-cheat signatures, free disk headroom, prefix, graphics pipeline, custom env). Exits `0` if launchable, `2` if blocked. |
| `DirectMetal library report [--format markdown\|csv] [--sort most-played\|title\|recent\|favorites] [--output <path>] [--json]` | Export a privacy-safe playtime, API & stability report in GitHub-Flavored Markdown or RFC 4180 CSV (omits local file paths and custom env secrets). |
| `DirectMetal library shortcut <id\|title> [--format app\|command] [--dir <path>] [--json]` | Export a standalone macOS `.app` launcher (with game icon for Spotlight/Dock/Launchpad) or executable `.command` script for one-click launching. |
| `DirectMetal library remove <id\|title>` | Hide and remove a title from the library without deleting game files. |
| `DirectMetal library export <backup.json>` | Export all saved game settings and controller remapping profiles to a portable JSON backup. |
| `DirectMetal library import <backup.json> [--overwrite]` | Restore games and controller profiles from a backup (preserves existing entries unless `--overwrite` is passed). |
| `DirectMetal profiles list [--json]` | List all built-in + user-overlay community game profiles (`runtime/profiles/game_profiles.json`). |
| `DirectMetal profiles match <exe>` | Show which community profile matches a given executable. |
| `DirectMetal profiles save <id\|title> [--verified] [--notes <text>] [--json]` | Draft, schema-validate, and save a library game's tuned settings into the local user overlay (`~/Library/Application Support/DirectMetal/game_profiles.json`). |
| `DirectMetal profiles export-pr <id\|title> [--verified] [--notes <text>]` | Emit a schema-validated JSON snippet ready to submit in a PR to `runtime/profiles/game_profiles.json`. |
| `DirectMetal profiles remove <profile_id>` | Remove a custom profile from the local user overlay. |

---

## Direct Execution & Inspection

| Command | Description |
| :--- | :--- |
| `DirectMetal inspect <exe>` | Parse Windows PE32/PE32+ headers, imported & delay-loaded DLLs, graphics APIs (`D3D12`, `D3D11`, `D3D10`, `D3D9`, `Vulkan`, `OpenGL`), upscalers (`DLSS`, `FSR`, `XeSS`), and deterministic `buildHash`. |
| `DirectMetal run <exe> [options] [-- game args]` | Execute any Windows `.exe` directly. Options: `--prefix <name>`, `--engine auto\|arm64ec\|rosetta`, `--perf-mode balanced\|ultra\|lowlatency`, `--dx9-backend auto\|dxvk\|metalgl`, `--upscale quality\|balanced\|performance`, `--retina` / `--no-retina`, `--hud` / `--no-hud`, `--sandbox`, `--warm-server`, `--reset-prefix`. |
| `DirectMetal prefix list` | List all APFS Copy-on-Write prefixes managed by DirectMetal. |
| `DirectMetal prefix stats [--json]` | Inspect per-prefix disk usage, file count, APFS CoW clone time, and associated game executable. |
| `DirectMetal prefix prune [--dry-run] [--json]` | Safely remove orphaned APFS prefixes not referenced by any library game (always preserves `default` and active `wineserver` prefixes). |
| `DirectMetal prefix create\|reset\|delete <name>` | Create, reset from the golden base prefix, or delete a managed APFS prefix. |
| `DirectMetal prefix export-saves <name> <out.tar.gz> [--json]` | Export Windows save data (`Documents`, `Saved Games`, `AppData`) from a prefix into a SHA-256 verified `.tar.gz` archive. |
| `DirectMetal prefix import-saves <name> <backup.tar.gz> [--json]` | SHA-256 verify and atomically restore a save backup archive into a managed prefix (rejects path traversal and symlinks). |
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
| `DirectMetal cache verify [--quarantine\|--repair] [--dry-run] [--json\|--markdown]` | Verify local `.metallib`/`MTLBinaryArchive`, SQLite, DXVK, and JSON shader cache integrity (symlink-safe) and optionally quarantine corrupt artifacts into `_quarantine` without deleting healthy caches. |
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
| `DirectMetal controller set <profile> <key=val ...>` | Configure presets (`xboxStandard`/`xbox`, `playstationDualSense`/`playstation`, `nintendoSwap`, `invertedLookY`, `bumperTriggerSwap`, `custom`), `left-deadzone=0..35`, `right-deadzone=0..35`, `haptics=true\|false`, or individual button swaps. |
| `DirectMetal controller reset <profile>` | Reset a controller profile to defaults. |
| `DirectMetal hud show [--json]` | Show current Metal Performance HUD overlay preset, corner alignment, scale, opacity, and emitted `MTL_HUD_*` variables. |
| `DirectMetal hud set <key=val ...>` | Customize Metal Performance HUD (`preset=minimal\|standard\|frameGraph\|detailed`, `alignment=topLeft\|topRight\|bottomLeft\|bottomRight`, `scale=0.5..2.0`, `opacity=0.25..1.0`, `dxvk-hud=true\|false`). |
| `DirectMetal hud reset` | Reset Metal Performance HUD overlay configuration to defaults. |
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
