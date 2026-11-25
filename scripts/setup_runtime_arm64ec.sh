#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.directmetal_cache"
RUNTIME_DIR="${REPO_ROOT}/build/runtime-arm64ec"

URL="https://github.com/metalsharp/MetalSharp-Wine/releases/download/v9.0/metalsharp-wine-9.0-arm64.tar.xz"
TARBALL="${CACHE_DIR}/metalsharp-wine-9.0-arm64.tar.xz"

mkdir -p "${CACHE_DIR}" "${RUNTIME_DIR}"

if [[ -s "${TARBALL}" ]]; then
  echo "[DirectMetal] Using cached $(basename "${TARBALL}")"
else
  echo "[DirectMetal] Downloading MetalSharp-Wine 9.0 ARM64EC+FEX (~987 MB)..."
  curl -fL --retry 3 -o "${TARBALL}.tmp" "${URL}"
  mv "${TARBALL}.tmp" "${TARBALL}"
fi

WINE_EXTRACT="${RUNTIME_DIR}/wine-dist"
if [[ ! -d "${WINE_EXTRACT}" ]]; then
  echo "[DirectMetal] Extracting metalsharp-wine-9.0-arm64.tar.xz..."
  mkdir -p "${WINE_EXTRACT}"
  tar -xf "${TARBALL}" -C "${WINE_EXTRACT}"
fi

WINE_BIN="$(find "${WINE_EXTRACT}" -maxdepth 6 -type f -name wine-launcher | head -n 1 || true)"
if [[ -z "${WINE_BIN}" ]]; then
  WINE_BIN="$(find "${WINE_EXTRACT}" -maxdepth 6 -type f -name wine \( -path "*/MacOS/wine" -o -path "*/bin/wine" \) | head -n 1 || true)"
fi
if [[ -z "${WINE_BIN}" ]]; then
  echo "ERROR: Could not locate native wine executable inside ${WINE_EXTRACT}" >&2
  exit 1
fi

echo "[DirectMetal] Verifying native ARM64 Mach-O architecture:"
file "${WINE_BIN}"
if ! file "${WINE_BIN}" | grep -q "arm64"; then
  echo "ERROR: Expected arm64 executable for ${WINE_BIN}" >&2
  exit 1
fi

WINE_ROOT_ABS="$(cd "$(dirname "${WINE_BIN}")/.." && pwd)"
WINE_ROOT_REL="${WINE_ROOT_ABS#"${RUNTIME_DIR}/"}"

# Symlink bin/ and lib/ cleanly as relative links so bin/wine resolves wine-launcher & gstreamer
rm -rf "${RUNTIME_DIR}/bin"
ln -sfn "${WINE_ROOT_REL}/bin" "${RUNTIME_DIR}/bin"

echo "[DirectMetal] Stripping macOS quarantine..."
xattr -dr com.apple.quarantine "${RUNTIME_DIR}" 2>/dev/null || true

WINEMETAL_SO="$(find "${WINE_EXTRACT}" -maxdepth 8 -name "winemetal.so" | head -n 1 || true)"
echo "[DirectMetal] Bundled winemetal.so: ${WINEMETAL_SO:-not found}"
[[ -n "${WINEMETAL_SO}" ]] && file "${WINEMETAL_SO}" || true

BASE_PREFIX="${RUNTIME_DIR}/base-prefix"
if [[ ! -f "${BASE_PREFIX}/system.reg" ]]; then
  echo "[DirectMetal] Initializing ARM64EC golden base prefix at ${BASE_PREFIX}..."
  rm -rf "${BASE_PREFIX}"
  mkdir -p "${BASE_PREFIX}"
  WINEPREFIX="${BASE_PREFIX}" \
  WINEDEBUG=-all \
  WINEDLLOVERRIDES="mscoree,mshtml=" \
  "${RUNTIME_DIR}/bin/wine" wineboot -u -r
  "${RUNTIME_DIR}/bin/wineserver" -w || true
fi

echo "[DirectMetal] Wine version:"
"${RUNTIME_DIR}/bin/wine" --version
echo "[DirectMetal] ARM64EC + FEX-Emu runtime ready at ${RUNTIME_DIR}"
