#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DM_BIN="${REPO_ROOT}/dist/DirectMetal.app/Contents/MacOS/DirectMetal"
BIN_CACHE="${REPO_ROOT}/.directmetal_cache/conformance-bin"
CAND_DIR="${REPO_ROOT}/captures/m1pro"
REF_DIR="${REPO_ROOT}/tests/reference/rtx3070"
DIFF_DIR="${REPO_ROOT}/captures/diffs"

if [[ ! -x "${DM_BIN}" ]]; then
  "${REPO_ROOT}/scripts/package_app.sh"
fi

mkdir -p "${BIN_CACHE}" "${CAND_DIR}" "${DIFF_DIR}"

if [[ ! -f "${BIN_CACHE}/dm_d3d11_conformance.exe" || ! -f "${BIN_CACHE}/dm_d3d12_conformance.exe" ]]; then
  echo "[DirectMetal] Downloading conformance test binaries from GitHub release conformance-bins-v0.1..."
  gh release download conformance-bins-v0.1 -R amoham42/DirectMetal -D "${BIN_CACHE}" --clobber
fi

echo "=== PE INSPECT: D3D11 ==="
"${DM_BIN}" inspect "${BIN_CACHE}/dm_d3d11_conformance.exe"
echo "=== PE INSPECT: D3D12 ==="
"${DM_BIN}" inspect "${BIN_CACHE}/dm_d3d12_conformance.exe"

# Convert POSIX path to Wine Z: path
WIN_CAND_DIR="Z:${CAND_DIR//\//\\}"

echo "=== RUNNING D3D11 CONFORMANCE VIA DIRECTMETAL ==="
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d11_conformance.exe" \
  --prefix conformance_d3d11 \
  --reset-prefix \
  -- --out "${WIN_CAND_DIR}" --frames 200 || true

echo "=== RUNNING D3D12 CONFORMANCE VIA DIRECTMETAL ==="
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d12_conformance.exe" \
  --prefix conformance_d3d12 \
  --reset-prefix \
  -- --out "${WIN_CAND_DIR}" --frames 200 || true

# Write system_info.json for M1 Pro
MACOS_VER="$(sw_vers -productVersion)"
MACOS_BUILD="$(sw_vers -buildVersion)"
cat > "${CAND_DIR}/system_info.json" <<EOF
{
  "os": "macOS ${MACOS_VER} (${MACOS_BUILD})",
  "cpu": "Apple M1 Pro (8 cores, 16 GB UMA)",
  "gpu": "Apple M1 Pro (14-core GPU)",
  "metal": "Metal 4 / Metal 3",
  "runtime": "DirectMetal (Wine 11.21 + Mullion v0.5-alpha.4)"
}
EOF

# Collect host subsystem microbenchmarks (dm_sync + dm_prefix)
if [[ -x "${REPO_ROOT}/build/dm_sync/dm_sync_test" && -x "${REPO_ROOT}/build/dm_prefix/dm_prefix_test" ]]; then
  SYNC_OUT="$("${REPO_ROOT}/build/dm_sync/dm_sync_test")"
  SYNC_LINE="$(printf '%s\n' "${SYNC_OUT}" | grep "os_sync_wait_on_address" | sed 's/^ *//' || true)"
  COND_LINE="$(printf '%s\n' "${SYNC_OUT}" | grep "pthread_cond" | sed 's/^ *//' || true)"
  PIPE_LINE="$(printf '%s\n' "${SYNC_OUT}" | grep "unix pipe" | sed 's/^ *//' || true)"
  PREFIX_LINE="$("${REPO_ROOT}/build/dm_prefix/dm_prefix_test" | grep "clonefile time" || true)"
  "${REPO_ROOT}/.venv/bin/python" -c "
import json, sys
data = {
    'NT Sync (os_sync_wait_on_address)': sys.argv[1],
    'POSIX Baseline (pthread_cond)': sys.argv[2],
    'IPC Baseline (unix pipe)': sys.argv[3],
    'APFS CoW Prefix (clonefile)': sys.argv[4],
}
with open(sys.argv[5], 'w') as f:
    json.dump(data, f, indent=2)
" "${SYNC_LINE}" "${COND_LINE}" "${PIPE_LINE}" "${PREFIX_LINE}" "${CAND_DIR}/host_metrics.json"
fi

if [[ -d "${REF_DIR}" && -f "${REF_DIR}/d3d11_results.json" ]]; then
  echo "=== RUNNING PSNR / SSIM VISUAL DIFF HARNESS ==="
  PHASE2_ARG=()
  if [[ -f "${CAND_DIR}/phase2_summary.json" ]]; then
    PHASE2_ARG=(--phase2-metrics "${CAND_DIR}/phase2_summary.json")
  fi
  PHASE3_ARG=()
  if [[ -f "${CAND_DIR}/phase3_summary.json" ]]; then
    PHASE3_ARG=(--phase3-metrics "${CAND_DIR}/phase3_summary.json")
  fi
  "${REPO_ROOT}/.venv/bin/python" "${REPO_ROOT}/tools/diff_harness.py" \
    --ref "${REF_DIR}" \
    --cand "${CAND_DIR}" \
    --save-diffs "${DIFF_DIR}" \
    --extra-metrics "${CAND_DIR}/host_metrics.json" \
    "${PHASE2_ARG[@]}" \
    "${PHASE3_ARG[@]}" \
    --json-out "${CAND_DIR}/diff_report.json" \
    --update-compat "${REPO_ROOT}/COMPATIBILITY.md"
else
  echo "WARNING: RTX 3070 reference directory ${REF_DIR} not yet present."
fi
