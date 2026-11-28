#!/usr/bin/env python3
"""Strict schema, enum, uniqueness, and hygiene validator for runtime/profiles/game_profiles.json."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

VALID_PERF = {"balanced", "ultra"}
VALID_DX9 = {"auto", "wined3d", "dxvk"}
VALID_UPSCALE = {"off", "quality", "balanced", "performance", "ultra_performance"}
VALID_STATUS = {"playable", "needs-steam-login", "preset"}
VALID_STORES = {"steam", "gog", "epic"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
GENERIC_EXES = {
    "launcher.exe",
    "start_protected_game.exe",
    "unins000.exe",
    "setup.exe",
    "steam.exe",
    "dxsetup.exe",
    "vcredist_x64.exe",
}


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"{path}: invalid JSON: {exc}"]

    if not isinstance(raw, dict):
        return [f"{path}: root must be a JSON object"]

    if raw.get("schema") != "directmetal.game_profiles.v1":
        errors.append(f"unexpected schema: {raw.get('schema')!r}")

    profiles = raw.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        errors.append("profiles must be a non-empty list")
        return errors

    seen_ids: set[str] = set()
    seen_steam: dict[str, str] = {}
    seen_gog: dict[str, str] = {}
    seen_epic: dict[str, str] = {}

    for idx, p in enumerate(profiles):
        ctx = f"profiles[{idx}]"
        if not isinstance(p, dict):
            errors.append(f"{ctx}: must be an object")
            continue

        pid = p.get("id")
        if not isinstance(pid, str) or not ID_RE.match(pid):
            errors.append(f"{ctx}: invalid id {pid!r} (expected lowercase a-z, 0-9, '-')")
            continue
        ctx = f"profile '{pid}'"
        if pid in seen_ids:
            errors.append(f"{ctx}: duplicate id")
        seen_ids.add(pid)

        title = p.get("title")
        if not isinstance(title, str) or not title.strip():
            errors.append(f"{ctx}: missing non-empty title")

        match_titles = p.get("matchTitles", [])
        match_exes = p.get("matchExeNames", [])
        steam_ids = p.get("steamAppIds", [])
        gog_ids = p.get("gogGameIds", [])
        epic_names = p.get("epicAppNames", [])

        for field_name, val in (
            ("matchTitles", match_titles),
            ("matchExeNames", match_exes),
            ("steamAppIds", steam_ids),
            ("gogGameIds", gog_ids),
            ("epicAppNames", epic_names),
        ):
            if not isinstance(val, list) or not all(isinstance(x, str) and x.strip() for x in val):
                errors.append(f"{ctx}: {field_name} must be a list of non-empty strings")

        if not (match_titles or match_exes or steam_ids or gog_ids or epic_names):
            errors.append(f"{ctx}: must define at least one matcher (title, exe, steam/gog/epic id)")

        for exe in match_exes if isinstance(match_exes, list) else []:
            if exe.lower() in GENERIC_EXES:
                errors.append(f"{ctx}: generic executable {exe!r} must not be used in matchExeNames")
            if not exe.lower().endswith(".exe"):
                errors.append(f"{ctx}: matchExeNames entry {exe!r} should end with .exe")

        for sid in steam_ids if isinstance(steam_ids, list) else []:
            if not sid.isdigit():
                errors.append(f"{ctx}: steamAppIds entry {sid!r} must be numeric")
            if sid in seen_steam:
                errors.append(f"{ctx}: duplicate steamAppId {sid!r} (already used by {seen_steam[sid]!r})")
            seen_steam[sid] = pid

        for gid in gog_ids if isinstance(gog_ids, list) else []:
            if not gid.isdigit():
                errors.append(f"{ctx}: gogGameIds entry {gid!r} must be numeric")
            if gid in seen_gog:
                errors.append(f"{ctx}: duplicate gogGameId {gid!r} (already used by {seen_gog[gid]!r})")
            seen_gog[gid] = pid

        for ename in epic_names if isinstance(epic_names, list) else []:
            key = ename.lower()
            if key in seen_epic:
                errors.append(f"{ctx}: duplicate epicAppName {ename!r} (already used by {seen_epic[key]!r})")
            seen_epic[key] = pid

        if p.get("perfProfile") not in VALID_PERF:
            errors.append(f"{ctx}: invalid perfProfile {p.get('perfProfile')!r}")
        if p.get("dx9Backend") not in VALID_DX9:
            errors.append(f"{ctx}: invalid dx9Backend {p.get('dx9Backend')!r}")
        if p.get("upscaleMode") not in VALID_UPSCALE:
            errors.append(f"{ctx}: invalid upscaleMode {p.get('upscaleMode')!r}")
        if p.get("status") not in VALID_STATUS:
            errors.append(f"{ctx}: invalid status {p.get('status')!r}")

        for bfield in ("retinaMode", "enableHUD", "enableSandbox"):
            if not isinstance(p.get(bfield), bool):
                errors.append(f"{ctx}: {bfield} must be a boolean")

        stores = p.get("stores")
        if stores is not None:
            if not isinstance(stores, list) or not all(s in VALID_STORES for s in stores):
                errors.append(f"{ctx}: invalid stores {stores!r}")

        verified_on = p.get("verifiedOn")
        if not isinstance(verified_on, list) or not verified_on or not all(isinstance(v, str) and v.strip() for v in verified_on):
            errors.append(f"{ctx}: verifiedOn must be a non-empty list of strings")
        elif p.get("status") == "preset" and verified_on != ["preset"]:
            errors.append(f"{ctx}: untested preset must use verifiedOn=[\"preset\"]")
        elif p.get("status") != "preset" and verified_on == ["preset"]:
            errors.append(f"{ctx}: status={p.get('status')!r} must specify tested hardware/OS in verifiedOn")

        notes = p.get("notes")
        if not isinstance(notes, str) or len(notes.strip()) < 10:
            errors.append(f"{ctx}: notes must be a descriptive string (>= 10 chars)")

    return errors


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else repo_root / "runtime/profiles/game_profiles.json"
    errors = validate(target)
    if errors:
        for err in errors:
            print(f"[validate_profiles] ERROR: {err}", file=sys.stderr)
        return 1
    data = json.loads(target.read_text(encoding="utf-8"))
    profiles = data["profiles"]
    tested = sum(1 for p in profiles if p.get("status") != "preset")
    print(f"[validate_profiles] OK: {len(profiles)} profiles valid ({tested} hardware-verified, {len(profiles) - tested} community presets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
