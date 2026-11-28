#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CUSTOM_APP_BUNDLE=""
CUSTOM_DMG_PATH=""
CUSTOM_VOL_NAME=""
LITE_MODE=0
SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
REQUEST_SIGN=0
REPACKAGE=0
DMG_FORMAT="ULFO"
PACKAGE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lite)
      LITE_MODE=1
      shift
      ;;
    --app)
      CUSTOM_APP_BUNDLE="$2"
      shift 2
      ;;
    --output)
      CUSTOM_DMG_PATH="$2"
      shift 2
      ;;
    --volname)
      CUSTOM_VOL_NAME="$2"
      shift 2
      ;;
    --repackage)
      REPACKAGE=1
      shift
      ;;
    --include-rosetta)
      PACKAGE_ARGS+=(--include-rosetta)
      shift
      ;;
    --ultra-compress)
      DMG_FORMAT="ULMO"
      shift
      ;;
    --sign)
      REQUEST_SIGN=1
      if [[ $# -ge 2 && "$2" != --* ]]; then
        SIGN_IDENTITY="$2"
        shift 2
      else
        shift
      fi
      ;;
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options]

Builds a compressed macOS arm64 DMG installer (default ULFO / Apple LZFSE, or ULMO / LZMA) + SHA-256 checksum,
with optional Apple Developer ID code signing, Notarytool submission, and Ticket Stapling.

Options:
  --lite                    Build DirectMetal Lite DMG (defaults: dist/DirectMetal-Lite.app -> dist/DirectMetal-Lite-macOS-arm64.dmg)
  --app <path>              Source .app bundle (default: dist/DirectMetal.app, or dist/DirectMetal-Lite.app with --lite)
  --output <path>           Output .dmg path (default: dist/DirectMetal-macOS-arm64.dmg, or dist/DirectMetal-Lite-macOS-arm64.dmg with --lite)
  --volname <name>          Mounted volume name (default: DirectMetal, or "DirectMetal Lite" with --lite)
  --repackage               Force running scripts/package_app.sh before building the DMG
  --include-rosetta         Include legacy Rosetta 2 runtime if packaging DirectMetal.app
  --ultra-compress          Use ULMO (LZMA) instead of default ULFO (LZFSE) for maximum release compression
  --sign [<identity>]       Sign DMG with Developer ID (uses APPLE_SIGN_IDENTITY if <identity> omitted)
  --notary-profile <name>   Submit to Apple Notary Service & staple ticket (or set APPLE_NOTARY_PROFILE)
  -h, --help                Show this help message

Environment Variables:
  APPLE_SIGN_IDENTITY       "Developer ID Application: Your Name (TEAMID)" (defaults to '-' ad-hoc locally)
  APPLE_NOTARY_PROFILE      Keychain profile name created via 'xcrun notarytool store-credentials'
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option '$1' (pass --help for usage)" >&2
      exit 1
      ;;
  esac
done

if [[ "${LITE_MODE}" == "1" ]]; then
  APP_BUNDLE="${CUSTOM_APP_BUNDLE:-${REPO_ROOT}/dist/DirectMetal-Lite.app}"
  DMG_PATH="${CUSTOM_DMG_PATH:-${REPO_ROOT}/dist/DirectMetal-Lite-macOS-arm64.dmg}"
  VOL_NAME="${CUSTOM_VOL_NAME:-DirectMetal Lite}"
  PACKAGE_ARGS+=(--lite)
else
  APP_BUNDLE="${CUSTOM_APP_BUNDLE:-${REPO_ROOT}/dist/DirectMetal.app}"
  DMG_PATH="${CUSTOM_DMG_PATH:-${REPO_ROOT}/dist/DirectMetal-macOS-arm64.dmg}"
  VOL_NAME="${CUSTOM_VOL_NAME:-DirectMetal}"
fi
if [[ -n "${CUSTOM_APP_BUNDLE}" ]]; then
  PACKAGE_ARGS+=(--output "${APP_BUNDLE}")
fi
APP_BASENAME="$(basename "${APP_BUNDLE}")"

if [[ "${REQUEST_SIGN}" == "1" && ( -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" == "-" ) ]]; then
  echo "error: --sign was passed, but no real Apple Developer ID identity was provided." >&2
  echo "  Pass --sign \"Developer ID Application: Name (TEAMID)\" or export APPLE_SIGN_IDENTITY." >&2
  exit 1
fi

if [[ "${REPACKAGE}" == "1" || ! -d "${APP_BUNDLE}" ]]; then
  echo "[DirectMetal] Packaging ${APP_BUNDLE} before creating DMG..."
  APPLE_SIGN_IDENTITY="${SIGN_IDENTITY}" "${SCRIPT_DIR}/package_app.sh" "${PACKAGE_ARGS[@]}"
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "error: source app bundle not found at ${APP_BUNDLE}" >&2
  exit 1
fi

OUT_DIR="$(dirname "${DMG_PATH}")"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
DMG_FILENAME="$(basename "${DMG_PATH}")"
DMG_PATH="${OUT_DIR}/${DMG_FILENAME}"
SHA_PATH="${DMG_PATH}.sha256"

STAGE_DIR="${OUT_DIR}/.dmg-staging-$$"
cleanup() {
  rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

echo "[DirectMetal] Staging DMG layout in ${STAGE_DIR} (${APP_BASENAME})..."
# Prefer APFS CoW clone (-c) when staging on the same volume, falling back to standard copy across volumes
if ! cp -Rc "${APP_BUNDLE}" "${STAGE_DIR}/${APP_BASENAME}" 2>/dev/null; then
  cp -R "${APP_BUNDLE}" "${STAGE_DIR}/${APP_BASENAME}"
fi

ln -s /Applications "${STAGE_DIR}/Applications"

if [[ "${LITE_MODE}" == "1" ]]; then
  cat > "${STAGE_DIR}/README.txt" <<EOF
DirectMetal Lite — Apple Silicon DirectX 9/10/11/12 Launcher
============================================================

Installation:
  1. Drag ${APP_BASENAME} onto the Applications folder shortcut.
  2. Eject the ${VOL_NAME} disk image and launch ${APP_BASENAME%.app} from Applications.

Verified First-Run Runtime Download:
  DirectMetal Lite automatically downloads and SHA-256 verifies the signed ARM64EC + FEX + Mullion
  runtime on first launch via the GUI, or from Terminal via:
    /Applications/${APP_BASENAME}/Contents/MacOS/DirectMetal runtime install

System Requirements:
  • Apple Silicon Mac (M1 / M2 / M3 / M4 / M5)
  • macOS 15.0 Sequoia or newer (macOS 26.4+ recommended for 100% post-Rosetta ARM64EC + FEX execution)

Local / Ad-Hoc Builds:
  If this DMG was built locally without Apple Developer ID notarization, remove
  Gatekeeper quarantine once after copying to /Applications:
    xattr -dr com.apple.quarantine "/Applications/${APP_BASENAME}"

Command-Line Interface:
  "/Applications/${APP_BASENAME}/Contents/MacOS/DirectMetal" --help
EOF
else
  cat > "${STAGE_DIR}/README.txt" <<EOF
DirectMetal — Apple Silicon DirectX 9/10/11/12 Runtime
======================================================

Installation:
  1. Drag ${APP_BASENAME} onto the Applications folder shortcut.
  2. Eject the ${VOL_NAME} disk image and launch ${APP_BASENAME%.app} from Applications.

System Requirements:
  • Apple Silicon Mac (M1 / M2 / M3 / M4 / M5)
  • macOS 15.0 Sequoia or newer (macOS 26.4+ recommended for 100% post-Rosetta ARM64EC + FEX execution)

Local / Ad-Hoc Builds:
  If this DMG was built locally without Apple Developer ID notarization, remove
  Gatekeeper quarantine once after copying to /Applications:
    xattr -dr com.apple.quarantine "/Applications/${APP_BASENAME}"

Command-Line Interface:
  "/Applications/${APP_BASENAME}/Contents/MacOS/DirectMetal" --help
EOF
fi

ICON_CANDIDATE=""
if [[ -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]]; then
  ICON_CANDIDATE="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
elif [[ -f "${REPO_ROOT}/app/DirectMetalApp/AppIcon.icns" ]]; then
  ICON_CANDIDATE="${REPO_ROOT}/app/DirectMetalApp/AppIcon.icns"
fi

if [[ -n "${ICON_CANDIDATE}" ]]; then
  echo "[DirectMetal] Setting custom DMG volume icon from ${ICON_CANDIDATE}..."
  cp "${ICON_CANDIDATE}" "${STAGE_DIR}/.VolumeIcon.icns"
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -c icnC "${STAGE_DIR}/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "${STAGE_DIR}" 2>/dev/null || true
  elif xcrun -f SetFile >/dev/null 2>&1; then
    xcrun SetFile -c icnC "${STAGE_DIR}/.VolumeIcon.icns" 2>/dev/null || true
    xcrun SetFile -a C "${STAGE_DIR}" 2>/dev/null || true
  fi
fi

rm -f "${DMG_PATH}" "${SHA_PATH}"
echo "[DirectMetal] Building compressed ${DMG_FORMAT} disk image: ${DMG_PATH}..."
DMG_T0="$(python3 -c 'import time; print(f"{time.monotonic():.6f}")')"
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -fs HFS+ \
  -ov \
  -format "${DMG_FORMAT}" \
  "${DMG_PATH}" >/dev/null
DMG_ELAPSED="$(python3 -c "import time; print(f'{time.monotonic() - ${DMG_T0}:.2f}')")"

echo "[DirectMetal] Verifying disk image integrity (hdiutil verify)..."
hdiutil verify "${DMG_PATH}" >/dev/null

if [[ -n "${SIGN_IDENTITY}" && "${SIGN_IDENTITY}" != "-" ]]; then
  echo "[DirectMetal] Signing DMG with Developer ID: ${SIGN_IDENTITY}..."
  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
  codesign --verify --verbose=2 "${DMG_PATH}"

  if [[ -n "${NOTARY_PROFILE}" ]]; then
    echo "[DirectMetal] Submitting ${DMG_FILENAME} to Apple Notary Service (profile: ${NOTARY_PROFILE})..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    echo "[DirectMetal] Stapling notarization ticket to ${DMG_FILENAME}..."
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
  else
    cat <<EOF
[DirectMetal] Note: DMG is signed with '${SIGN_IDENTITY}', but APPLE_NOTARY_PROFILE is unset.
  To notarize & staple for Gatekeeper distribution:
    1. xcrun notarytool store-credentials "DirectMetalNotary" --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
    2. APPLE_SIGN_IDENTITY="${SIGN_IDENTITY}" APPLE_NOTARY_PROFILE="DirectMetalNotary" ./scripts/build_dmg.sh
EOF
  fi
else
  cat <<EOF
[DirectMetal] Local unsigned/ad-hoc DMG build complete (no Developer ID certificate used).
  • ${APP_BASENAME} uses ad-hoc Hardened Runtime signing (-) for local Apple Silicon testing.
  • For public Gatekeeper distribution without quarantine prompts, re-run with real Apple credentials:
      APPLE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \\
      APPLE_NOTARY_PROFILE="DirectMetalNotary" \\
      ./scripts/build_dmg.sh --repackage$( [[ "${LITE_MODE}" == "1" ]] && printf " --lite" )
EOF
fi

(cd "${OUT_DIR}" && shasum -a 256 "${DMG_FILENAME}") > "${SHA_PATH}"
DMG_BYTES="$(stat -f%z "${DMG_PATH}")"
DMG_MIB="$(python3 -c "print(f'{${DMG_BYTES} / (1024 * 1024):.1f}')")"
DMG_SIZE="$(du -sh "${DMG_PATH}" | awk '{print $1}')"
DMG_SHA="$(awk '{print $1}' "${SHA_PATH}")"

echo "[DirectMetal] Built ${DMG_PATH} (format: ${DMG_FORMAT}, size: ${DMG_MIB} MiB / ${DMG_SIZE} / ${DMG_BYTES} bytes, build time: ${DMG_ELAPSED}s)"
echo "[DirectMetal] SHA-256: ${DMG_SHA} -> ${SHA_PATH}"
