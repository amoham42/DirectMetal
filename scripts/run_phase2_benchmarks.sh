#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/captures/m1pro"
MFX_DIR="${OUT_DIR}/metalfx"
DM_BIN="${REPO_ROOT}/dist/DirectMetal.app/Contents/MacOS/DirectMetal"
BIN_CACHE="${REPO_ROOT}/.directmetal_cache/conformance-bin"

mkdir -p "${OUT_DIR}" "${MFX_DIR}"

echo "=== BUILDING PHASE 2 COMPONENTS ==="
cmake -S "${REPO_ROOT}/graphics/dm_metal_core" -B "${REPO_ROOT}/build/dm_metal_core" -G Ninja
cmake --build "${REPO_ROOT}/build/dm_metal_core"

cmake -S "${REPO_ROOT}/shaders/dm_shader_cache" -B "${REPO_ROOT}/build/dm_shader_cache" -G Ninja
cmake --build "${REPO_ROOT}/build/dm_shader_cache"

cmake -S "${REPO_ROOT}/upscaling/dm_metalfx_bridge" -B "${REPO_ROOT}/build/dm_metalfx_bridge" -G Ninja
cmake --build "${REPO_ROOT}/build/dm_metalfx_bridge"

echo "=== RUNNING PHASE 2 BENCHMARKS ==="
"${REPO_ROOT}/build/dm_metal_core/dm_uma_bench" --json "${OUT_DIR}/phase2_uma_bench.json"
"${REPO_ROOT}/build/dm_metal_core/dm_tbdr_bench" --json "${OUT_DIR}/phase2_tbdr_bench.json"
"${REPO_ROOT}/build/dm_shader_cache/dm_shader_cache_test" --json "${OUT_DIR}/phase2_shader_cache_bench.json"
"${REPO_ROOT}/build/dm_metalfx_bridge/dm_metalfx_bench" --out-dir "${MFX_DIR}" --json "${OUT_DIR}/phase2_metalfx_bench.json"

echo "=== MEASURING REAL MULLION D3D12 COLD VS WARM SHADER CACHE ==="
if [[ ! -x "${DM_BIN}" ]]; then
  "${REPO_ROOT}/scripts/package_app.sh"
fi
mkdir -p /tmp/dm_mullion_coldwarm
WIN_TMP="Z:\\tmp\\dm_mullion_coldwarm"
"${DM_BIN}" cache clear >/dev/null

COLD_START="$("${REPO_ROOT}/.venv/bin/python" -c "import time; print(time.perf_counter())")"
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d12_conformance.exe" --prefix conformance_d3d12 -- --out "${WIN_TMP}" --frames 50 >/dev/null
COLD_END="$("${REPO_ROOT}/.venv/bin/python" -c "import time; print(time.perf_counter())")"

WARM_START="$("${REPO_ROOT}/.venv/bin/python" -c "import time; print(time.perf_counter())")"
"${DM_BIN}" run "${BIN_CACHE}/dm_d3d12_conformance.exe" --prefix conformance_d3d12 -- --out "${WIN_TMP}" --frames 50 >/dev/null
WARM_END="$("${REPO_ROOT}/.venv/bin/python" -c "import time; print(time.perf_counter())")"

CACHE_JSON="$("${DM_BIN}" cache status)"
rm -rf /tmp/dm_mullion_coldwarm

"${REPO_ROOT}/.venv/bin/python" -c "
import json, sys
from pathlib import Path
from PIL import Image
sys.path.insert(0, '${REPO_ROOT}/tools')
from diff_harness import compute_image_metrics

out_dir = Path('${OUT_DIR}')
mfx_dir = Path('${MFX_DIR}')
uma = json.loads((out_dir / 'phase2_uma_bench.json').read_text())
tbdr = json.loads((out_dir / 'phase2_tbdr_bench.json').read_text())
sc = json.loads((out_dir / 'phase2_shader_cache_bench.json').read_text())
mfx = json.loads((out_dir / 'phase2_metalfx_bench.json').read_text())

with Image.open(mfx_dir / 'native_1080p.png') as nat_im, \
     Image.open(mfx_dir / 'metalfx_spatial_quality.png') as sq_im, \
     Image.open(mfx_dir / 'metalfx_temporal_quality.png') as tq_im:
    sq_m = compute_image_metrics(nat_im, sq_im)
    tq_m = compute_image_metrics(nat_im, tq_im)

mfx['spatial_quality_psnr_db'] = sq_m['psnr_db']
mfx['spatial_quality_ssim'] = sq_m['ssim']
mfx['temporal_quality_psnr_db'] = tq_m['psnr_db']
mfx['temporal_quality_ssim'] = tq_m['ssim']

cold_s = float('${COLD_END}') - float('${COLD_START}')
warm_s = float('${WARM_END}') - float('${WARM_START}')
cache_info = json.loads('''${CACHE_JSON}''')

summary = {
    'uma': uma,
    'tbdr': tbdr,
    'shader_cache': sc,
    'metalfx': mfx,
    'mullion_cache': {
        'cold_wall_s': cold_s,
        'warm_wall_s': warm_s,
        'speedup_x': (cold_s / warm_s) if warm_s > 0 else 0.0,
        'cache_bytes': cache_info.get('totalBytes', 0),
        'entries': cache_info.get('entries', []),
    },
}
(out_dir / 'phase2_summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
"
