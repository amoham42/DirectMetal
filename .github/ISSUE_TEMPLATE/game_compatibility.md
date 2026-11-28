---
name: Game Compatibility Report
about: Share Apple Silicon compatibility telemetry or propose a preset for runtime/profiles/game_profiles.json
title: "[Compat]: <Game Title> (<D3D9/D3D11/D3D12>)"
labels: ["compatibility"]
---

## Game Overview

- **Game Title:**
- **Storefront / Build:** (Steam / GOG / Epic / Standalone)
- **Engine:** (e.g., Unreal Engine 4/5, Unity, Source / Source 2, RE Engine, REDengine, Custom)
- **Compatibility Status:**
  - [ ] **Playable** — Boots cleanly, accurate rendering, smooth frame pacing (60–120+ FPS)
  - [ ] **In-Game (Minor Issues)** — Playable with minor visual, audio, or UI quirks
  - [ ] **Menus / Intro Only** — Launches into menus but hangs or crashes entering gameplay
  - [ ] **Crashes on Launch** — Fails before rendering
  - [ ] **Blocked by Kernel Anti-Cheat / DRM** — Requires Windows Ring-0 `.sys` driver or external launcher session

## PE Inspection (`DirectMetal inspect <game.exe>`)

```json
Paste output of: DirectMetal inspect "/path/to/Game.exe"
```

## Test Hardware & DirectMetal Runtime

- **Mac Model & Unified Memory:** (e.g., Apple M1 Pro 16 GB / Apple M4 16 GB)
- **macOS Version (`sw_vers`):** (e.g., macOS 27.2.1 `26B131` / macOS 26.7.1)
- **Execution Path:** `ARM64EC + FEX-Emu` (`MetalSharp-Wine v10.5`) / `Rosetta 2`
- **Seatbelt `--sandbox` Verified:** Yes / No

## Measured Frame-Time & GPU Telemetry

- **Resolution & Retina PPI:** (e.g., `1512x982` Retina / `1920x1080`)
- **Upscaling Mode:** (`off` / `quality` / `balanced` / `performance` — MetalFX Spatial or Metal 4 MetalFX Temporal)
- **Average FPS / 1%-Low FPS:** (via `--hud` Metal HUD or `tools/dm_fps_probe`)
- **GPU Utilization / Memory:**

## Proposed Community Profile (`runtime/profiles/game_profiles.json`)

If this title benefits from tuned defaults, include a candidate entry for `runtime/profiles/game_profiles.json`:

```json
{
  "matchExecutables": ["Game.exe"],
  "title": "Example Game",
  "engine": "auto",
  "perfProfile": "ultra",
  "dx9Backend": "auto",
  "upscaleMode": "quality",
  "retinaMode": true,
  "enableSandbox": true,
  "extraArgs": "",
  "notes": "Zero-config D3D12 FL 12_2 + MetalFX."
}
```

## Notes & Workarounds

Any additional observations (shader warm-up behavior, controller support via `GameController.framework`, D3D12 placed-resource alignment guard, etc.).
