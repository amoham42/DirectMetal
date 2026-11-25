#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_FILE="${REPO_ROOT}/docs/ENV_AUDIT_M1PRO.md"

mkdir -p "$(dirname "${OUT_FILE}")"

MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
MACOS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo 'unknown')"
KERNEL_INFO="$(uname -a 2>/dev/null || echo 'unknown')"
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 'unknown')"
MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo '0')"
MEM_GB="$((MEM_BYTES / 1024 / 1024 / 1024))"
GPU_INFO="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset Model:|Total Number of Cores:|Metal Support:" | sed 's/^ *//' || true)"

XCODE_DIR="$(xcode-select -p 2>/dev/null || echo 'not set')"
XCODE_VER="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || echo 'unavailable')"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 'unavailable')"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo '')"
METAL_TOOLCHAIN_STATUS="$(xcodebuild -showComponent MetalToolchain 2>&1 | tr '\n' '; ' | sed 's/; $//')"
METAL_CLI_PATH="$(xcrun -f metal 2>&1 || true)"
METALLIB_CLI_PATH="$(xcrun -f metallib 2>&1 || true)"
METAL_EXEC_TEST="$(xcrun metal --version 2>&1 | head -n 2 | tr '\n' ' ' || true)"
CLANGXX_VER="$(xcrun clang++ --version 2>&1 | head -n 1 || echo 'unavailable')"
SWIFTC_VER="$(xcrun swiftc --version 2>&1 | head -n 1 || echo 'unavailable')"
ROSETTA_ARCH="$(arch -x86_64 uname -m 2>&1 || echo 'unavailable')"

check_tool() {
  local name="$1"
  local path
  if path="$(command -v "${name}" 2>/dev/null)"; then
    local ver
    ver="$("${name}" --version 2>&1 | head -n 1 || true)"
    echo "| \`${name}\` | Found | \`${path}\` | \`${ver}\` |"
  else
    echo "| \`${name}\` | Missing | - | - |"
  fi
}

VENV_STATUS="Missing"
if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
  VENV_PKGS="$("${REPO_ROOT}/.venv/bin/python" -c "import numpy, PIL; print(f'numpy {numpy.__version__}, Pillow {PIL.__version__}')" 2>&1 || echo "broken")"
  VENV_STATUS="Ready (\`${VENV_PKGS}\`)"
fi

GH_AUTH_STATUS="$(gh auth status 2>&1 | tr '\n' ' ' | sed 's/  */ /g' || echo 'not authenticated')"
GIT_REMOTE="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo 'none')"

METAL4_HEADER="No"
[[ -n "${SDK_PATH}" && -f "${SDK_PATH}/System/Library/Frameworks/Metal.framework/Headers/MTL4CommandQueue.h" ]] && METAL4_HEADER="Yes (\`MTL4CommandQueue.h\`)"
METALFX_HEADER="No"
[[ -n "${SDK_PATH}" && -f "${SDK_PATH}/System/Library/Frameworks/MetalFX.framework/Headers/MetalFX.h" ]] && METALFX_HEADER="Yes (\`MetalFX.h\`)"
OSSYNC_HEADER="No"
[[ -n "${SDK_PATH}" && -f "${SDK_PATH}/usr/include/os/os_sync_wait_on_address.h" ]] && OSSYNC_HEADER="Yes (\`os/os_sync_wait_on_address.h\`)"

cat > "${OUT_FILE}" <<EOF
# DirectMetal M1 Pro Environment Audit

Generated: \`$(date -u '+%Y-%m-%dT%H:%M:%SZ')\`

## Hardware & OS

- **macOS Version:** ${MACOS_VER} (Build \`${MACOS_BUILD}\`)
- **Kernel:** \`${KERNEL_INFO}\`
- **CPU:** ${CPU_BRAND} (${NCPU} cores)
- **Unified Memory:** ${MEM_GB} GB (\`${MEM_BYTES}\` bytes)
- **Rosetta 2 (`arch -x86_64 uname -m`):** \`${ROSETTA_ARCH}\`
- **GPU / Metal Info:**
\`\`\`
${GPU_INFO}
\`\`\`

## Xcode, Metal SDK & Toolchain

- **Developer Dir:** \`${XCODE_DIR}\`
- **Xcode:** ${XCODE_VER}
- **macOS SDK:** ${SDK_VER} (\`${SDK_PATH}\`)
- **Metal 4 Headers:** ${METAL4_HEADER}
- **MetalFX Headers:** ${METALFX_HEADER}
- **Fast Sync Header:** ${OSSYNC_HEADER}
- **MetalToolchain Component:** \`${METAL_TOOLCHAIN_STATUS}\`
- **\`xcrun -f metal\`:** \`${METAL_CLI_PATH}\`
- **\`xcrun metal --version\`:** \`${METAL_EXEC_TEST}\`
- **\`xcrun -f metallib\`:** \`${METALLIB_CLI_PATH}\`
- **\`clang++\`:** \`${CLANGXX_VER}\`
- **\`swiftc\`:** \`${SWIFTC_VER}\`

## CLI & Build Tools

| Tool | Status | Path | Version |
| :--- | :--- | :--- | :--- |
$(check_tool brew)
$(check_tool cmake)
$(check_tool ninja)
$(check_tool meson)
$(check_tool pkg-config)
$(check_tool dxc)
$(check_tool python3)
$(check_tool uv)
$(check_tool git)
$(check_tool gh)

- **Python Diff Venv (\`.venv\`):** ${VENV_STATUS}
- **Git Origin:** \`${GIT_REMOTE}\`
- **GitHub CLI Auth:** \`${GH_AUTH_STATUS}\`
EOF

echo "Wrote ${OUT_FILE}"
cat "${OUT_FILE}"
