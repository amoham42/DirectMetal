#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
COMMON_REPO_ROOT=""
if [[ -n "${COMMON_GIT_DIR}" ]]; then
  if [[ "${COMMON_GIT_DIR}" != /* ]]; then
    COMMON_GIT_DIR="${REPO_ROOT}/${COMMON_GIT_DIR}"
  fi
  COMMON_REPO_ROOT="$(cd "${COMMON_GIT_DIR}/.." 2>/dev/null && pwd || true)"
fi

APP_SRC="${REPO_ROOT}/app/DirectMetalApp"
RUNTIME_SRC="${DIRECTMETAL_RUNTIME_SRC:-${REPO_ROOT}/build/runtime}"
if [[ -z "${DIRECTMETAL_RUNTIME_SRC:-}" && ! -d "${RUNTIME_SRC}" && -n "${COMMON_REPO_ROOT}" && -d "${COMMON_REPO_ROOT}/build/runtime" ]]; then
  RUNTIME_SRC="${COMMON_REPO_ROOT}/build/runtime"
fi
ARM64EC_SRC="${DIRECTMETAL_ARM64EC_SRC:-${REPO_ROOT}/build/runtime-arm64ec}"
if [[ -z "${DIRECTMETAL_ARM64EC_SRC:-}" && ! -d "${ARM64EC_SRC}" && -n "${COMMON_REPO_ROOT}" && -d "${COMMON_REPO_ROOT}/build/runtime-arm64ec" ]]; then
  ARM64EC_SRC="${COMMON_REPO_ROOT}/build/runtime-arm64ec"
fi

STAGE_PREFIX_ROOT=""
cleanup() {
  if [[ -n "${STAGE_PREFIX_ROOT}" && -d "${STAGE_PREFIX_ROOT}" ]]; then
    rm -rf "${STAGE_PREFIX_ROOT}"
  fi
}
trap cleanup EXIT

LITE_MODE="${DIRECTMETAL_LITE:-0}"
CUSTOM_APP_BUNDLE="${DIRECTMETAL_APP_BUNDLE:-}"
INCLUDE_ROSETTA="${DIRECTMETAL_INCLUDE_ROSETTA:-0}"
SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lite)
      LITE_MODE=1
      shift
      ;;
    --output)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        CUSTOM_APP_BUNDLE="$2"
        shift 2
      else
        echo "error: --output requires a target .app path" >&2
        exit 1
      fi
      ;;
    --include-rosetta)
      INCLUDE_ROSETTA=1
      shift
      ;;
    --slim|--no-rosetta)
      INCLUDE_ROSETTA=0
      shift
      ;;
    --sign)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        SIGN_IDENTITY="$2"
        shift 2
      elif [[ -n "${APPLE_SIGN_IDENTITY:-}" && "${APPLE_SIGN_IDENTITY}" != "-" ]]; then
        SIGN_IDENTITY="${APPLE_SIGN_IDENTITY}"
        shift
      else
        echo "error: --sign requires a Developer ID identity argument or APPLE_SIGN_IDENTITY env var" >&2
        exit 1
      fi
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--lite] [--slim] [--include-rosetta] [--output <path>] [--sign <identity>]

Options:
  --lite                Build compact DirectMetal-Lite.app (~2-4 MB) without embedded Wine/Mullion runtimes
  --slim, --no-rosetta  Default slim 100% post-Rosetta ARM64EC+FEX mode (DIRECTMETAL_INCLUDE_ROSETTA=0)
  --include-rosetta     Also bundle legacy Rosetta 2 runtime into Contents/Runtime (DIRECTMETAL_INCLUDE_ROSETTA=1)
  --output <path>       Custom output .app path (or set DIRECTMETAL_APP_BUNDLE)
  --sign <identity>     Code-sign app bundle with Apple Developer ID (or set APPLE_SIGN_IDENTITY; default '-')
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option '$1' (pass --help for usage)" >&2
      exit 1
      ;;
  esac
done

if [[ -n "${CUSTOM_APP_BUNDLE}" ]]; then
  APP_BUNDLE="${CUSTOM_APP_BUNDLE}"
elif [[ "${LITE_MODE}" == "1" ]]; then
  APP_BUNDLE="${REPO_ROOT}/dist/DirectMetal-Lite.app"
else
  APP_BUNDLE="${REPO_ROOT}/dist/DirectMetal.app"
fi
mkdir -p "$(dirname "${APP_BUNDLE}")"
APP_BUNDLE="$(cd "$(dirname "${APP_BUNDLE}")" && pwd)/$(basename "${APP_BUNDLE}")"
APP_BASENAME="$(basename "${APP_BUNDLE}")"
CONTENTS="${APP_BUNDLE}/Contents"

HAS_ARM64EC=0
if [[ -d "${ARM64EC_SRC}/base-prefix" ]]; then
  HAS_ARM64EC=1
fi

BUNDLE_ROSETTA=0
if [[ "${LITE_MODE}" == "1" ]]; then
  echo "[DirectMetal] Lite mode active: building compact ${APP_BASENAME} (runtime downloaded on first launch)."
elif [[ "${INCLUDE_ROSETTA}" == "1" ]]; then
  BUNDLE_ROSETTA=1
  echo "[DirectMetal] Rosetta inclusion requested (DIRECTMETAL_INCLUDE_ROSETTA=1): bundling legacy Rosetta 2 runtime."
elif [[ "${HAS_ARM64EC}" == "0" ]]; then
  BUNDLE_ROSETTA=1
  echo "[DirectMetal] build/runtime-arm64ec/base-prefix not found; falling back to bundling build/runtime."
else
  echo "[DirectMetal] Slim post-Rosetta mode active: skipping Contents/Runtime (~3+ GB saved; pass --include-rosetta to include)."
fi

if [[ "${BUNDLE_ROSETTA}" == "1" ]]; then
  if [[ ! -d "${RUNTIME_SRC}/wine" || ! -d "${RUNTIME_SRC}/base-prefix" ]]; then
    echo "[DirectMetal] Rosetta runtime missing; running scripts/setup_runtime.sh..."
    "${REPO_ROOT}/scripts/setup_runtime.sh"
  fi
fi

echo "[DirectMetal] Compiling ${APP_BASENAME} (arm64 Swift, -O -whole-module-optimization)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

shopt -s nullglob
SWIFT_SOURCES=("${APP_SRC}"/*.swift)
shopt -u nullglob
if [[ ${#SWIFT_SOURCES[@]} -eq 0 ]]; then
  echo "error: no Swift source files found in ${APP_SRC}" >&2
  exit 1
fi

xcrun swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos15.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Metal \
  -framework MetalFX \
  -framework CryptoKit \
  -framework Security \
  -framework DeviceCheck \
  -o "${CONTENTS}/MacOS/DirectMetal" \
  "${SWIFT_SOURCES[@]}"

if [[ ! -f "${APP_SRC}/AppIcon.icns" && -f "${SCRIPT_DIR}/generate_icon.swift" ]]; then
  echo "[DirectMetal] Generating AppIcon.icns..."
  swift "${SCRIPT_DIR}/generate_icon.swift" "${APP_SRC}/AppIcon.icns"
fi

cp "${APP_SRC}/Info.plist" "${CONTENTS}/Info.plist"
if [[ -f "${APP_SRC}/AppIcon.icns" ]]; then
  cp "${APP_SRC}/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
fi
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Resources/mullion.conf"
cp "${REPO_ROOT}/sandbox/profiles/directmetal_game.sb.tmpl" "${CONTENTS}/Resources/directmetal_game.sb.tmpl"

echo "[DirectMetal] Building & bundling universal Vulkan compat layer (VK_LAYER_DIRECTMETAL_mvk_compat)..."
mkdir -p "${CONTENTS}/Resources/vulkan-layers" "${REPO_ROOT}/build/dm_vk_compat"
xcrun clang -O3 -arch arm64 -arch x86_64 -dynamiclib -fvisibility=hidden \
  "${REPO_ROOT}/graphics/dm_vk_compat/dm_vk_compat_layer.c" \
  -o "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
strip -x "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
cp "${REPO_ROOT}/graphics/dm_vk_compat/VK_LAYER_DIRECTMETAL_mvk_compat.json" "${REPO_ROOT}/build/dm_vk_compat/"
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" \
    "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
else
  codesign --force --sign - "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
fi
cp "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib" "${CONTENTS}/Resources/vulkan-layers/"
cp "${REPO_ROOT}/build/dm_vk_compat/VK_LAYER_DIRECTMETAL_mvk_compat.json" "${CONTENTS}/Resources/vulkan-layers/"

D3D12_GUARD_DLL="${REPO_ROOT}/build/dm_d3d12_placed_guard/d3d12_x64.dll"
MINGW_CLANG=""
if [[ -x "${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]]; then
  MINGW_CLANG="${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang"
elif [[ -n "${COMMON_REPO_ROOT}" && -x "${COMMON_REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]]; then
  MINGW_CLANG="${COMMON_REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang"
elif command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
  MINGW_CLANG="$(command -v x86_64-w64-mingw32-clang)"
fi
if [[ -n "${MINGW_CLANG}" && -f "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" ]]; then
  echo "[DirectMetal] Building D3D12 Placed-Resource Alignment Guard (d3d12_x64.dll, -O3)..."
  mkdir -p "${REPO_ROOT}/build/dm_d3d12_placed_guard"
  "${MINGW_CLANG}" -O3 -shared \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.def" \
    -o "${D3D12_GUARD_DLL}"
fi
if [[ -f "${D3D12_GUARD_DLL}" ]]; then
  mkdir -p "${CONTENTS}/Resources/guards"
  cp "${D3D12_GUARD_DLL}" "${CONTENTS}/Resources/guards/d3d12_x64.dll"
fi

if [[ "${LITE_MODE}" == "1" ]]; then
  if [[ -d "${ARM64EC_SRC}/base-prefix" && -d "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app" ]]; then
    echo "[DirectMetal] Lite mode: dehydrating local ARM64EC base-prefix into Contents/Resources/base-prefix-dehydrated..."
    mkdir -p "${REPO_ROOT}/build"
    STAGE_PREFIX_ROOT="$(mktemp -d "${REPO_ROOT}/build/.stage-arm64ec-prefix.XXXXXX")"
    STAGE_BASE_PREFIX="${STAGE_PREFIX_ROOT}/base-prefix"
    if ! cp -Rc "${ARM64EC_SRC}/base-prefix" "${STAGE_BASE_PREFIX}" 2>/dev/null; then
      cp -R "${ARM64EC_SRC}/base-prefix" "${STAGE_BASE_PREFIX}"
    fi
    if [[ -f "${D3D12_GUARD_DLL}" && -f "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app/Contents/lib/mullion/aarch64-windows/d3d12.dll" ]]; then
      rm -f "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll" \
            "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
      cp "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app/Contents/lib/mullion/aarch64-windows/d3d12.dll" \
         "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll"
      cp "${D3D12_GUARD_DLL}" \
         "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
    fi
    python3 "${SCRIPT_DIR}/dehydrate_base_prefix.py" \
      --base-prefix "${STAGE_BASE_PREFIX}" \
      --wine-app-contents "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app/Contents" \
      --out-dir "${CONTENTS}/Resources/base-prefix-dehydrated"
    rm -rf "${STAGE_PREFIX_ROOT}"
    STAGE_PREFIX_ROOT=""
  else
    echo "[DirectMetal] Lite mode: local ARM64EC base-prefix + MetalSharp-Wine.app not found; skipping optional pre-dehydrated base-prefix."
  fi
fi

if [[ "${LITE_MODE}" != "1" && "${BUNDLE_ROSETTA}" == "1" ]]; then
  echo "[DirectMetal] Cloning self-contained Wine + Mullion Rosetta runtime via APFS CoW..."
  mkdir -p "${CONTENTS}/Runtime"
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
fi

if [[ "${LITE_MODE}" != "1" && "${HAS_ARM64EC}" == "1" ]]; then
  echo "[DirectMetal] Packaging ARM64EC + FEX-Emu runtime with dehydrated base-prefix..."
  mkdir -p "${CONTENTS}/Runtime-ARM64EC/wine-dist" "${REPO_ROOT}/build"
  STAGE_PREFIX_ROOT="$(mktemp -d "${REPO_ROOT}/build/.stage-arm64ec-prefix.XXXXXX")"
  STAGE_BASE_PREFIX="${STAGE_PREFIX_ROOT}/base-prefix"
  if ! cp -Rc "${ARM64EC_SRC}/base-prefix" "${STAGE_BASE_PREFIX}" 2>/dev/null; then
    cp -R "${ARM64EC_SRC}/base-prefix" "${STAGE_BASE_PREFIX}"
  fi

  if [[ -d "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app" ]]; then
    MSW_APP="${CONTENTS}/Runtime-ARM64EC/wine-dist/MetalSharp-Wine.app"
    # Keep MetalSharp-Wine.app signature, notarization, and cross-architecture entitlement intact!
    if ! cp -Rc "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app" "${MSW_APP}" 2>/dev/null; then
      cp -R "${ARM64EC_SRC}/wine-dist/MetalSharp-Wine.app" "${MSW_APP}"
    fi
    ln -sfn "wine-dist/MetalSharp-Wine.app/Contents/MacOS" "${CONTENTS}/Runtime-ARM64EC/bin"
    echo "[DirectMetal] Deduplicating MetalSharp-Wine.app via atomic hardlinks & verifying signature..."
    python3 "${SCRIPT_DIR}/dedup_bundle_hardlinks.py" --bundle "${MSW_APP}" --verify-codesign
    if [[ -f "${D3D12_GUARD_DLL}" && -f "${MSW_APP}/Contents/lib/mullion/aarch64-windows/d3d12.dll" ]]; then
      echo "[DirectMetal] Installing D3D12 Alignment Guard into staged ARM64EC base-prefix..."
      rm -f "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll" \
            "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
      cp "${MSW_APP}/Contents/lib/mullion/aarch64-windows/d3d12.dll" \
         "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll"
      cp "${D3D12_GUARD_DLL}" \
         "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
    fi
    python3 "${SCRIPT_DIR}/dehydrate_base_prefix.py" \
      --base-prefix "${STAGE_BASE_PREFIX}" \
      --wine-app-contents "${MSW_APP}/Contents" \
      --out-dir "${CONTENTS}/Runtime-ARM64EC/base-prefix-dehydrated"
  else
    rm -rf "${CONTENTS}/Runtime-ARM64EC/wine-dist"
    if ! cp -Rc "${ARM64EC_SRC}/wine-dist" "${CONTENTS}/Runtime-ARM64EC/wine-dist" 2>/dev/null; then
      cp -R "${ARM64EC_SRC}/wine-dist" "${CONTENTS}/Runtime-ARM64EC/wine-dist"
    fi
    if [[ -L "${ARM64EC_SRC}/bin" ]]; then
      ln -sfn "$(readlink "${ARM64EC_SRC}/bin")" "${CONTENTS}/Runtime-ARM64EC/bin"
    fi
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
        echo "[DirectMetal] Installing D3D12 Alignment Guard into staged ARM64EC base-prefix..."
        rm -f "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll" \
              "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
        cp "${MSW_BUNDLE_ROOT}/lib/mullion/aarch64-windows/d3d12.dll" \
           "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12_mullion.dll"
        cp "${D3D12_GUARD_DLL}" \
           "${STAGE_BASE_PREFIX}/drive_c/windows/system32/d3d12.dll"
      fi
      python3 "${SCRIPT_DIR}/dehydrate_base_prefix.py" \
        --base-prefix "${STAGE_BASE_PREFIX}" \
        --wine-app-contents "${MSW_BUNDLE_ROOT}" \
        --out-dir "${CONTENTS}/Runtime-ARM64EC/base-prefix-dehydrated"
    fi
  fi

  rm -rf "${STAGE_PREFIX_ROOT}"
  STAGE_PREFIX_ROOT=""
fi

echo "[DirectMetal] Stripping local debug symbols from DirectMetal executable..."
strip -x "${CONTENTS}/MacOS/DirectMetal"

xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
  echo "[DirectMetal] Signing ${APP_BASENAME} with Developer ID (${SIGN_IDENTITY}) + Hardened Runtime + timestamp..."
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" \
    --entitlements "${REPO_ROOT}/sandbox/DirectMetal.entitlements" "${APP_BUNDLE}"
else
  echo "[DirectMetal] Applying ad-hoc Hardened Runtime (--options runtime --sign -) + entitlements to ${APP_BASENAME}..."
  codesign --force --options runtime --sign - \
    --entitlements "${REPO_ROOT}/sandbox/DirectMetal.entitlements" "${APP_BUNDLE}"
fi

# Re-verify embedded MetalSharp-Wine.app remained 100% valid after top-level bundle signing
if [[ -d "${CONTENTS}/Runtime-ARM64EC/wine-dist/MetalSharp-Wine.app" ]]; then
  codesign --verify --strict --deep "${CONTENTS}/Runtime-ARM64EC/wine-dist/MetalSharp-Wine.app"
fi

echo "[DirectMetal] Packaged ${APP_BUNDLE} ($(du -sh "${APP_BUNDLE}" | awk '{print $1}'))"
if [[ "${LITE_MODE}" == "1" ]]; then
  "${CONTENTS}/MacOS/DirectMetal" info || true
else
  "${CONTENTS}/MacOS/DirectMetal" info
fi
