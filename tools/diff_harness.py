#!/usr/bin/env python3
"""DirectMetal PSNR/SSIM Visual-Diff & Conformance Report Generator."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import sys
from typing import Any

import numpy as np
from PIL import Image


def _gaussian_kernel_1d(size: int = 11, sigma: float = 1.5) -> np.ndarray:
    coords = np.arange(size, dtype=np.float64) - (size // 2)
    kernel = np.exp(-(coords ** 2) / (2.0 * sigma * sigma))
    kernel /= kernel.sum()
    return kernel


_GAUSS_1D = _gaussian_kernel_1d(11, 1.5)


def _gaussian_blur_valid_2d(arr: np.ndarray, kernel: np.ndarray = _GAUSS_1D) -> np.ndarray:
    """Separable 2D valid convolution in pure NumPy (matches Wang-Bovik SSIM)."""
    win_h = np.lib.stride_tricks.sliding_window_view(arr, len(kernel), axis=1)
    horiz = np.tensordot(win_h, kernel, axes=([2], [0]))
    win_v = np.lib.stride_tricks.sliding_window_view(horiz, len(kernel), axis=0)
    return np.tensordot(win_v, kernel, axes=([2], [0]))


def compute_image_metrics(ref_img: Image.Image, cand_img: Image.Image) -> dict[str, Any]:
    """Compute exact PSNR (dB), Wang-Bovik SSIM, MAE, max diff, and % >1 LSB."""
    ref_rgba = np.asarray(ref_img.convert("RGBA"), dtype=np.float64)
    cand_rgba = np.asarray(cand_img.convert("RGBA"), dtype=np.float64)

    if ref_rgba.shape != cand_rgba.shape:
        raise ValueError(f"Image shape mismatch: {ref_rgba.shape} vs {cand_rgba.shape}")

    ref_rgb = ref_rgba[:, :, :3]
    cand_rgb = cand_rgba[:, :, :3]
    diff = np.abs(ref_rgb - cand_rgb)

    mse = float(np.mean((ref_rgb - cand_rgb) ** 2))
    psnr = math.inf if mse == 0.0 else 10.0 * math.log10((255.0 ** 2) / mse)
    mae = float(np.mean(diff))
    max_diff = int(np.max(diff))
    pct_gt1 = float(np.mean(np.any(diff > 1.0, axis=2)) * 100.0)

    c1 = (0.01 * 255.0) ** 2
    c2 = (0.03 * 255.0) ** 2

    ssim_channels = []
    for ch in range(3):
        x = ref_rgb[:, :, ch]
        y = cand_rgb[:, :, ch]
        mu_x = _gaussian_blur_valid_2d(x)
        mu_y = _gaussian_blur_valid_2d(y)

        mu_x2 = mu_x * mu_x
        mu_y2 = mu_y * mu_y
        mu_xy = mu_x * mu_y

        sigma_x2 = np.maximum(0.0, _gaussian_blur_valid_2d(x * x) - mu_x2)
        sigma_y2 = np.maximum(0.0, _gaussian_blur_valid_2d(y * y) - mu_y2)
        sigma_xy = _gaussian_blur_valid_2d(x * y) - mu_xy

        num = (2.0 * mu_xy + c1) * (2.0 * sigma_xy + c2)
        den = (mu_x2 + mu_y2 + c1) * (sigma_x2 + sigma_y2 + c2)
        ssim_map = num / den
        ssim_channels.append(float(np.mean(ssim_map)))

    ssim = float(sum(ssim_channels) / len(ssim_channels))
    return {
        "mse": mse,
        "psnr_db": psnr,
        "ssim": ssim,
        "mae": mae,
        "max_abs_diff": max_diff,
        "pct_pixels_gt_1lsb": pct_gt1,
    }


def save_diff_visualization(
    ref_img: Image.Image, cand_img: Image.Image, out_path: Path, amp: float = 8.0
) -> None:
    """Save side-by-side [Reference | Candidate | 8x Error Heatmap] PNG."""
    ref_rgb = np.asarray(ref_img.convert("RGB"), dtype=np.uint8)
    cand_rgb = np.asarray(cand_img.convert("RGB"), dtype=np.uint8)
    abs_diff = np.abs(ref_rgb.astype(np.float64) - cand_rgb.astype(np.float64))
    mag = np.clip(np.max(abs_diff, axis=2) * amp, 0.0, 255.0).astype(np.uint8)

    # Simple high-contrast heatmap (black -> red -> yellow -> white)
    heat = np.zeros_like(ref_rgb)
    heat[:, :, 0] = np.clip(mag * 2, 0, 255).astype(np.uint8)
    heat[:, :, 1] = np.clip((mag.astype(np.int32) - 85) * 2, 0, 255).astype(np.uint8)
    heat[:, :, 2] = np.clip((mag.astype(np.int32) - 170) * 3, 0, 255).astype(np.uint8)

    strip = np.concatenate([ref_rgb, cand_rgb, heat], axis=1)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(strip, mode="RGB").save(out_path)


def evaluate_pair(
    ref_dir: Path,
    cand_dir: Path,
    save_diffs_dir: Path | None = None,
    ssim_threshold: float = 0.995,
    psnr_threshold: float = 40.0,
) -> dict[str, Any]:
    apis: list[tuple[str, str]] = [
        ("D3D11", "d3d11_results.json"),
        ("D3D12", "d3d12_results.json"),
    ]
    report: dict[str, Any] = {
        "apis": {},
        "total_tests": 0,
        "passed_tests": 0,
        "mean_ssim": 0.0,
        "min_psnr_db": math.inf,
    }
    all_ssims: list[float] = []

    for api_name, json_name in apis:
        ref_json_path = ref_dir / json_name
        cand_json_path = cand_dir / json_name
        if not ref_json_path.exists() or not cand_json_path.exists():
            continue

        ref_data = json.loads(ref_json_path.read_text(encoding="utf-8"))
        cand_data = json.loads(cand_json_path.read_text(encoding="utf-8"))
        cand_by_name = {t["name"]: t for t in cand_data.get("tests", [])}

        test_rows: list[dict[str, Any]] = []
        api_passed = 0
        for ref_t in ref_data.get("tests", []):
            name = ref_t["name"]
            cand_t = cand_by_name.get(name)
            row: dict[str, Any] = {
                "name": name,
                "ref_status": ref_t.get("status", "missing"),
                "cand_status": cand_t.get("status", "missing") if cand_t else "missing",
                "passed": False,
                "psnr_db": 0.0,
                "ssim": 0.0,
                "mae": 0.0,
                "max_abs_diff": 255,
                "pct_pixels_gt_1lsb": 100.0,
                "checksum_match": None,
                "notes": "",
            }

            if cand_t is None:
                row["notes"] = "Missing candidate test entry"
                test_rows.append(row)
                continue

            if row["ref_status"] != "pass" or row["cand_status"] != "pass":
                row["notes"] = f"ref={row['ref_status']}, cand={row['cand_status']}: {cand_t.get('detail', '')}"

            ref_png = ref_dir / ref_t.get("png", "")
            cand_png = cand_dir / cand_t.get("png", "")
            if ref_t.get("png") and cand_t.get("png") and ref_png.exists() and cand_png.exists():
                with Image.open(ref_png) as r_im, Image.open(cand_png) as c_im:
                    metrics = compute_image_metrics(r_im, c_im)
                    row.update(metrics)
                    if save_diffs_dir is not None:
                        save_diff_visualization(r_im, c_im, save_diffs_dir / f"{name}_diff.png")
            else:
                row["notes"] = (row["notes"] + "; PNG missing").strip("; ")

            checksum_ok = True
            if "compute_checksum" in ref_t or "compute_checksum" in cand_t:
                ref_cs = ref_t.get("compute_checksum")
                cand_cs = cand_t.get("compute_checksum")
                checksum_ok = (ref_cs is not None and ref_cs == cand_cs)
                row["checksum_match"] = checksum_ok
                if not checksum_ok:
                    row["notes"] = (row["notes"] + f"; compute mismatch ({cand_cs} vs {ref_cs})").strip("; ")

            psnr_ok = math.isinf(row["psnr_db"]) or row["psnr_db"] >= psnr_threshold
            ssim_ok = row["ssim"] >= ssim_threshold
            row["passed"] = (
                row["ref_status"] == "pass"
                and row["cand_status"] == "pass"
                and checksum_ok
                and ssim_ok
                and psnr_ok
            )

            if row["passed"]:
                api_passed += 1
            all_ssims.append(row["ssim"])
            if not math.isinf(row["psnr_db"]):
                report["min_psnr_db"] = min(report["min_psnr_db"], row["psnr_db"])

            test_rows.append(row)

        report["apis"][api_name] = {
            "ref_adapter": ref_data.get("adapter", {}),
            "cand_adapter": cand_data.get("adapter", {}),
            "ref_feature_level": ref_data.get("feature_level", ""),
            "cand_feature_level": cand_data.get("feature_level", ""),
            "passed": api_passed,
            "total": len(test_rows),
            "tests": test_rows,
            "ref_benchmark": ref_data.get("benchmark", {}),
            "cand_benchmark": cand_data.get("benchmark", {}),
        }
        report["total_tests"] += len(test_rows)
        report["passed_tests"] += api_passed

    if all_ssims:
        report["mean_ssim"] = sum(all_ssims) / len(all_ssims)
    return report


def _fmt_psnr(val: float) -> str:
    return "Exact (inf)" if math.isinf(val) else f"{val:.2f} dB"


def render_compatibility_markdown(
    report: dict[str, Any],
    ref_sys: dict[str, Any] | None = None,
    cand_sys: dict[str, Any] | None = None,
    extra_metrics: dict[str, Any] | None = None,
) -> str:
    total = report["total_tests"]
    passed = report["passed_tests"]
    pct = (100.0 * passed / total) if total > 0 else 0.0
    min_psnr = "Exact (inf)" if math.isinf(report["min_psnr_db"]) else f"{report['min_psnr_db']:.2f} dB"

    lines: list[str] = [
        "# DirectMetal Compatibility & Visual-Diff Matrix",
        "",
        "Automated pixel-level accuracy (`PSNR` / `SSIM`) and frame-time comparison between **Windows x64 + NVIDIA RTX 3070** (ground-truth reference) and **Apple Silicon M1 Pro + DirectMetal (Metal 3/4)**.",
        "",
        "## Summary",
        "",
        f"- **Conformance Pass Rate:** **{passed} / {total} ({pct:.1f}%)**",
        f"- **Mean SSIM:** `{report['mean_ssim']:.6f}` (pass threshold `>= 0.995000`)",
        f"- **Minimum PSNR:** `{min_psnr}` (pass threshold `>= 40.00 dB`)",
    ]

    if ref_sys or cand_sys:
        lines.extend(["", "## Hardware & Runtime Metadata", "", "| Machine | OS | CPU | GPU / Driver | Runtime |", "| :--- | :--- | :--- | :--- | :--- |"])
        if ref_sys:
            lines.append(
                f"| Reference (Windows) | {ref_sys.get('os', 'Windows')} | {ref_sys.get('cpu', 'AMD')} | "
                f"{ref_sys.get('gpu', 'RTX 3070')} ({ref_sys.get('driver', '')}) | Native DirectX 11/12 |"
            )
        if cand_sys:
            lines.append(
                f"| Target (Mac) | {cand_sys.get('os', 'macOS')} | {cand_sys.get('cpu', 'Apple M1 Pro')} | "
                f"{cand_sys.get('gpu', 'Apple M1 Pro')} ({cand_sys.get('metal', 'Metal 4')}) | {cand_sys.get('runtime', 'DirectMetal')} |"
            )

    for api_name, api_info in report["apis"].items():
        ref_desc = api_info["ref_adapter"].get("description", "Reference GPU")
        cand_desc = api_info["cand_adapter"].get("description", "Candidate GPU")
        lines.extend([
            "",
            f"## {api_name} Conformance ({api_info['passed']} / {api_info['total']} Passed)",
            "",
            f"- **Reference Adapter:** `{ref_desc}` (Feature Level `{api_info.get('ref_feature_level', '?')}`)",
            f"- **DirectMetal Adapter:** `{cand_desc}` (Feature Level `{api_info.get('cand_feature_level', '?')}`)",
            "",
            "| Test | Result | PSNR | SSIM | Max Diff | >1 LSB % | Checksum | Notes |",
            "| :--- | :--- | ---: | ---: | ---: | ---: | :---: | :--- |",
        ])
        for row in api_info["tests"]:
            res = "PASS" if row["passed"] else "FAIL"
            cs = "-" if row["checksum_match"] is None else ("EXACT" if row["checksum_match"] else "MISMATCH")
            lines.append(
                f"| `{row['name']}` | **{res}** | {_fmt_psnr(row['psnr_db'])} | {row['ssim']:.6f} | "
                f"{row['max_abs_diff']} | {row['pct_pixels_gt_1lsb']:.2f}% | {cs} | {row['notes']} |"
            )

    lines.extend([
        "",
        "## Performance Benchmarks (RTX 3070 vs. M1 Pro)",
        "",
        "| Suite | Reference Mean (ms) | Reference FPS | Reference 1%-Low FPS | DirectMetal Mean (ms) | DirectMetal FPS | DirectMetal 1%-Low FPS | M1 Pro / RTX 3070 FPS |",
        "| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for api_name, api_info in report["apis"].items():
        rb = api_info.get("ref_benchmark", {})
        cb = api_info.get("cand_benchmark", {})
        if not rb or not cb:
            continue
        r_fps = float(rb.get("fps", 0.0))
        c_fps = float(cb.get("fps", 0.0))
        ratio = (100.0 * c_fps / r_fps) if r_fps > 0 else 0.0
        lines.append(
            f"| `{cb.get('name', api_name)}` | {rb.get('mean_ms', 0.0):.3f} | {r_fps:.1f} | {rb.get('one_percent_low_fps', 0.0):.1f} | "
            f"{cb.get('mean_ms', 0.0):.3f} | {c_fps:.1f} | {cb.get('one_percent_low_fps', 0.0):.1f} | {ratio:.1f}% |"
        )

    if extra_metrics:
        lines.extend(["", "## Native ARM64 Host Subsystem Microbenchmarks", ""])
        for k, v in extra_metrics.items():
            lines.append(f"- **{k}:** {v}")

    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="DirectMetal PSNR/SSIM diff harness")
    parser.add_argument("--ref", required=True, type=Path, help="Reference results directory (RTX 3070)")
    parser.add_argument("--cand", required=True, type=Path, help="Candidate results directory (M1 Pro)")
    parser.add_argument("--save-diffs", type=Path, default=None, help="Directory for visual diff PNGs")
    parser.add_argument("--update-compat", type=Path, default=None, help="Output Markdown path (e.g. COMPATIBILITY.md)")
    parser.add_argument("--json-out", type=Path, default=None, help="Optional structured JSON summary path")
    parser.add_argument("--extra-metrics", type=Path, default=None, help="Optional extra host metrics JSON")
    parser.add_argument("--ssim-threshold", type=float, default=0.995)
    parser.add_argument("--psnr-threshold", type=float, default=40.0)
    args = parser.parse_args(argv)

    report = evaluate_pair(
        args.ref,
        args.cand,
        save_diffs_dir=args.save_diffs,
        ssim_threshold=args.ssim_threshold,
        psnr_threshold=args.psnr_threshold,
    )

    ref_sys = json.loads((args.ref / "system_info.json").read_text()) if (args.ref / "system_info.json").exists() else None
    cand_sys = json.loads((args.cand / "system_info.json").read_text()) if (args.cand / "system_info.json").exists() else None
    extra = json.loads(args.extra_metrics.read_text()) if (args.extra_metrics and args.extra_metrics.exists()) else None

    if args.update_compat is not None:
        md = render_compatibility_markdown(report, ref_sys=ref_sys, cand_sys=cand_sys, extra_metrics=extra)
        args.update_compat.write_text(md, encoding="utf-8")

    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"Conformance: {report['passed_tests']}/{report['total_tests']} passed | Mean SSIM={report['mean_ssim']:.6f}")
    return 0 if report["total_tests"] > 0 and report["passed_tests"] == report["total_tests"] else 1


if __name__ == "__main__":
    sys.exit(main())
