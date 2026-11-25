#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DM_BIN="${REPO_ROOT}/dist/DirectMetal.app/Contents/MacOS/DirectMetal"
BIN_CACHE="${REPO_ROOT}/.directmetal_cache/conformance-bin"
CAND_ARM="${REPO_ROOT}/captures/m1pro_arm64ec"
CAND_NOTSO="/tmp/dm_arm64ec_notso"
REF_DIR="${REPO_ROOT}/tests/reference/rtx3070"
ROSETTA_DIR="${REPO_ROOT}/captures/m1pro"

if [[ ! -d "${REPO_ROOT}/build/runtime-arm64ec/base-prefix" ]]; then
  "${REPO_ROOT}/scripts/setup_runtime_arm64ec.sh"
fi

if [[ ! -x "${DM_BIN}" ]]; then
  "${REPO_ROOT}/scripts/package_app.sh"
fi

mkdir -p "${ROSETTA_DIR}" "${CAND_ARM}" "${CAND_NOTSO}"

echo "=== BUILDING & RUNNING ARM64 HOST I/O PROBE ==="
cmake -S "${REPO_ROOT}/runtime/dm_host_io" -B "${REPO_ROOT}/build/dm_host_io" -G Ninja >/dev/null
cmake --build "${REPO_ROOT}/build/dm_host_io" >/dev/null
"${REPO_ROOT}/build/dm_host_io/dm_host_io_test" --json "${ROSETTA_DIR}/phase3_host_io.json"

if [[ ! -f "${BIN_CACHE}/dm_d3d11_conformance.exe" || ! -f "${BIN_CACHE}/dm_d3d12_conformance.exe" ]]; then
  gh release download conformance-bins-v0.1 -R amoham42/DirectMetal -D "${BIN_CACHE}" --clobber
fi

WIN_ARM="Z:${CAND_ARM//\//\\}"
WIN_NOTSO="Z:\\tmp\\dm_arm64ec_notso"

echo "=== RUNNING D3D11 + D3D12 ON NATIVE ARM64EC + FEX (TSO=1) ==="
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d11_conformance.exe" \
  --prefix conformance_d3d11_arm64ec --engine arm64ec --fex-tso on --reset-prefix \
  -- --out "${WIN_ARM}" --frames 200 || true

"${DM_BIN}" run "${BIN_CACHE}/dm_d3d12_conformance.exe" \
  --prefix conformance_d3d12_arm64ec --engine arm64ec --fex-tso on --reset-prefix \
  -- --out "${WIN_ARM}" --frames 200 || true

echo "=== RUNNING D3D11 + D3D12 ON NATIVE ARM64EC + FEX (TSO=0) ==="
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d11_conformance.exe" \
  --prefix conformance_d3d11_arm64ec --engine arm64ec --fex-tso off \
  -- --out "${WIN_NOTSO}" --frames 200 || true

"${DM_BIN}" run "${BIN_CACHE}/dm_d3d12_conformance.exe" \
  --prefix conformance_d3d12_arm64ec --engine arm64ec --fex-tso off \
  -- --out "${WIN_NOTSO}" --frames 200 || true

"${REPO_ROOT}/.venv/bin/python" "${REPO_ROOT}/tools/diff_harness.py" \
  --ref "${REF_DIR}" \
  --cand "${CAND_ARM}" \
  --json-out "${CAND_ARM}/diff_report.json" || true

"${REPO_ROOT}/.venv/bin/python" -c "
import json, math
from pathlib import Path

ref_dir = Path('${REF_DIR}')
ros_dir = Path('${ROSETTA_DIR}')
arm_dir = Path('${CAND_ARM}')
notso_dir = Path('${CAND_NOTSO}')

diff_rep = json.loads((arm_dir / 'diff_report.json').read_text()) if (arm_dir / 'diff_report.json').exists() else {}
host_io = json.loads((ros_dir / 'phase3_host_io.json').read_text()) if (ros_dir / 'phase3_host_io.json').exists() else {}

def load_bench(d, name):
    p = d / f'{name}_results.json'
    return json.loads(p.read_text()).get('benchmark', {}) if p.exists() else {}

suites = {}
for api in ['d3d11', 'd3d12']:
    rb = load_bench(ref_dir, api)
    ros = load_bench(ros_dir, api)
    tso1 = load_bench(arm_dir, api)
    tso0 = load_bench(notso_dir, api)
    suites[api] = {
        'rtx3070': rb,
        'rosetta2': ros,
        'arm64ec_tso1': tso1,
        'arm64ec_tso0': tso0,
    }

min_psnr = diff_rep.get('min_psnr_db', 0.0)
summary = {
    'passed_tests': diff_rep.get('passed_tests', 0),
    'total_tests': diff_rep.get('total_tests', 0),
    'mean_ssim': diff_rep.get('mean_ssim', 0.0),
    'min_psnr_db': None if isinstance(min_psnr, float) and math.isinf(min_psnr) else min_psnr,
    'host_io': host_io,
    'suites': suites,
}
(ros_dir / 'phase3_summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
"

rm -rf "${CAND_NOTSO}"
