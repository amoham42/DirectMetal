#!/usr/bin/env python3
"""Unit tests for tools/diff_harness.py."""

from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image

from diff_harness import compute_image_metrics, evaluate_pair, render_compatibility_markdown


class TestDiffHarness(unittest.TestCase):
    def setUp(self) -> None:
        rng = np.random.default_rng(42)
        y, x = np.mgrid[0:128, 0:128]
        r = ((x * 2) % 256).astype(np.uint8)
        g = ((y * 2) % 256).astype(np.uint8)
        b = (((x ^ y) * 2) % 256).astype(np.uint8)
        a = np.full((128, 128), 255, dtype=np.uint8)
        self.base_arr = np.stack([r, g, b, a], axis=-1)
        self.base_img = Image.fromarray(self.base_arr, mode="RGBA")
        self.rng = rng

    def test_identical_images(self) -> None:
        m = compute_image_metrics(self.base_img, self.base_img)
        self.assertEqual(m["mse"], 0.0)
        self.assertTrue(math.isinf(m["psnr_db"]))
        self.assertAlmostEqual(m["ssim"], 1.0, places=9)
        self.assertEqual(m["max_abs_diff"], 0)
        self.assertEqual(m["pct_pixels_gt_1lsb"], 0.0)

    def test_one_lsb_noise(self) -> None:
        noisy = self.base_arr.copy().astype(np.int16)
        delta = self.rng.integers(-1, 2, size=(128, 128, 3))
        noisy[:, :, :3] = np.clip(noisy[:, :, :3] + delta, 0, 255)
        noisy_img = Image.fromarray(noisy.astype(np.uint8), mode="RGBA")
        m = compute_image_metrics(self.base_img, noisy_img)
        self.assertGreater(m["psnr_db"], 47.0)
        self.assertGreater(m["ssim"], 0.990)
        self.assertLessEqual(m["max_abs_diff"], 1)
        self.assertEqual(m["pct_pixels_gt_1lsb"], 0.0)

    def test_one_lsb_rounding_bias(self) -> None:
        shifted = self.base_arr.copy().astype(np.int16)
        shifted[:, :, :3] = np.clip(shifted[:, :, :3] + 1, 0, 255)
        shifted_img = Image.fromarray(shifted.astype(np.uint8), mode="RGBA")
        m = compute_image_metrics(self.base_img, shifted_img)
        self.assertGreater(m["psnr_db"], 48.0)
        self.assertGreater(m["ssim"], 0.999)
        self.assertLessEqual(m["max_abs_diff"], 1)
        self.assertEqual(m["pct_pixels_gt_1lsb"], 0.0)

    def test_inverted_image_fails(self) -> None:
        inv = self.base_arr.copy()
        inv[:, :, :3] = 255 - inv[:, :, :3]
        inv_img = Image.fromarray(inv, mode="RGBA")
        m = compute_image_metrics(self.base_img, inv_img)
        self.assertLess(m["psnr_db"], 15.0)
        self.assertLess(m["ssim"], 0.1)

    def test_evaluate_pair_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ref_dir = root / "ref"
            cand_dir = root / "cand"
            diffs_dir = root / "diffs"
            ref_dir.mkdir()
            cand_dir.mkdir()

            self.base_img.save(ref_dir / "t_ok.png")
            self.base_img.save(cand_dir / "t_ok.png")

            inv = self.base_arr.copy()
            inv[:, :, :3] = 255 - inv[:, :, :3]
            self.base_img.save(ref_dir / "t_bad.png")
            Image.fromarray(inv, mode="RGBA").save(cand_dir / "t_bad.png")

            ref_json = {
                "api": "D3D11",
                "feature_level": "11_1",
                "adapter": {"description": "RTX 3070"},
                "tests": [
                    {"name": "t_ok", "status": "pass", "png": "t_ok.png", "compute_checksum": "0x1234"},
                    {"name": "t_bad", "status": "pass", "png": "t_bad.png"},
                ],
                "benchmark": {"name": "d3d11_bench_frame", "mean_ms": 1.0, "fps": 1000.0, "one_percent_low_fps": 800.0},
            }
            cand_json = {
                "api": "D3D11",
                "feature_level": "11_1",
                "adapter": {"description": "Apple M1 Pro"},
                "tests": [
                    {"name": "t_ok", "status": "pass", "png": "t_ok.png", "compute_checksum": "0x1234"},
                    {"name": "t_bad", "status": "pass", "png": "t_bad.png"},
                ],
                "benchmark": {"name": "d3d11_bench_frame", "mean_ms": 2.0, "fps": 500.0, "one_percent_low_fps": 420.0},
            }
            (ref_dir / "d3d11_results.json").write_text(json.dumps(ref_json))
            (cand_dir / "d3d11_results.json").write_text(json.dumps(cand_json))

            report = evaluate_pair(ref_dir, cand_dir, save_diffs_dir=diffs_dir)
            self.assertEqual(report["total_tests"], 2)
            self.assertEqual(report["passed_tests"], 1)
            self.assertTrue((diffs_dir / "t_ok_diff.png").exists())
            self.assertTrue((diffs_dir / "t_bad_diff.png").exists())

            md = render_compatibility_markdown(report)
            self.assertIn("1 / 2 (50.0%)", md)
            self.assertIn("Exact (inf)", md)
            self.assertIn("EXACT", md)


if __name__ == "__main__":
    unittest.main(verbosity=2)
