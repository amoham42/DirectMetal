# Troubleshooting DirectMetal

Quick fixes for the most common setup and runtime issues on Apple Silicon Macs.

---

## 1. "DirectMetal-Lite.app is damaged and can't be opened" / Gatekeeper Quarantine

Local and community CI builds are currently ad-hoc Hardened Runtime signed (`--options runtime --sign -`) until Apple Developer ID notarization secrets are configured. Clear the quarantine extended attribute once after dragging the app into `/Applications`:

```bash
xattr -dr com.apple.quarantine "/Applications/DirectMetal-Lite.app"
```

---

## 2. 32-Bit Windows Games on macOS 15.0 – 26.3

Native post-Rosetta 32-bit execution via `com.apple.developer.cross-architecture-support` requires **macOS 26.4 or newer**.

- **On macOS 26.4+ / 27.x:** Both 64-bit and 32-bit games run natively on ARM64EC + FEX automatically.
- **On macOS 15.0 – 26.3:** Build with the legacy Rosetta 2 fallback bundled and pass `--engine rosetta` for 32-bit titles:
  ```bash
  ./scripts/package_app.sh --include-rosetta
  DirectMetal run /path/to/game32.exe --engine rosetta
  ```

---

## 3. Blurry or Tiny UI / Retina Scaling Issues

DirectMetal automatically configures Wine's Mac Driver (`RetinaMode=y`) and Windows DPI (`LogPixels=192` on 2× Retina displays) before every launch.

- To force native Retina pixels (`3024×1964 @ 192 DPI` on 14" MBP): `--retina` (default on Retina displays).
- For legacy games that break at >96 DPI or need lower render resolution: `--no-retina` (or uncheck **Retina PPI** in the GUI).
- For legacy full-screen mode-switch issues: pass `--desktop 1920x1080` (or `off` to disable).

---

## 4. DirectX 9 Video Color Tint or Hang

- **64-bit DX9 games** (e.g., *Team Fortress 2*) default to **DXVK 3.1.1 + Mesa KosmicKrisp**.
- **32-bit DX9 games** (e.g., *Need for Speed: Hot Pursuit*) default to **WineMetalGL 4.6 (`wined3d`)** for accurate YUV video playback and to avoid `d7vk` / `ddraw` hangs.
- Override per game in the GUI (**DX9 Backend**) or CLI:
  ```bash
  DirectMetal library set "Game Name" dx9=wined3d   # or dx9=dxvk
  ```

---

## 5. Steam Games Closing After ~20 Seconds

Titles that call `SteamUser()->GetSteamID()` (e.g., *Team Fortress 2*, *Prince of Persia*) require an active Steam client login inside the game's Wine prefix. Install and sign in to Steam inside the prefix using `./scripts/setup_steam.sh`, or launch the title through Steam inside DirectMetal.

---

## 6. Piped CLI Commands Waiting After Game Exit (`--warm-server`)

When using `--warm-server`, Wine's background services (`services.exe` / `winedevice.exe`) keep inherited stdout pipes open until the warm server timer expires.

- **Interactive terminals and file redirects** (`> run.log 2>&1`) return immediately.
- **Piped commands** (`DirectMetal run … | tee`) should pass `--no-warm-server` or stop servers explicitly via:
  ```bash
  DirectMetal runtime stop-servers
  ```

---

## 7. Shader Cache Sync Reports `compatible: false`

Pre-compiled `MTLBinaryArchive` caches are keyed strictly by `(game_build_hash, apple_gpu_family, macos_build)` (e.g., `apple7_26B131`, `apple9_25G241`). If no matching entry exists for your exact GPU family and macOS build, DirectMetal compiles shaders locally on first launch and caches them automatically in `~/Library/Caches/DirectMetal/Shaders/`.

You can inspect your machine's cache key with:
```bash
DirectMetal info | grep cache_key
```

---

## 8. Filing an Actionable Bug Report

Include the output of these three commands (or click **Copy Report** inside the launcher's Launch Diagnostics drawer):

```bash
DirectMetal info
DirectMetal runtime status --json
DirectMetal inspect /path/to/game.exe
```
