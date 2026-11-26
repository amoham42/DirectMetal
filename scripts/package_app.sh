#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SRC="${REPO_ROOT}/app/DirectMetalApp"
RUNTIME_SRC="${REPO_ROOT}/build/runtime"
APP_BUNDLE="${REPO_ROOT}/dist/DirectMetal.app"
CONTENTS="${APP_BUNDLE}/Contents"

if [[ ! -d "${RUNTIME_SRC}/wine" || ! -d "${RUNTIME_SRC}/base-prefix" ]]; then
  echo "[DirectMetal] Runtime missing; running scripts/setup_runtime.sh..."
  "${REPO_ROOT}/scripts/setup_runtime.sh"
fi

echo "[DirectMetal] Compiling DirectMetal.app (arm64 Swift)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${CONTENTS}/Runtime"

xcrun swiftc \
  -O \
  -target arm64-apple-macos15.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Metal \
  -framework MetalFX \
  -framework CryptoKit \
  -framework Security \
  -framework DeviceCheck \
  -o "${CONTENTS}/MacOS/DirectMetal" \
  "${APP_SRC}/PEInspector.swift" \
  "${APP_SRC}/PrefixManager.swift" \
  "${APP_SRC}/SandboxAttestation.swift" \
  "${APP_SRC}/ShaderCacheManager.swift" \
  "${APP_SRC}/RuntimeLauncher.swift" \
  "${APP_SRC}/DirectMetalGUI.swift" \
  "${APP_SRC}/main.swift"

cp "${APP_SRC}/Info.plist" "${CONTENTS}/Info.plist"
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Resources/mullion.conf"
cp "${REPO_ROOT}/sandbox/profiles/directmetal_game.sb.tmpl" "${CONTENTS}/Resources/directmetal_game.sb.tmpl"

echo "[DirectMetal] Building & bundling universal Vulkan compat layer (VK_LAYER_DIRECTMETAL_mvk_compat)..."
mkdir -p "${CONTENTS}/Resources/vulkan-layers" "${REPO_ROOT}/build/dm_vk_compat"
xcrun clang -O2 -arch arm64 -arch x86_64 -dynamiclib -fvisibility=hidden \
  "${REPO_ROOT}/graphics/dm_vk_compat/dm_vk_compat_layer.c" \
  -o "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
cp "${REPO_ROOT}/graphics/dm_vk_compat/VK_LAYER_DIRECTMETAL_mvk_compat.json" "${REPO_ROOT}/build/dm_vk_compat/"
codesign --force --sign - "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
cp "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib" "${CONTENTS}/Resources/vulkan-layers/"
cp "${REPO_ROOT}/build/dm_vk_compat/VK_LAYER_DIRECTMETAL_mvk_compat.json" "${CONTENTS}/Resources/vulkan-layers/"

echo "[DirectMetal] Cloning self-contained Wine + Mullion runtime via APFS CoW..."
cp -Rc "${RUNTIME_SRC}/wine-dist" "${CONTENTS}/Runtime/wine-dist"
cp -Rc "${RUNTIME_SRC}/mullion-dist" "${CONTENTS}/Runtime/mullion-dist"
cp -Rc "${RUNTIME_SRC}/base-prefix" "${CONTENTS}/Runtime/base-prefix"
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Runtime/mullion.conf"

# Strip unused build/dev/legacy bloat from bundled Rosetta runtime copy (non-destructive to build/)
WINE_REL="$(cd "${CONTENTS}/Runtime" && find wine-dist -maxdepth 6 -type f -name wine -path "*/bin/wine" | head -n 1 | sed 's|/bin/wine$||')"
MULLION_REL="$(cd "${CONTENTS}/Runtime" && find mullion-dist -maxdepth 3 -type f -name install.sh | head -n 1 | sed 's|/install.sh$||')"
ln -sfn "${WINE_REL}" "${CONTENTS}/Runtime/wine"
ln -sfn "${MULLION_REL}" "${CONTENTS}/Runtime/mullion"
rm -rf "${CONTENTS}/Runtime/${WINE_REL}/include" \
       "${CONTENTS}/Runtime/${WINE_REL}/share/man" \
       "${CONTENTS}/Runtime/${WINE_REL}/share/doc" \
       "${CONTENTS}/Runtime/${WINE_REL}/share/wine/gecko" \
       "${CONTENTS}/Runtime/${WINE_REL}/share/wine/mono" 2>/dev/null || true
find "${CONTENTS}/Runtime/${WINE_REL}/lib/wine" -type f -name "*.a" -delete 2>/dev/null || true

ARM64EC_SRC="${REPO_ROOT}/build/runtime-arm64ec"
if [[ -d "${ARM64EC_SRC}/base-prefix" ]]; then
  echo "[DirectMetal] Cloning self-contained ARM64EC + FEX-Emu runtime via APFS CoW..."
  cp -Rc "${ARM64EC_SRC}" "${CONTENTS}/Runtime-ARM64EC"
  # Keep native ARM64X DXVK 3.1.1 (loaded via GRAPHICS_BACKEND=dxvk) instead of overwriting system32/d3d9.dll with x86_64 DXVK 1.10.3
  # Strip unused archives/installers/headers/VR/legacy translators from bundled ARM64EC copy
  MSW_BUNDLE_ROOT="$(find "${CONTENTS}/Runtime-ARM64EC/wine-dist" -maxdepth 2 -type d -name "metalsharp-wine-*" | head -n 1 || true)"
  if [[ -n "${MSW_BUNDLE_ROOT}" ]]; then
    echo "[DirectMetal] Stripping unused bloat from bundled ARM64EC runtime..."
    rm -rf "${MSW_BUNDLE_ROOT}/include" \
           "${MSW_BUNDLE_ROOT}/share/man" \
           "${MSW_BUNDLE_ROOT}/share/doc" \
           "${MSW_BUNDLE_ROOT}/share/wine/mono" \
           "${MSW_BUNDLE_ROOT}/share/wine/gecko" \
           "${MSW_BUNDLE_ROOT}/share/metalsharp/archives" \
           "${MSW_BUNDLE_ROOT}/share/metalsharp/assets" \
           "${MSW_BUNDLE_ROOT}/share/metalsharp/redist" \
           "${MSW_BUNDLE_ROOT}/lib/vkd3d-proton" \
           "${MSW_BUNDLE_ROOT}/lib/zink" \
           "${MSW_BUNDLE_ROOT}/lib/metalvr" \
           "${MSW_BUNDLE_ROOT}/bin/metalvrd" 2>/dev/null || true
    find "${MSW_BUNDLE_ROOT}/lib/wine" -type f -name "*.a" -delete 2>/dev/null || true
    # Disable FEX ProfileStats in bundled Config.json (avoids per-frame profiling CPU overhead)
    if [[ -f "${MSW_BUNDLE_ROOT}/share/fex-emu/Config.json" ]]; then
      sed -i '' 's/"ProfileStats":[[:space:]]*"1"/"ProfileStats": "0"/g' "${MSW_BUNDLE_ROOT}/share/fex-emu/Config.json"
    fi
  fi
fi

echo "[DirectMetal] Applying Hardened Runtime (--options runtime) + entitlements..."
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true
codesign --force --options runtime --sign - --entitlements "${REPO_ROOT}/sandbox/DirectMetal.entitlements" "${APP_BUNDLE}"

echo "[DirectMetal] Packaged ${APP_BUNDLE} ($(du -sh "${APP_BUNDLE}" | awk '{print $1}'))"
"${CONTENTS}/MacOS/DirectMetal" info
