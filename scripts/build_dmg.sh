#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_BUNDLE="${REPO_ROOT}/dist/DirectMetal.app"
DMG_PATH="${REPO_ROOT}/dist/DirectMetal-macOS-arm64.dmg"
VOL_NAME="DirectMetal"
SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
REQUEST_SIGN=0
REPACKAGE=0
PACKAGE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_BUNDLE="$2"
      shift 2
      ;;
    --output)
      DMG_PATH="$2"
      shift 2
      ;;
    --volname)
      VOL_NAME="$2"
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

Builds a compressed macOS arm64 DMG installer (UDZO) + SHA-256 checksum,
with optional Apple Developer ID code signing, Notarytool submission, and Ticket Stapling.

Options:
  --app <path>              Source .app bundle (default: dist/DirectMetal.app)
  --output <path>           Output .dmg path (default: dist/DirectMetal-macOS-arm64.dmg)
  --volname <name>          Mounted volume name (default: DirectMetal)
  --repackage               Force running scripts/package_app.sh before building the DMG
  --include-rosetta         Include legacy Rosetta 2 runtime if packaging DirectMetal.app
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

echo "[DirectMetal] Staging DMG layout in ${STAGE_DIR}..."
# Prefer APFS CoW clone (-c) when staging on the same volume, falling back to standard copy across volumes
if ! cp -Rc "${APP_BUNDLE}" "${STAGE_DIR}/DirectMetal.app" 2>/dev/null; then
  cp -R "${APP_BUNDLE}" "${STAGE_DIR}/DirectMetal.app"
fi

ln -s /Applications "${STAGE_DIR}/Applications"

cat > "${STAGE_DIR}/README.txt" <<'EOF'
DirectMetal — Apple Silicon DirectX 9/10/11/12 Runtime
======================================================

Installation:
  1. Drag DirectMetal.app onto the Applications folder shortcut.
  2. Eject the DirectMetal disk image and launch DirectMetal from Applications.

System Requirements:
  • Apple Silicon Mac (M1 / M2 / M3 / M4 / M5)
  • macOS 15.0 Sequoia or newer (macOS 26.4+ recommended for 100% post-Rosetta ARM64EC + FEX execution)

Local / Ad-Hoc Builds:
  If this DMG was built locally without Apple Developer ID notarization, remove
  Gatekeeper quarantine once after copying to /Applications:
    xattr -dr com.apple.quarantine /Applications/DirectMetal.app

Command-Line Interface:
  /Applications/DirectMetal.app/Contents/MacOS/DirectMetal --help
EOF

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
echo "[DirectMetal] Building compressed UDZO disk image: ${DMG_PATH}..."
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -fs HFS+ \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}" >/dev/null

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
  cat <<'EOF'
[DirectMetal] Local unsigned/ad-hoc DMG build complete (no Developer ID certificate used).
  • DirectMetal.app uses ad-hoc Hardened Runtime signing (-) for local Apple Silicon testing.
  • For public Gatekeeper distribution without quarantine prompts, re-run with real Apple credentials:
      APPLE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
      APPLE_NOTARY_PROFILE="DirectMetalNotary" \
      ./scripts/build_dmg.sh --repackage
EOF
fi

(cd "${OUT_DIR}" && shasum -a 256 "${DMG_FILENAME}") > "${SHA_PATH}"
DMG_SIZE="$(du -sh "${DMG_PATH}" | awk '{print $1}')"
DMG_SHA="$(awk '{print $1}' "${SHA_PATH}")"

echo "[DirectMetal] Built ${DMG_PATH} (${DMG_SIZE})"
echo "[DirectMetal] SHA-256: ${DMG_SHA} -> ${SHA_PATH}"
