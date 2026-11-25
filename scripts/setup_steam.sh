#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.directmetal_cache"
DM_BIN="${REPO_ROOT}/dist/DirectMetal.app/Contents/MacOS/DirectMetal"
STEAM_INSTALLER="${CACHE_DIR}/SteamSetup.exe"
PREFIX_NAME="${1:-steam}"

mkdir -p "${CACHE_DIR}"

if [[ ! -s "${STEAM_INSTALLER}" ]]; then
  echo "[DirectMetal] Downloading official SteamSetup.exe..."
  curl -fL --retry 3 -o "${STEAM_INSTALLER}.tmp" "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
  mv "${STEAM_INSTALLER}.tmp" "${STEAM_INSTALLER}"
fi

echo "[DirectMetal] Installing Steam into APFS CoW prefix '${PREFIX_NAME}' (silent /S)..."
"${DM_BIN}" run "${STEAM_INSTALLER}" \
  --prefix "${PREFIX_NAME}" \
  --engine rosetta \
  --desktop off \
  -- /S

STEAM_EXE="${HOME}/Library/Application Support/DirectMetal/Prefixes/${PREFIX_NAME}/drive_c/Program Files (x86)/Steam/steam.exe"
if [[ -f "${STEAM_EXE}" ]]; then
  echo "[DirectMetal] Installed official Windows Steam at: ${STEAM_EXE}"
  echo "[DirectMetal] Launch with:"
  echo "  ${DM_BIN} run \"${STEAM_EXE}\" --prefix ${PREFIX_NAME} --engine rosetta --desktop off -- -nofriendsui -no-cef-sandbox"
else
  echo "ERROR: Steam installation did not produce ${STEAM_EXE}" >&2
  exit 1
fi
