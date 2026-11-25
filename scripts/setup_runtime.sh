#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.directmetal_cache"
RUNTIME_DIR="${REPO_ROOT}/build/runtime"

WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-devel-11.21-osx64.tar.xz"
WINE_TARBALL="${CACHE_DIR}/wine-devel-11.21-osx64.tar.xz"

MULLION_URL="https://github.com/dttdrv/mullion/releases/download/v0.5-alpha.4/mullion-v0.5-alpha.4.tar.gz"
MULLION_TARBALL="${CACHE_DIR}/mullion-v0.5-alpha.4.tar.gz"

DXVK_URL="https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507/dxvk-macOS-async-v1.10.3-20230507.tar.gz"
DXVK_TARBALL="${CACHE_DIR}/dxvk-macOS-async-v1.10.3-20230507.tar.gz"

mkdir -p "${CACHE_DIR}" "${RUNTIME_DIR}"

download_if_missing() {
  local url="$1"
  local dst="$2"
  if [[ -s "${dst}" ]]; then
    echo "[DirectMetal] Using cached $(basename "${dst}")"
  else
    echo "[DirectMetal] Downloading ${url}..."
    curl -fL --retry 3 -o "${dst}.tmp" "${url}"
    mv "${dst}.tmp" "${dst}"
  fi
}

download_if_missing "${WINE_URL}" "${WINE_TARBALL}"
download_if_missing "${MULLION_URL}" "${MULLION_TARBALL}"
download_if_missing "${DXVK_URL}" "${DXVK_TARBALL}"

WINE_EXTRACT="${RUNTIME_DIR}/wine-dist"
if [[ ! -d "${WINE_EXTRACT}" ]]; then
  echo "[DirectMetal] Extracting Wine 11.21..."
  mkdir -p "${WINE_EXTRACT}"
  tar -xf "${WINE_TARBALL}" -C "${WINE_EXTRACT}"
fi

# Locate the directory containing bin/wine and lib/wine
WINE_BIN_PATH="$(find "${WINE_EXTRACT}" -maxdepth 6 -type f -name wine -path "*/bin/wine" | head -n 1 || true)"
if [[ -z "${WINE_BIN_PATH}" ]]; then
  echo "ERROR: Could not locate bin/wine inside ${WINE_EXTRACT}" >&2
  exit 1
fi
WINE_ROOT="$(cd "$(dirname "${WINE_BIN_PATH}")/.." && pwd)"
ln -sfn "${WINE_ROOT}" "${RUNTIME_DIR}/wine"
echo "[DirectMetal] Wine root: ${WINE_ROOT} -> ${RUNTIME_DIR}/wine"

MULLION_EXTRACT="${RUNTIME_DIR}/mullion-dist"
if [[ ! -d "${MULLION_EXTRACT}" ]]; then
  echo "[DirectMetal] Extracting Mullion v0.5-alpha.4..."
  mkdir -p "${MULLION_EXTRACT}"
  tar -xzf "${MULLION_TARBALL}" -C "${MULLION_EXTRACT}"
fi

MULLION_INSTALL_SH="$(find "${MULLION_EXTRACT}" -maxdepth 3 -type f -name install.sh | head -n 1 || true)"
if [[ -z "${MULLION_INSTALL_SH}" ]]; then
  echo "ERROR: Could not locate install.sh inside ${MULLION_EXTRACT}" >&2
  exit 1
fi
MULLION_ROOT="$(cd "$(dirname "${MULLION_INSTALL_SH}")" && pwd)"
ln -sfn "${MULLION_ROOT}" "${RUNTIME_DIR}/mullion"
echo "[DirectMetal] Mullion root: ${MULLION_ROOT} -> ${RUNTIME_DIR}/mullion"

echo "[DirectMetal] Stripping macOS quarantine & ad-hoc signing native runtime libraries..."
xattr -dr com.apple.quarantine "${RUNTIME_DIR}" 2>/dev/null || true
find "${MULLION_ROOT}" -type f \( -name "*.so" -o -name "*.dylib" \) -exec codesign --force --sign - {} \;

echo "[DirectMetal] Installing Mullion into Wine..."
chmod +x "${MULLION_ROOT}/install.sh"
"${MULLION_ROOT}/install.sh" "${WINE_ROOT}"

find "${WINE_ROOT}/lib/wine" -maxdepth 2 -type f \( -name "winemetal.so" -o -name "*.dylib" \) -exec codesign --force --sign - {} \; 2>/dev/null || true

BASE_PREFIX="${RUNTIME_DIR}/base-prefix"
if [[ ! -f "${BASE_PREFIX}/system.reg" ]]; then
  echo "[DirectMetal] Initializing golden base Wine prefix at ${BASE_PREFIX}..."
  rm -rf "${BASE_PREFIX}"
  mkdir -p "${BASE_PREFIX}"
  WINEPREFIX="${BASE_PREFIX}" \
  WINEDEBUG=-all \
  WINEDLLOVERRIDES="mscoree,mshtml=" \
  "${WINE_ROOT}/bin/wineboot" --init
  "${WINE_ROOT}/bin/wineserver" -w || true
fi

echo "[DirectMetal] Installing Mullion DLLs into golden base prefix..."
"${MULLION_ROOT}/install.sh" "${WINE_ROOT}" "${BASE_PREFIX}"

DXVK_EXTRACT="${RUNTIME_DIR}/dxvk-dist"
if [[ ! -d "${DXVK_EXTRACT}" ]]; then
  echo "[DirectMetal] Extracting DXVK-macOS async (D3D9 -> Vulkan -> MoltenVK -> Metal)..."
  mkdir -p "${DXVK_EXTRACT}"
  tar -xzf "${DXVK_TARBALL}" -C "${DXVK_EXTRACT}"
fi
DXVK_X32_D3D9="$(find "${DXVK_EXTRACT}" -type f -path "*/x32/d3d9.dll" | head -n 1 || true)"
DXVK_X64_D3D9="$(find "${DXVK_EXTRACT}" -type f -path "*/x64/d3d9.dll" | head -n 1 || true)"
if [[ -n "${DXVK_X32_D3D9}" ]]; then
  mkdir -p "${BASE_PREFIX}/drive_c/windows/syswow64"
  cp -f "${DXVK_X32_D3D9}" "${BASE_PREFIX}/drive_c/windows/syswow64/d3d9.dll"
  echo "[DirectMetal] Installed 32-bit DXVK d3d9.dll -> syswow64/d3d9.dll"
fi
if [[ -n "${DXVK_X64_D3D9}" ]]; then
  cp -f "${DXVK_X64_D3D9}" "${BASE_PREFIX}/drive_c/windows/system32/d3d9.dll"
  echo "[DirectMetal] Installed 64-bit DXVK d3d9.dll -> system32/d3d9.dll"
fi

echo "[DirectMetal] Verifying Wine + Mullion installation..."
"${WINE_ROOT}/bin/wine" --version
for dll in d3d11.dll d3d12.dll dxgi.dll d3d10.dll d3d10core.dll; do
  if [[ ! -f "${BASE_PREFIX}/drive_c/windows/system32/${dll}" ]]; then
    echo "ERROR: Missing ${dll} in ${BASE_PREFIX}/drive_c/windows/system32/" >&2
    exit 1
  fi
done
WINEMETAL_SO="$(find "${WINE_ROOT}/lib/wine" -maxdepth 2 -name winemetal.so | head -n 1 || true)"
if [[ -z "${WINEMETAL_SO}" ]]; then
  echo "ERROR: Missing winemetal.so in ${WINE_ROOT}/lib/wine" >&2
  exit 1
fi
echo "[DirectMetal] Verified winemetal.so: ${WINEMETAL_SO}"
echo "[DirectMetal] Runtime setup complete."
