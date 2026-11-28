# Community Game Profiles Guide

DirectMetal ships with **100 built-in game profiles** in [`runtime/profiles/game_profiles.json`](../runtime/profiles/game_profiles.json). When a game is discovered by `DirectMetal library scan` or added for the first time, the first matching profile automatically seeds optimal per-game settings (`perfProfile`, `dx9Backend`, `upscaleMode`, `retinaMode`, `enableHUD`, `enableSandbox`) without ever overwriting existing user customizations.

---

## 1. Local User Overrides (No Rebuild Needed)

Create or edit `~/Library/Application Support/DirectMetal/game_profiles.json` using the exact same schema (`directmetal.game_profiles.v1`). Any profile with the same `id` overrides the bundled profile, and new `id`s are appended cleanly.

You can also point to an alternate file for testing:

```bash
DIRECTMETAL_GAME_PROFILES=/path/to/custom_profiles.json DirectMetal profiles list
```

---

## 2. Profile Schema

```json
{
  "id": "my-game-slug",
  "title": "My Game Title",
  "matchTitles": ["My Game Title", "My Game"],
  "matchExeNames": ["MyGame-Win64-Shipping.exe"],
  "steamAppIds": ["123456"],
  "gogGameIds": [],
  "epicAppNames": [],
  "stores": ["steam"],
  "gameEngine": "Unreal Engine 5",
  "perfProfile": "ultra",
  "dx9Backend": "auto",
  "upscaleMode": "quality",
  "retinaMode": true,
  "enableHUD": false,
  "enableSandbox": true,
  "status": "preset",
  "notes": "Short, factual note shown in the launcher UI.",
  "verifiedOn": ["preset"]
}
```

### Matching Priority
1. Exact **Steam App ID** (`steamAppIds`), **GOG Game ID** (`gogGameIds`), or **Epic `AppName`** (`epicAppNames`).
2. Case-insensitive **executable filename** (`matchExeNames`) — never use generic launcher names like `launcher.exe`, `setup.exe`, or `start_protected_game.exe`.
3. Punctuation- and case-normalized **title match** (`matchTitles`).

### Honesty Rules for `status` & `verifiedOn`
- Use `"status": "preset"` and `"verifiedOn": ["preset"]` for untested starter templates.
- Only set `"status": "playable"` and record real hardware/OS strings (e.g., `["M4 (macOS 26.7.1)"]`) when you actually launched and verified the game on Apple Silicon.

---

## 3. Validating Before Opening a PR

Run the schema & hygiene validator (also enforced automatically in GitHub Actions CI):

```bash
python3 scripts/validate_profiles.py
```

It checks:
- Valid JSON & `directmetal.game_profiles.v1` schema header
- Unique `id`, `steamAppIds`, `gogGameIds`, and `epicAppNames` across all profiles
- Valid enums for `perfProfile`, `dx9Backend`, `upscaleMode`, `status`, and `stores`
- No banned generic executable names in `matchExeNames`
- At least one matcher per profile
