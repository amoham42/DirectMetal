#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.directmetal_cache"
RUNTIME_DIR="${REPO_ROOT}/build/runtime-arm64ec"

VERSION="10.5"
URL="https://github.com/metalsharp/MetalSharp-Wine/releases/download/v${VERSION}/MetalSharp-Wine-${VERSION}-arm64.zip"
ARCHIVE="${CACHE_DIR}/MetalSharp-Wine-${VERSION}-arm64.zip"

mkdir -p "${CACHE_DIR}" "${RUNTIME_DIR}"

if [[ -s "${ARCHIVE}" ]]; then
  echo "[DirectMetal] Using cached $(basename "${ARCHIVE}")"
else
  echo "[DirectMetal] Downloading MetalSharp-Wine ${VERSION} ARM64EC+FEX notarized app (~1.33 GB)..."
  curl -fL --retry 3 -o "${ARCHIVE}.tmp" "${URL}"
  mv "${ARCHIVE}.tmp" "${ARCHIVE}"
fi

WINE_EXTRACT="${RUNTIME_DIR}/wine-dist"
APP_DIR="${WINE_EXTRACT}/MetalSharp-Wine.app"
if [[ ! -d "${APP_DIR}" ]]; then
  echo "[DirectMetal] Extracting MetalSharp-Wine-${VERSION}-arm64.zip (preserving Developer ID signature & cross-architecture entitlement)..."
  rm -rf "${WINE_EXTRACT}"
  mkdir -p "${WINE_EXTRACT}"
  ditto -x -k "${ARCHIVE}" "${WINE_EXTRACT}"
fi

WINE_BIN="${APP_DIR}/Contents/MacOS/wine"
if [[ ! -x "${WINE_BIN}" ]]; then
  echo "ERROR: Could not locate native wine executable at ${WINE_BIN}" >&2
  exit 1
fi

echo "[DirectMetal] Verifying native ARM64 Mach-O architecture & Apple Developer ID signature:"
file "${WINE_BIN}"
if ! file "${WINE_BIN}" | grep -q "arm64"; then
  echo "ERROR: Expected arm64 executable for ${WINE_BIN}" >&2
  exit 1
fi
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true
codesign --verify --strict --deep "${APP_DIR}" && echo "[DirectMetal] Signature & provisioning profile verified intact!"

# Symlink bin/ cleanly as relative link to MetalSharp-Wine.app/Contents/MacOS
rm -rf "${RUNTIME_DIR}/bin"
ln -sfn "wine-dist/MetalSharp-Wine.app/Contents/MacOS" "${RUNTIME_DIR}/bin"

BASE_PREFIX="${RUNTIME_DIR}/base-prefix"
if [[ ! -f "${BASE_PREFIX}/system.reg" ]]; then
  echo "[DirectMetal] Initializing ARM64EC v${VERSION} golden base prefix at ${BASE_PREFIX}..."
  rm -rf "${BASE_PREFIX}"
  mkdir -p "${BASE_PREFIX}"
  WINEPREFIX="${BASE_PREFIX}" \
  WINEDEBUG=-all \
  WINEDLLOVERRIDES="mscoree,mshtml=" \
  "${WINE_BIN}" wineboot -u -r
  "${APP_DIR}/Contents/MacOS/wineserver" -w || true
fi

echo "[DirectMetal] Wine version:"
"${WINE_BIN}" --version
echo "[DirectMetal] ARM64EC + FEX-Emu v${VERSION} runtime ready at ${RUNTIME_DIR}"
