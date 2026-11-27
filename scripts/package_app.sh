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

D3D12_GUARD_DLL="${REPO_ROOT}/build/dm_d3d12_placed_guard/d3d12_x64.dll"
MINGW_CLANG=""
if [[ -x "${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]]; then
  MINGW_CLANG="${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang"
elif command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
  MINGW_CLANG="$(command -v x86_64-w64-mingw32-clang)"
fi
if [[ -n "${MINGW_CLANG}" && -f "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" ]]; then
  echo "[DirectMetal] Building D3D12 Placed-Resource Alignment Guard (d3d12_x64.dll)..."
  mkdir -p "${REPO_ROOT}/build/dm_d3d12_placed_guard"
  "${MINGW_CLANG}" -O2 -shared \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.def" \
    -o "${D3D12_GUARD_DLL}"
fi

echo "[DirectMetal] Cloning self-contained Wine + Mullion runtime via APFS CoW..."
cp -Rc "${RUNTIME_SRC}/wine-dist" "${CONTENTS}/Runtime/wine-dist"
cp -Rc "${RUNTIME_SRC}/mullion-dist" "${CONTENTS}/Runtime/mullion-dist"
cp -Rc "${RUNTIME_SRC}/base-prefix" "${CONTENTS}/Runtime/base-prefix"
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Runtime/mullion.conf"

if [[ -f "${D3D12_GUARD_DLL}" && -f "${CONTENTS}/Runtime/base-prefix/drive_c/windows/system32/d3d12.dll" ]]; then
  echo "[DirectMetal] Installing D3D12 Alignment Guard into Rosetta base-prefix..."
  cp "${CONTENTS}/Runtime/base-prefix/drive_c/windows/system32/d3d12.dll" \
     "${CONTENTS}/Runtime/base-prefix/drive_c/windows/system32/d3d12_mullion.dll"
  cp "${D3D12_GUARD_DLL}" "${CONTENTS}/Runtime/base-prefix/drive_c/windows/system32/d3d12.dll"
fi

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
  MSW_APP="${CONTENTS}/Runtime-ARM64EC/wine-dist/MetalSharp-Wine.app"
  if [[ -d "${MSW_APP}" ]]; then
    # Keep MetalSharp-Wine.app 100% untouched so its Apple Developer ID signature,
    # notarization, and com.apple.developer.cross-architecture-support entitlement remain valid!
    echo "[DirectMetal] Preserving signed MetalSharp-Wine.app (verifying signature & cross-arch profile)..."
    codesign --verify --strict --deep "${MSW_APP}"
    if [[ -f "${D3D12_GUARD_DLL}" && -f "${MSW_APP}/Contents/lib/mullion/aarch64-windows/d3d12.dll" ]]; then
      echo "[DirectMetal] Installing D3D12 Alignment Guard into ARM64EC base-prefix..."
      cp "${MSW_APP}/Contents/lib/mullion/aarch64-windows/d3d12.dll" \
         "${CONTENTS}/Runtime-ARM64EC/base-prefix/drive_c/windows/system32/d3d12_mullion.dll"
      cp "${D3D12_GUARD_DLL}" "${CONTENTS}/Runtime-ARM64EC/base-prefix/drive_c/windows/system32/d3d12.dll"
    fi
  else
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
      if [[ -f "${MSW_BUNDLE_ROOT}/share/fex-emu/Config.json" ]]; then
        sed -i '' 's/"ProfileStats":[[:space:]]*"1"/"ProfileStats": "0"/g' "${MSW_BUNDLE_ROOT}/share/fex-emu/Config.json"
      fi
      if [[ -f "${D3D12_GUARD_DLL}" && -f "${MSW_BUNDLE_ROOT}/lib/mullion/aarch64-windows/d3d12.dll" ]]; then
        echo "[DirectMetal] Installing D3D12 Alignment Guard into ARM64EC base-prefix..."
        cp "${MSW_BUNDLE_ROOT}/lib/mullion/aarch64-windows/d3d12.dll" \
           "${CONTENTS}/Runtime-ARM64EC/base-prefix/drive_c/windows/system32/d3d12_mullion.dll"
        cp "${D3D12_GUARD_DLL}" "${CONTENTS}/Runtime-ARM64EC/base-prefix/drive_c/windows/system32/d3d12.dll"
      fi
    fi
  fi
fi

echo "[DirectMetal] Applying Hardened Runtime (--options runtime) + entitlements..."
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true
codesign --force --options runtime --sign - --entitlements "${REPO_ROOT}/sandbox/DirectMetal.entitlements" "${APP_BUNDLE}"

echo "[DirectMetal] Packaged ${APP_BUNDLE} ($(du -sh "${APP_BUNDLE}" | awk '{print $1}'))"
"${CONTENTS}/MacOS/DirectMetal" info
