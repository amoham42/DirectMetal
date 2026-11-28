#!/usr/bin/env bash
set -euo pipefail

# DirectMetal Local CI Verification Gate
# Mirrors .github/workflows/ci.yml on an Apple Silicon development machine:
#   1. Shell syntax (bash -n scripts/*.sh) & Python syntax (py_compile)
#   2. JSON, game profile schema (scripts/validate_profiles.py), & workflow YAML validation
#   3. Python PSNR/SSIM diff-harness unit tests (tools/test_diff_harness.py)
#   4. CMake C/Obj-C++ native subsystem builds + strict Vulkan/D3D12 layer -Werror checks
#   5. CMake host subsystem tests
#   6. Swift unit tests (tests/swift/DirectMetalTests.swift when present)
#   7. DirectMetal-Lite.app build, strict codesign verification, and CLI smoke checks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CLEAN_AFTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN_AFTER=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--clean]

Runs all DirectMetal local CI checks end-to-end:
  • Shell, Python, JSON, profile schema, and workflow YAML validation
  • Python visual-diff harness unit tests (tools/test_diff_harness.py)
  • Native C/Obj-C++ CMake subsystem builds, strict -Werror layer checks, & host tests
  • Swift unit tests (tests/swift/DirectMetalTests.swift when present)
  • DirectMetal-Lite.app build, codesign verification, and CLI smoke tests

Options:
  --clean     Remove build/ and dist/ outputs after verification succeeds
  -h, --help  Show this help message
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option '$1' (pass --help for usage)" >&2
      exit 1
      ;;
  esac
done

TEMP_VENV=""
TEMP_ATTEST=""
cleanup() {
  if [[ -n "${TEMP_VENV}" && -d "${TEMP_VENV}" ]]; then
    rm -rf "${TEMP_VENV}"
  fi
  if [[ -n "${TEMP_ATTEST}" && -f "${TEMP_ATTEST}" ]]; then
    rm -f "${TEMP_ATTEST}"
  fi
}
trap cleanup EXIT

T0="$(python3 -c 'import time; print(f"{time.monotonic():.3f}")')"

echo "=== [1/7] Shell & Python Syntax Checks ==="
bash -n scripts/*.sh
echo "  [OK] bash -n passed on $(ls -1 scripts/*.sh | wc -l | tr -d ' ') shell scripts."
python3 -m py_compile scripts/*.py tools/*.py
echo "  [OK] py_compile passed on Python scripts and tools."

echo "=== [2/7] JSON, Profile Schema & Workflow YAML Validation ==="
python3 - <<'PY'
import json
import pathlib
import sys

roots = [pathlib.Path(p) for p in ("runtime", "graphics", "tests/reference") if pathlib.Path(p).exists()]
json_files = sorted(f for r in roots for f in r.rglob("*.json"))
if not json_files:
    print("error: no JSON files found under runtime/ or graphics/", file=sys.stderr)
    sys.exit(1)
for jf in json_files:
    with jf.open("r", encoding="utf-8") as fh:
        json.load(fh)
print(f"  [OK] Validated {len(json_files)} JSON file(s).")
PY

if [[ -f "${REPO_ROOT}/scripts/validate_profiles.py" ]]; then
  python3 "${REPO_ROOT}/scripts/validate_profiles.py"
  echo "  [OK] Validated game profiles schema via scripts/validate_profiles.py."
else
  echo "  [SKIP] scripts/validate_profiles.py not present; skipping profile schema validator."
fi

if [[ -d ".github/workflows" ]]; then
  if python3 -c "import yaml" >/dev/null 2>&1; then
    python3 - <<'PY'
import pathlib
import yaml

ymls = sorted(pathlib.Path(".github/workflows").glob("*.yml"))
for yf in ymls:
    doc = yaml.safe_load(yf.read_text(encoding="utf-8"))
    assert isinstance(doc, dict) and "jobs" in doc, f"Invalid workflow structure in {yf}"
print(f"  [OK] Validated {len(ymls)} workflow YAML file(s) via PyYAML.")
PY
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rdate -e '
      files = Dir.glob(".github/workflows/*.yml").sort
      abort("No workflow YAML files found") if files.empty?
      files.each do |f|
        doc = YAML.safe_load(File.read(f), permitted_classes: [Date, Time])
        abort("Invalid workflow structure in #{f}") unless doc.is_a?(Hash) && doc.key?("jobs")
      end
      puts "  [OK] Validated #{files.size} workflow YAML file(s) via Ruby Psych."
    '
  fi
fi

COMMON_GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
COMMON_ROOT=""
if [[ -n "${COMMON_GIT_DIR}" ]]; then
  [[ "${COMMON_GIT_DIR}" != /* ]] && COMMON_GIT_DIR="${REPO_ROOT}/${COMMON_GIT_DIR}"
  COMMON_ROOT="$(cd "${COMMON_GIT_DIR}/.." 2>/dev/null && pwd || true)"
fi

echo "=== [3/7] Python Visual-Diff Harness Unit Tests ==="
PY_RUNNER=""
if [[ -x "${REPO_ROOT}/.venv/bin/python" ]] && "${REPO_ROOT}/.venv/bin/python" -c "import PIL, numpy" >/dev/null 2>&1; then
  PY_RUNNER="${REPO_ROOT}/.venv/bin/python"
elif python3 -c "import PIL, numpy" >/dev/null 2>&1; then
  PY_RUNNER="python3"
elif [[ -n "${COMMON_ROOT}" && -x "${COMMON_ROOT}/.venv/bin/python" ]] && "${COMMON_ROOT}/.venv/bin/python" -c "import PIL, numpy" >/dev/null 2>&1; then
  PY_RUNNER="${COMMON_ROOT}/.venv/bin/python"
fi

if [[ -z "${PY_RUNNER}" ]]; then
  echo "  [INFO] Creating temporary venv with pillow + numpy..."
  TEMP_VENV="$(mktemp -d "${TMPDIR:-/tmp}/dm-ci-venv.XXXXXX")"
  python3 -m venv "${TEMP_VENV}"
  "${TEMP_VENV}/bin/pip" install --quiet --disable-pip-version-check pillow numpy
  PY_RUNNER="${TEMP_VENV}/bin/python"
fi
PYTHONPATH="${REPO_ROOT}/tools" "${PY_RUNNER}" "${REPO_ROOT}/tools/test_diff_harness.py"
if [[ -d "${REPO_ROOT}/tests/python" ]]; then
  echo "  [INFO] Running Python packaging & profile unit tests (tests/python)..."
  python3 -m unittest discover -s "${REPO_ROOT}/tests/python" -v
fi

echo "=== [4/7] CMake Native C/Obj-C++ Subsystem Build & Strict Layer Warning Gate ==="
SUBSYSTEMS=(
  runtime/dm_sync
  runtime/dm_prefix
  sandbox/dm_sandbox
  runtime/dm_host_io
  shaders/dm_shader_cache
  sandbox/dm_attestation
  graphics/dm_metal_core
  upscaling/dm_metalfx_bridge
)
for sub in "${SUBSYSTEMS[@]}"; do
  name="$(basename "${sub}")"
  cmake -S "${REPO_ROOT}/${sub}" -B "${REPO_ROOT}/build/${name}" >/dev/null
  cmake --build "${REPO_ROOT}/build/${name}" -j >/dev/null
  echo "  [OK] Built ${name}"
done

mkdir -p "${REPO_ROOT}/build/dm_vk_compat"
xcrun clang -O3 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -dynamiclib -fvisibility=hidden \
  "${REPO_ROOT}/graphics/dm_vk_compat/dm_vk_compat_layer.c" \
  -o "${REPO_ROOT}/build/dm_vk_compat/libdm_vk_compat_layer.dylib"
echo "  [OK] Built dm_vk_compat_layer (-Wall -Wextra -Werror, universal arm64+x86_64)"

MINGW_CLANG=""
if [[ -x "${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]]; then
  MINGW_CLANG="${REPO_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang"
elif [[ -n "${COMMON_ROOT}" && -x "${COMMON_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]]; then
  MINGW_CLANG="${COMMON_ROOT}/.directmetal_cache/toolchains/llvm-mingw/bin/x86_64-w64-mingw32-clang"
elif command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
  MINGW_CLANG="$(command -v x86_64-w64-mingw32-clang)"
fi
if [[ -n "${MINGW_CLANG}" && -f "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" ]]; then
  mkdir -p "${REPO_ROOT}/build/dm_d3d12_placed_guard"
  "${MINGW_CLANG}" -O3 -Wall -Wextra -Werror -shared \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.c" \
    "${REPO_ROOT}/graphics/dm_d3d12_placed_guard/d3d12_guard.def" \
    -o "${REPO_ROOT}/build/dm_d3d12_placed_guard/d3d12_x64.dll"
  echo "  [OK] Built d3d12_guard (-Wall -Wextra -Werror, x86_64 PE DLL)"
fi

echo "=== [5/7] CMake Host Subsystem Tests ==="
"${REPO_ROOT}/build/dm_sync/dm_sync_test"
"${REPO_ROOT}/build/dm_prefix/dm_prefix_test"
mkdir -p "${HOME}/.ssh"
"${REPO_ROOT}/build/dm_sandbox/dm_sandbox_test" "${REPO_ROOT}/sandbox/profiles/directmetal_game.sb.tmpl"
"${REPO_ROOT}/build/dm_host_io/dm_host_io_test"

if swift -e 'import Metal; guard let d = MTLCreateSystemDefaultDevice(), !d.name.lowercased().contains("paravirtual") else { exit(1) }' >/dev/null 2>&1; then
  "${REPO_ROOT}/build/dm_shader_cache/dm_shader_cache_test"
else
  echo "  [SKIP] No hardware Metal GPU device detected; skipping dm_shader_cache_test."
fi

"${REPO_ROOT}/build/dm_attestation/dm_attestation_test"

echo "=== [6/7] Swift Unit Tests ==="
if [[ -f "${REPO_ROOT}/tests/swift/DirectMetalTests.swift" ]]; then
  mkdir -p "${REPO_ROOT}/build/swift_tests"
  SWIFT_LIB_SOURCES=()
  for sf in "${REPO_ROOT}/app/DirectMetalApp"/*.swift; do
    [[ "$(basename "${sf}")" == "main.swift" ]] && continue
    SWIFT_LIB_SOURCES+=("${sf}")
  done
  SWIFT_EXTRA_TESTS=()
  for tf in "${REPO_ROOT}/tests/swift"/*.swift; do
    [[ "$(basename "${tf}")" == "DirectMetalTests.swift" ]] && continue
    SWIFT_EXTRA_TESTS+=("${tf}")
  done
  SWIFT_TEST_ENTRY="${REPO_ROOT}/tests/swift/DirectMetalTests.swift"
  if ! grep -Eq '^[[:space:]]*@main\b' "${SWIFT_TEST_ENTRY}"; then
    cp "${SWIFT_TEST_ENTRY}" "${REPO_ROOT}/build/swift_tests/main.swift"
    SWIFT_TEST_ENTRY="${REPO_ROOT}/build/swift_tests/main.swift"
  fi
  xcrun swiftc \
    -warnings-as-errors \
    -target arm64-apple-macos15.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Metal \
    -framework MetalFX \
    -framework GameController \
    -framework CryptoKit \
    -framework Security \
    -framework DeviceCheck \
    -framework UniformTypeIdentifiers \
    "${SWIFT_LIB_SOURCES[@]}" \
    ${SWIFT_EXTRA_TESTS[@]+"${SWIFT_EXTRA_TESTS[@]}"} \
    "${SWIFT_TEST_ENTRY}" \
    -o "${REPO_ROOT}/build/swift_tests/DirectMetalTests"
  "${REPO_ROOT}/build/swift_tests/DirectMetalTests"
  echo "  [OK] DirectMetalTests Swift unit test suite passed."
else
  echo "  [SKIP] tests/swift/DirectMetalTests.swift not present; skipping Swift unit test stage."
fi

echo "=== [7/7] DirectMetal-Lite.app Packaging & Smoke Verification ==="
"${REPO_ROOT}/scripts/package_app.sh" --lite
APP_BUNDLE="${REPO_ROOT}/dist/DirectMetal-Lite.app"
DM_BIN="${APP_BUNDLE}/Contents/MacOS/DirectMetal"

codesign --verify --strict "${APP_BUNDLE}"
echo "  [OK] codesign --verify --strict passed on DirectMetal-Lite.app"

"${DM_BIN}" help >/dev/null
echo "  [OK] DirectMetal help passed"

INFO_OUT="$("${DM_BIN}" info)"
printf '%s\n' "${INFO_OUT}" | python3 -m json.tool >/dev/null
echo "  [OK] DirectMetal info emitted valid JSON"

"${DM_BIN}" completions zsh | zsh -n
"${DM_BIN}" completions bash | bash -n
"${DM_BIN}" profiles match /Games/Hades/x64/Hades.exe --json | python3 -m json.tool >/dev/null
"${DM_BIN}" history --json | python3 -m json.tool >/dev/null
"${DM_BIN}" prefix prune --dry-run --json | python3 -m json.tool >/dev/null
echo "  [OK] DirectMetal CLI completions, profiles match, history & prefix prune smoke passed"

TEMP_ATTEST="$(mktemp "${TMPDIR:-/tmp}/dm-ci-attest.XXXXXX.json")"
"${DM_BIN}" attest --nonce a1b2c3d4e5f60718293a4b5c6d7e8f90 > "${TEMP_ATTEST}"
"${DM_BIN}" verify-attest "${TEMP_ATTEST}" --nonce a1b2c3d4e5f60718293a4b5c6d7e8f90 >/dev/null
echo "  [OK] DirectMetal attest + verify-attest round-trip passed"

if [[ "${CLEAN_AFTER}" == "1" ]]; then
  rm -rf "${REPO_ROOT}/build" "${REPO_ROOT}/dist"
  echo "  [CLEAN] Removed build/ and dist/"
fi

ELAPSED="$(python3 -c "import time; print(f'{time.monotonic() - ${T0}:.2f}')")"
echo "=== ALL DIRECTMETAL LOCAL CI CHECKS PASSED (${ELAPSED}s) ==="
