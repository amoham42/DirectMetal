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
  -o "${CONTENTS}/MacOS/DirectMetal" \
  "${APP_SRC}/PEInspector.swift" \
  "${APP_SRC}/PrefixManager.swift" \
  "${APP_SRC}/RuntimeLauncher.swift" \
  "${APP_SRC}/DirectMetalGUI.swift" \
  "${APP_SRC}/main.swift"

cp "${APP_SRC}/Info.plist" "${CONTENTS}/Info.plist"
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Resources/mullion.conf"

echo "[DirectMetal] Cloning self-contained Wine + Mullion runtime via APFS CoW..."
cp -Rc "${RUNTIME_SRC}/wine-dist" "${CONTENTS}/Runtime/wine-dist"
cp -Rc "${RUNTIME_SRC}/mullion-dist" "${CONTENTS}/Runtime/mullion-dist"
cp -Rc "${RUNTIME_SRC}/base-prefix" "${CONTENTS}/Runtime/base-prefix"
cp "${REPO_ROOT}/runtime/config/mullion.conf" "${CONTENTS}/Runtime/mullion.conf"

# Create relative symlinks inside Contents/Runtime so the .app is relocatable
WINE_REL="$(cd "${CONTENTS}/Runtime" && find wine-dist -maxdepth 6 -type f -name wine -path "*/bin/wine" | head -n 1 | sed 's|/bin/wine$||')"
MULLION_REL="$(cd "${CONTENTS}/Runtime" && find mullion-dist -maxdepth 3 -type f -name install.sh | head -n 1 | sed 's|/install.sh$||')"
ln -sfn "${WINE_REL}" "${CONTENTS}/Runtime/wine"
ln -sfn "${MULLION_REL}" "${CONTENTS}/Runtime/mullion"

echo "[DirectMetal] Applying Hardened Runtime entitlements (ad-hoc signed)..."
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true
codesign --force --sign - --entitlements "${REPO_ROOT}/sandbox/DirectMetal.entitlements" "${APP_BUNDLE}"

echo "[DirectMetal] Packaged ${APP_BUNDLE}"
"${CONTENTS}/MacOS/DirectMetal" info
