#!/usr/bin/env python3
"""Zero-dependency unittest suite for DirectMetal Python packaging & validation tools.

Covers:
  1. scripts/validate_profiles.py
  2. scripts/dedup_bundle_hardlinks.py
  3. scripts/dehydrate_base_prefix.py
"""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import ModuleType
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "scripts"
REAL_PROFILES_PATH = REPO_ROOT / "runtime" / "profiles" / "game_profiles.json"

VALIDATE_SCRIPT = SCRIPTS_DIR / "validate_profiles.py"
DEDUP_SCRIPT = SCRIPTS_DIR / "dedup_bundle_hardlinks.py"
DEHYDRATE_SCRIPT = SCRIPTS_DIR / "dehydrate_base_prefix.py"


def _load_script_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate_profiles = _load_script_module("dm_validate_profiles", VALIDATE_SCRIPT)
dedup_bundle_hardlinks = _load_script_module("dm_dedup_bundle_hardlinks", DEDUP_SCRIPT)
dehydrate_base_prefix = _load_script_module("dm_dehydrate_base_prefix", DEHYDRATE_SCRIPT)


def _run_cli(script: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _valid_profile(
    profile_id: str = "sample-game",
    *,
    status: str = "playable",
    verified_on: list[str] | None = None,
) -> dict[str, object]:
    if verified_on is None:
        verified_on = ["preset"] if status == "preset" else ["M1 Pro (macOS 26.1)"]
    return {
        "id": profile_id,
        "title": "Sample Game",
        "matchTitles": ["Sample Game"],
        "matchExeNames": ["SampleGame.exe"],
        "steamAppIds": ["123456"],
        "gogGameIds": ["654321"],
        "epicAppNames": ["SampleEpicApp"],
        "stores": ["steam", "gog", "epic"],
        "perfProfile": "balanced",
        "dx9Backend": "auto",
        "upscaleMode": "off",
        "retinaMode": True,
        "enableHUD": False,
        "enableSandbox": True,
        "status": status,
        "verifiedOn": verified_on,
        "notes": "Verified sample game profile with descriptive testing notes.",
    }


def _write_json(path: Path, payload: object) -> Path:
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path


class TestValidateProfiles(unittest.TestCase):
    """Tests for scripts/validate_profiles.py."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_profiles_doc(self, profiles: list[object], schema: str = "directmetal.game_profiles.v1") -> Path:
        return _write_json(self.tmp_dir / "profiles.json", {"schema": schema, "profiles": profiles})

    def test_real_game_profiles_passes_with_zero_errors(self) -> None:
        self.assertTrue(REAL_PROFILES_PATH.is_file(), f"Missing {REAL_PROFILES_PATH}")
        errors = validate_profiles.validate(REAL_PROFILES_PATH)
        self.assertEqual(errors, [])

    def test_real_game_profiles_cli_default_and_explicit_path(self) -> None:
        proc_default = _run_cli(VALIDATE_SCRIPT)
        self.assertEqual(proc_default.returncode, 0, msg=proc_default.stderr)
        self.assertIn("[validate_profiles] OK:", proc_default.stdout)
        self.assertEqual(proc_default.stderr, "")

        proc_explicit = _run_cli(VALIDATE_SCRIPT, str(REAL_PROFILES_PATH))
        self.assertEqual(proc_explicit.returncode, 0, msg=proc_explicit.stderr)
        self.assertIn("[validate_profiles] OK:", proc_explicit.stdout)

    def test_valid_enum_combinations_and_preset_profile(self) -> None:
        profiles = []
        idx = 0
        for perf in sorted(validate_profiles.VALID_PERF):
            for dx9 in sorted(validate_profiles.VALID_DX9):
                for upscale in sorted(validate_profiles.VALID_UPSCALE):
                    idx += 1
                    status = "preset" if idx % 3 == 0 else ("needs-steam-login" if idx % 3 == 1 else "playable")
                    p = _valid_profile(f"valid-game-{idx}", status=status)
                    p["perfProfile"] = perf
                    p["dx9Backend"] = dx9
                    p["upscaleMode"] = upscale
                    p["steamAppIds"] = [str(100000 + idx)]
                    p["gogGameIds"] = [str(200000 + idx)]
                    p["epicAppNames"] = [f"EpicApp{idx}"]
                    profiles.append(p)

        path = self._write_profiles_doc(profiles)
        self.assertEqual(validate_profiles.validate(path), [])

    def test_malformed_json_reports_error_and_nonzero_exit(self) -> None:
        bad_path = self.tmp_dir / "broken.json"
        bad_path.write_text('{"schema": "directmetal.game_profiles.v1", "profiles": [', encoding="utf-8")

        errors = validate_profiles.validate(bad_path)
        self.assertEqual(len(errors), 1)
        self.assertIn("invalid JSON", errors[0])

        proc = _run_cli(VALIDATE_SCRIPT, str(bad_path))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("invalid JSON", proc.stderr)

    def test_non_object_root_wrong_schema_and_empty_profiles(self) -> None:
        array_root = _write_json(self.tmp_dir / "array.json", [])
        self.assertIn("root must be a JSON object", validate_profiles.validate(array_root)[0])

        wrong_schema = self._write_profiles_doc([_valid_profile()], schema="directmetal.game_profiles.v99")
        errors = validate_profiles.validate(wrong_schema)
        self.assertTrue(any("unexpected schema" in e for e in errors), errors)

        empty_profiles = self._write_profiles_doc([])
        errors = validate_profiles.validate(empty_profiles)
        self.assertTrue(any("profiles must be a non-empty list" in e for e in errors), errors)

    def test_duplicate_profile_ids_and_invalid_id_format(self) -> None:
        p1 = _valid_profile("dup-game")
        p2 = _valid_profile("dup-game")
        p2["steamAppIds"] = ["222222"]
        p2["gogGameIds"] = ["333333"]
        p2["epicAppNames"] = ["OtherEpic"]
        path = self._write_profiles_doc([p1, p2])
        errors = validate_profiles.validate(path)
        self.assertTrue(any("duplicate id" in e for e in errors), errors)

        for bad_id in ("BadUpper", "-leading-hyphen", "has space", "", None):
            p = _valid_profile()
            p["id"] = bad_id
            bad_path = self._write_profiles_doc([p])
            errs = validate_profiles.validate(bad_path)
            self.assertTrue(any("invalid id" in e for e in errs), (bad_id, errs))

    def test_invalid_enum_values(self) -> None:
        cases = [
            ("perfProfile", "extreme", "invalid perfProfile"),
            ("dx9Backend", "opengl", "invalid dx9Backend"),
            ("upscaleMode", "dlss", "invalid upscaleMode"),
            ("status", "broken", "invalid status"),
            ("stores", ["steam", "origin"], "invalid stores"),
        ]
        for field, bad_value, expected_substr in cases:
            with self.subTest(field=field, bad_value=bad_value):
                p = _valid_profile()
                p[field] = bad_value
                path = self._write_profiles_doc([p])
                errors = validate_profiles.validate(path)
                self.assertTrue(any(expected_substr in e for e in errors), errors)

    def test_missing_required_fields_and_invalid_booleans(self) -> None:
        required_checks = [
            ("title", "missing non-empty title"),
            ("perfProfile", "invalid perfProfile"),
            ("dx9Backend", "invalid dx9Backend"),
            ("upscaleMode", "invalid upscaleMode"),
            ("status", "invalid status"),
            ("retinaMode", "retinaMode must be a boolean"),
            ("enableHUD", "enableHUD must be a boolean"),
            ("enableSandbox", "enableSandbox must be a boolean"),
            ("verifiedOn", "verifiedOn must be a non-empty list of strings"),
            ("notes", "notes must be a descriptive string"),
        ]
        for field, expected_substr in required_checks:
            with self.subTest(missing_field=field):
                p = _valid_profile()
                del p[field]
                path = self._write_profiles_doc([p])
                errors = validate_profiles.validate(path)
                self.assertTrue(any(expected_substr in e for e in errors), errors)

        # Integers and strings must not pass boolean validation.
        p_bool = _valid_profile()
        p_bool["retinaMode"] = 1
        p_bool["enableHUD"] = "false"
        p_bool["enableSandbox"] = None
        errors = validate_profiles.validate(self._write_profiles_doc([p_bool]))
        self.assertTrue(any("retinaMode must be a boolean" in e for e in errors), errors)
        self.assertTrue(any("enableHUD must be a boolean" in e for e in errors), errors)
        self.assertTrue(any("enableSandbox must be a boolean" in e for e in errors), errors)

        # Notes shorter than 10 chars fail.
        p_short = _valid_profile()
        p_short["notes"] = "too short"
        errors = validate_profiles.validate(self._write_profiles_doc([p_short]))
        self.assertTrue(any("notes must be a descriptive string" in e for e in errors), errors)

    def test_empty_matchers_and_matcher_hygiene(self) -> None:
        # Empty matchers
        p_empty = _valid_profile()
        for key in ("matchTitles", "matchExeNames", "steamAppIds", "gogGameIds", "epicAppNames"):
            p_empty[key] = []
        errors = validate_profiles.validate(self._write_profiles_doc([p_empty]))
        self.assertTrue(any("must define at least one matcher" in e for e in errors), errors)

        # Generic executable and missing .exe suffix
        p_exe = _valid_profile()
        p_exe["matchExeNames"] = ["Launcher.exe", "NotAnExe"]
        errors = validate_profiles.validate(self._write_profiles_doc([p_exe]))
        self.assertTrue(any("generic executable" in e for e in errors), errors)
        self.assertTrue(any("should end with .exe" in e for e in errors), errors)

        # Non-numeric steam/gog IDs and blank matcher string
        p_ids = _valid_profile()
        p_ids["steamAppIds"] = ["abc"]
        p_ids["gogGameIds"] = ["12x"]
        p_ids["matchTitles"] = ["   "]
        errors = validate_profiles.validate(self._write_profiles_doc([p_ids]))
        self.assertTrue(any("steamAppIds entry" in e and "must be numeric" in e for e in errors), errors)
        self.assertTrue(any("gogGameIds entry" in e and "must be numeric" in e for e in errors), errors)
        self.assertTrue(any("matchTitles must be a list of non-empty strings" in e for e in errors), errors)

    def test_duplicate_store_ids_across_profiles(self) -> None:
        p1 = _valid_profile("game-one")
        p2 = _valid_profile("game-two")
        p2["epicAppNames"] = ["sampleepicapp"]  # Case-insensitive collision
        errors = validate_profiles.validate(self._write_profiles_doc([p1, p2]))
        self.assertTrue(any("duplicate steamAppId" in e for e in errors), errors)
        self.assertTrue(any("duplicate gogGameId" in e for e in errors), errors)
        self.assertTrue(any("duplicate epicAppName" in e for e in errors), errors)

    def test_verified_on_status_consistency(self) -> None:
        p_preset = _valid_profile("preset-bad", status="preset", verified_on=["M1 Pro (macOS 26.1)"])
        errors = validate_profiles.validate(self._write_profiles_doc([p_preset]))
        self.assertTrue(any('untested preset must use verifiedOn=["preset"]' in e for e in errors), errors)

        p_playable = _valid_profile("playable-bad", status="playable", verified_on=["preset"])
        errors = validate_profiles.validate(self._write_profiles_doc([p_playable]))
        self.assertTrue(any("must specify tested hardware/OS in verifiedOn" in e for e in errors), errors)


class TestDedupBundleHardlinks(unittest.TestCase):
    """Tests for scripts/dedup_bundle_hardlinks.py."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self._tmp.name)
        self._chmod_restore: list[tuple[Path, int]] = []

    def tearDown(self) -> None:
        for path, mode in reversed(self._chmod_restore):
            if path.exists():
                os.chmod(path, mode)
        self._tmp.cleanup()

    def _make_realistic_bundle(self, *, include_readonly_dir: bool = False) -> tuple[Path, dict[str, Path]]:
        """Create a realistic .app directory tree with duplicates, uniques, symlinks, and _CodeSignature."""
        bundle = self.tmp_dir / "FakeDirectMetal.app"
        contents = bundle / "Contents"

        blob_a = (b"ARM64EC-DYLIB-PAYLOAD-A\x00" * 400)[:8192]  # 8192 B, 3-way duplicate (0o755)
        blob_b = (b"SHADER-CACHE-DATA-BLOCK\xff" * 300)[:6144]  # 6144 B, 2-way duplicate (0o644)
        blob_same_size_diff = (b"DIFF-CONTENT-SAME-LEN!!\x01" * 400)[:8192]  # 8192 B, unique (0o755)
        blob_unique = (b"UNIQUE-EXECUTABLE-BYTES\x7f" * 500)[:10240]  # 10240 B, unique (0o755)
        blob_small = b"small-dup-payload" * 8  # 136 B (< default 4096 B min-size)

        paths: dict[str, Path] = {
            "app_bin": contents / "MacOS" / "DirectMetal",
            "dup_a1": contents / "Frameworks" / "A.framework" / "libfoo.dylib",
            "dup_a2": contents / "PlugIns" / "nested" / "libfoo_copy.dylib",
            "dup_a3": contents / "Resources" / "runtime" / "libfoo_third.dylib",
            "dup_b1": contents / "Resources" / "assets" / "data_a.bin",
            "dup_b2": contents / "Resources" / "assets" / "sub" / "data_b.bin",
            "same_size_diff": contents / "Frameworks" / "B.framework" / "libbar.dylib",
            "perm_mismatch": contents / "Resources" / "libfoo_nonexec.dylib",
            "small_1": contents / "Resources" / "small_1.txt",
            "small_2": contents / "Resources" / "small_2.txt",
            "codesig_dup": contents / "_CodeSignature" / "CodeResources",
            "codesig_nested": contents / "Frameworks" / "A.framework" / "_CodeSignature" / "dup.dylib",
        }

        file_specs = [
            ("app_bin", blob_unique, 0o755),
            ("dup_a1", blob_a, 0o755),
            ("dup_a2", blob_a, 0o755),
            ("dup_a3", blob_a, 0o755),
            ("dup_b1", blob_b, 0o644),
            ("dup_b2", blob_b, 0o644),
            ("same_size_diff", blob_same_size_diff, 0o755),
            ("perm_mismatch", blob_a, 0o644),  # Same bytes as blob_a, different mode
            ("small_1", blob_small, 0o644),
            ("small_2", blob_small, 0o644),
            ("codesig_dup", blob_a, 0o755),  # Inside _CodeSignature: must be skipped
            ("codesig_nested", blob_a, 0o755),  # Inside nested _CodeSignature: must be skipped
        ]

        for key, data, mode in file_specs:
            target = paths[key]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.chmod(target, mode)

        # Symlinks: relative link to a duplicate, link to unique binary, and dangling link.
        sym_dup = contents / "Frameworks" / "A.framework" / "libfoo_link.dylib"
        sym_dup.symlink_to("libfoo.dylib")
        paths["sym_dup"] = sym_dup

        sym_unique = contents / "Resources" / "bin_link"
        sym_unique.symlink_to("../MacOS/DirectMetal")
        paths["sym_unique"] = sym_unique

        sym_dangling = contents / "Resources" / "dangling_link"
        sym_dangling.symlink_to("does_not_exist.dylib")
        paths["sym_dangling"] = sym_dangling

        if include_readonly_dir:
            ro_dir = contents / "PlugIns" / "readonly_dir"
            ro_dir.mkdir(parents=True, exist_ok=True)
            ro_dup = ro_dir / "libfoo_ro.dylib"
            ro_dup.write_bytes(blob_a)
            os.chmod(ro_dup, 0o755)
            os.chmod(ro_dir, 0o555)
            self._chmod_restore.append((ro_dir, 0o755))
            paths["ro_dir"] = ro_dir
            paths["ro_dup"] = ro_dup

        return bundle, paths

    @staticmethod
    def _snapshot_tree(root: Path) -> tuple[dict[str, tuple[int, int]], dict[str, bytes], dict[str, str]]:
        inodes: dict[str, tuple[int, int]] = {}
        contents: dict[str, bytes] = {}
        symlinks: dict[str, str] = {}
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for name in list(dirnames) + list(filenames):
                full = Path(dirpath) / name
                rel = full.relative_to(root).as_posix()
                st = os.lstat(full)
                inodes[rel] = (st.st_dev, st.st_ino)
                if stat.S_ISLNK(st.st_mode):
                    symlinks[rel] = os.readlink(full)
                elif stat.S_ISREG(st.st_mode):
                    contents[rel] = full.read_bytes()
        return inodes, contents, symlinks

    def test_no_dry_run_flag_and_high_min_size_leave_all_inodes_unchanged(self) -> None:
        """dedup_bundle_hardlinks.py has no --dry-run CLI mode; verify unknown --dry-run
        exits cleanly with argparse error (rc=2) and zero inode mutations, and that a
        non-matching --min-size scan exits 0 with zero inode mutations."""
        bundle, _paths = self._make_realistic_bundle()
        inodes_before, contents_before, symlinks_before = self._snapshot_tree(bundle)

        proc_dry = _run_cli(DEDUP_SCRIPT, "--bundle", str(bundle), "--dry-run")
        self.assertEqual(proc_dry.returncode, 2)
        self.assertIn("unrecognized arguments: --dry-run", proc_dry.stderr)

        inodes_after_dry, contents_after_dry, symlinks_after_dry = self._snapshot_tree(bundle)
        self.assertEqual(inodes_before, inodes_after_dry)
        self.assertEqual(contents_before, contents_after_dry)
        self.assertEqual(symlinks_before, symlinks_after_dry)

        # Valid no-op scan via --min-size larger than any file in the bundle
        proc_noop = _run_cli(DEDUP_SCRIPT, "--bundle", str(bundle), "--min-size", "1048576")
        self.assertEqual(proc_noop.returncode, 0, msg=proc_noop.stderr)
        self.assertIn("Files hardlinked:     0", proc_noop.stdout)
        self.assertIn("Logical bytes saved:  0 bytes", proc_noop.stdout)

        inodes_after_noop, contents_after_noop, symlinks_after_noop = self._snapshot_tree(bundle)
        self.assertEqual(inodes_before, inodes_after_noop)
        self.assertEqual(contents_before, contents_after_noop)
        self.assertEqual(symlinks_before, symlinks_after_noop)

    def test_dedup_real_run_hardlinks_duplicates_preserves_contents_and_reports_savings(self) -> None:
        bundle, paths = self._make_realistic_bundle(include_readonly_dir=True)
        inodes_before, contents_before, symlinks_before = self._snapshot_tree(bundle)

        proc = _run_cli(DEDUP_SCRIPT, "--bundle", str(bundle))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)

        # Group A: 4 copies (dup_a1, dup_a2, ro_dup, dup_a3) -> 3 hardlinked (3 * 8192 = 24576 B)
        # Group B: 2 copies (dup_b1, dup_b2) -> 1 hardlinked (1 * 6144 = 6144 B)
        expected_hardlinked = 4
        expected_bytes_saved = 3 * 8192 + 6144  # 30720 bytes
        self.assertIn(f"Files hardlinked:     {expected_hardlinked}", proc.stdout)
        self.assertIn(f"Logical bytes saved:  {expected_bytes_saved} bytes", proc.stdout)

        # Canonical file for Group A is lexicographically first: Contents/Frameworks/A.framework/libfoo.dylib
        canon_a_st = os.lstat(paths["dup_a1"])
        canon_a_id = (canon_a_st.st_dev, canon_a_st.st_ino)
        self.assertEqual(canon_a_st.st_nlink, 4)
        for key in ("dup_a2", "dup_a3", "ro_dup"):
            st = os.lstat(paths[key])
            self.assertEqual((st.st_dev, st.st_ino), canon_a_id, f"{key} was not hardlinked to dup_a1")

        # Canonical file for Group B is Contents/Resources/assets/data_a.bin
        canon_b_st = os.lstat(paths["dup_b1"])
        canon_b_id = (canon_b_st.st_dev, canon_b_st.st_ino)
        self.assertEqual(canon_b_st.st_nlink, 2)
        dup_b2_st = os.lstat(paths["dup_b2"])
        self.assertEqual((dup_b2_st.st_dev, dup_b2_st.st_ino), canon_b_id)

        # Untouched files keep their original distinct inodes
        for key in ("app_bin", "same_size_diff", "perm_mismatch", "small_1", "small_2", "codesig_dup", "codesig_nested"):
            rel = paths[key].relative_to(bundle).as_posix()
            st = os.lstat(paths[key])
            self.assertEqual((st.st_dev, st.st_ino), inodes_before[rel], f"{key} inode unexpectedly changed")
            self.assertEqual(st.st_nlink, 1, f"{key} should not be hardlinked")

        # Read-only directory permissions restored to 0o555
        ro_dir_mode = stat.S_IMODE(os.lstat(paths["ro_dir"]).st_mode)
        self.assertEqual(ro_dir_mode, 0o555)

        # Symlinks untouched and all regular file contents bit-for-bit identical; no temp files left behind
        _inodes_after, contents_after, symlinks_after = self._snapshot_tree(bundle)
        self.assertEqual(symlinks_before, symlinks_after)
        self.assertEqual(contents_before, contents_after)
        for key in ("sym_dup", "sym_unique", "sym_dangling"):
            self.assertTrue(os.path.islink(paths[key]))
        leftover_temps = [p for p in bundle.rglob(".dm_dedup_hl_*")]
        self.assertEqual(leftover_temps, [])

        # Re-running is idempotent: 0 files hardlinked, 0 bytes saved, identical inodes
        inodes_mid, _, _ = self._snapshot_tree(bundle)
        proc_again = _run_cli(DEDUP_SCRIPT, "--bundle", str(bundle))
        self.assertEqual(proc_again.returncode, 0, msg=proc_again.stderr)
        self.assertIn("Files hardlinked:     0", proc_again.stdout)
        self.assertIn("Logical bytes saved:  0 bytes", proc_again.stdout)
        inodes_end, _, _ = self._snapshot_tree(bundle)
        self.assertEqual(inodes_mid, inodes_end)

    def test_custom_min_size_deduplicates_small_files(self) -> None:
        bundle, paths = self._make_realistic_bundle()
        proc = _run_cli(DEDUP_SCRIPT, "--bundle", str(bundle), "--min-size", "64")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)

        st1 = os.lstat(paths["small_1"])
        st2 = os.lstat(paths["small_2"])
        self.assertEqual((st1.st_dev, st1.st_ino), (st2.st_dev, st2.st_ino))
        self.assertEqual(st1.st_nlink, 2)

    def test_missing_bundle_returns_error(self) -> None:
        missing = self.tmp_dir / "DoesNotExist.app"
        proc = _run_cli(DEDUP_SCRIPT, "--bundle", str(missing))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("bundle directory not found", proc.stderr)

    def test_verify_codesign_success_and_failure_paths(self) -> None:
        bundle, _paths = self._make_realistic_bundle()
        real_run = subprocess.run

        def _fake_run_ok(cmd: list[str], *args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            if cmd and cmd[0] == "codesign":
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
            return real_run(cmd, *args, **kwargs)  # type: ignore[arg-type]

        def _fake_run_fail(cmd: list[str], *args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            if cmd and cmd[0] == "codesign":
                return subprocess.CompletedProcess(cmd, 3, stdout="", stderr="code object is not signed")
            return real_run(cmd, *args, **kwargs)  # type: ignore[arg-type]

        with mock.patch.object(dedup_bundle_hardlinks.subprocess, "run", side_effect=_fake_run_ok):
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = dedup_bundle_hardlinks.main(["--bundle", str(bundle), "--verify-codesign"])
            self.assertEqual(rc, 0)
            self.assertIn("Verified strict deep code signature", out.getvalue())

        with mock.patch.object(dedup_bundle_hardlinks.subprocess, "run", side_effect=_fake_run_fail):
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = dedup_bundle_hardlinks.main(["--bundle", str(bundle), "--verify-codesign"])
            self.assertEqual(rc, 3)
            self.assertIn("codesign verification failed (rc=3)", err.getvalue())


class TestDehydrateBasePrefix(unittest.TestCase):
    """Tests for scripts/dehydrate_base_prefix.py."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _build_fake_runtime_and_prefix(self) -> tuple[Path, Path]:
        wine_contents = self.tmp_dir / "MetalSharp-Wine.app" / "Contents"
        base_prefix = self.tmp_dir / "base-prefix"

        # Shared DLL blobs inside fake Wine runtime
        ntdll_bytes = b"MZ-NTDLL-SHARED-BINARY\x00" * 200
        kernel32_bytes = b"MZ-KERNEL32-SHARED-BIN\x00" * 180
        symlink_only_blob = b"ONLY-REACHABLE-VIA-SYMLINK-IN-WINE" * 40

        wine_files = {
            "SharedSupport/wine/lib/wine/aarch64-windows/ntdll.dll": (ntdll_bytes, 0o755),
            # Second identical copy in Wine runtime: lexicographically earlier path should win
            "SharedSupport/wine/lib/wine/x86_64-windows/ntdll.dll": (ntdll_bytes, 0o755),
            "SharedSupport/wine/lib/wine/x86_64-windows/kernel32.dll": (kernel32_bytes, 0o755),
        }
        for rel, (data, mode) in wine_files.items():
            p = wine_contents / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            os.chmod(p, mode)

        # Put a blob outside wine_contents and symlink to it from inside wine_contents;
        # dehydrate_base_prefix must NOT follow/index symlinks inside --wine-app-contents.
        outside_blob = self.tmp_dir / "outside_only.dll"
        outside_blob.write_bytes(symlink_only_blob)
        wine_sym = wine_contents / "SharedSupport" / "wine" / "symlinked.dll"
        wine_sym.parent.mkdir(parents=True, exist_ok=True)
        wine_sym.symlink_to(outside_blob)

        # Build fake Wine base-prefix
        prefix_files = {
            "system.reg": (b"WINE REGISTRY Version 2\n[Software\\DirectMetal]\n", 0o644),
            "user.reg": (b"WINE REGISTRY Version 2\n[Control Panel]\n", 0o644),
            ".update-timestamp": (b"1712345678\n", 0o644),
            "drive_c/windows/system32/ntdll.dll": (ntdll_bytes, 0o755),
            "drive_c/windows/system32/kernel32.dll": (kernel32_bytes, 0o755),
            "drive_c/windows/system32/unique_custom.dll": (b"UNIQUE-PREFIX-DLL-CONTENT", 0o755),
            # Matches outside_blob, which is only symlinked in wine_contents -> must stay in delta!
            "drive_c/windows/system32/symlink_target.dll": (symlink_only_blob, 0o644),
        }
        for rel, (data, mode) in prefix_files.items():
            p = base_prefix / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            os.chmod(p, mode)

        # Empty directory to verify directory preservation in delta tar
        (base_prefix / "drive_c" / "users" / "crossover" / "Desktop").mkdir(parents=True, exist_ok=True)

        # Symlinks inside prefix (relative and dangling)
        dosdevices = base_prefix / "dosdevices"
        dosdevices.mkdir(parents=True, exist_ok=True)
        (dosdevices / "c:").symlink_to("../drive_c")
        (dosdevices / "z:").symlink_to("/nonexistent/mount/point")

        return wine_contents, base_prefix

    def test_dehydrate_generates_links_delta_fingerprint_and_rehydrates_losslessly(self) -> None:
        wine_contents, base_prefix = self._build_fake_runtime_and_prefix()
        out_dir = self.tmp_dir / "dehydrated-out"

        proc = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(base_prefix),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir),
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("[DirectMetal] Dehydrated base-prefix", proc.stdout)

        links_tsv = out_dir / "base-prefix-links.tsv"
        delta_tar = out_dir / "base-prefix-delta.tar.gz"
        fingerprint_txt = out_dir / "base-prefix-fingerprint.txt"
        self.assertEqual(
            sorted(p.name for p in out_dir.iterdir()),
            ["base-prefix-delta.tar.gz", "base-prefix-fingerprint.txt", "base-prefix-links.tsv"],
        )

        # 1. Verify base-prefix-links.tsv exact sorted entries & lexicographical tie-breaking
        link_lines = links_tsv.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            link_lines,
            [
                "drive_c/windows/system32/kernel32.dll\tSharedSupport/wine/lib/wine/x86_64-windows/kernel32.dll",
                "drive_c/windows/system32/ntdll.dll\tSharedSupport/wine/lib/wine/aarch64-windows/ntdll.dll",
            ],
        )

        # 2. Verify base-prefix-delta.tar.gz contents, metadata, and exclusion of deduplicated files
        with tarfile.open(delta_tar, mode="r:gz") as tf:
            members = tf.getmembers()
            names = [m.name for m in members]
            self.assertEqual(names, sorted(names), "Delta tarball entries must be lexicographically sorted")

            # Deduplicated files must NOT be in the delta tarball
            self.assertNotIn("drive_c/windows/system32/ntdll.dll", names)
            self.assertNotIn("drive_c/windows/system32/kernel32.dll", names)

            # Unique files, symlinks, and empty dirs MUST be present
            by_name = {m.name: m for m in members}
            for expected_file in (
                ".update-timestamp",
                "system.reg",
                "user.reg",
                "drive_c/windows/system32/unique_custom.dll",
                "drive_c/windows/system32/symlink_target.dll",
            ):
                self.assertIn(expected_file, by_name)
                self.assertTrue(by_name[expected_file].isfile())

            self.assertIn("drive_c/users/crossover/Desktop", by_name)
            self.assertTrue(by_name["drive_c/users/crossover/Desktop"].isdir())

            self.assertTrue(by_name["dosdevices/c:"].issym())
            self.assertEqual(by_name["dosdevices/c:"].linkname, "../drive_c")
            self.assertTrue(by_name["dosdevices/z:"].issym())
            self.assertEqual(by_name["dosdevices/z:"].linkname, "/nonexistent/mount/point")

            # Deterministic metadata (mtime from .update-timestamp, uid/gid/uname/gname normalized)
            for m in members:
                self.assertEqual(m.mtime, 1712345678)
                self.assertEqual(m.uid, 0)
                self.assertEqual(m.gid, 0)
                self.assertEqual(m.uname, "")
                self.assertEqual(m.gname, "")

            self.assertEqual(by_name["drive_c/windows/system32/unique_custom.dll"].mode, 0o755)
            self.assertEqual(by_name["system.reg"].mode, 0o644)

        # 3. Verify fingerprint matches SHA256(links.tsv + delta.tar.gz)[:16]
        fp_raw = fingerprint_txt.read_text(encoding="utf-8")
        self.assertTrue(re.fullmatch(r"[0-9a-f]{16}\n", fp_raw), f"Unexpected fingerprint format: {fp_raw!r}")
        expected_fp = hashlib.sha256(links_tsv.read_bytes() + delta_tar.read_bytes()).hexdigest()[:16]
        self.assertEqual(fp_raw.strip(), expected_fp)

        # 4. Lossless rehydration round-trip check inside TemporaryDirectory
        rehydrated = self.tmp_dir / "rehydrated-prefix"
        rehydrated.mkdir()
        with tarfile.open(delta_tar, mode="r:gz") as tf:
            for member in tf.getmembers():
                dest = rehydrated / member.name
                if member.isdir():
                    dest.mkdir(parents=True, exist_ok=True)
                elif member.issym():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.symlink_to(member.linkname)
                elif member.isfile():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    extracted = tf.extractfile(member)
                    assert extracted is not None
                    dest.write_bytes(extracted.read())
                    os.chmod(dest, member.mode)
        for line in link_lines:
            rel_dst, rel_src = line.split("\t")
            os.link(wine_contents / rel_src, rehydrated / rel_dst)

        # Compare original prefix and rehydrated prefix entry-by-entry
        orig_entries = self._collect_prefix_state(base_prefix)
        rehyd_entries = self._collect_prefix_state(rehydrated)
        self.assertEqual(orig_entries, rehyd_entries)

    @staticmethod
    def _collect_prefix_state(root: Path) -> dict[str, tuple[str, object]]:
        state: dict[str, tuple[str, object]] = {}
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for name in list(dirnames) + list(filenames):
                full = Path(dirpath) / name
                rel = full.relative_to(root).as_posix()
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    state[rel] = ("symlink", os.readlink(full))
                elif stat.S_ISDIR(st.st_mode):
                    state[rel] = ("dir", None)
                elif stat.S_ISREG(st.st_mode):
                    state[rel] = ("file", (stat.S_IMODE(st.st_mode), full.read_bytes()))
        return state

    def test_dehydrate_is_byte_deterministic_and_cleans_existing_out_dir(self) -> None:
        wine_contents, base_prefix = self._build_fake_runtime_and_prefix()
        out_dir_1 = self.tmp_dir / "out1"
        out_dir_2 = self.tmp_dir / "out2"
        out_dir_2.mkdir()
        stale_file = out_dir_2 / "stale.tmp"
        stale_file.write_text("should be removed", encoding="utf-8")

        proc1 = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(base_prefix),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir_1),
        )
        self.assertEqual(proc1.returncode, 0, msg=proc1.stderr)

        # Mutate on-disk mtime of a prefix file between runs; output must remain byte-identical
        os.utime(base_prefix / "system.reg", (1700000100, 1700000100))

        proc2 = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(base_prefix),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir_2),
        )
        self.assertEqual(proc2.returncode, 0, msg=proc2.stderr)
        self.assertFalse(stale_file.exists())

        for fname in ("base-prefix-links.tsv", "base-prefix-delta.tar.gz", "base-prefix-fingerprint.txt"):
            self.assertEqual(
                (out_dir_1 / fname).read_bytes(),
                (out_dir_2 / fname).read_bytes(),
                f"{fname} was not byte-for-byte deterministic",
            )

        # Also check gzip header mtime is 0 (bytes 4..8 in RFC 1952 header)
        gz_header = (out_dir_1 / "base-prefix-delta.tar.gz").read_bytes()[:10]
        self.assertEqual(gz_header[:2], b"\x1f\x8b")
        self.assertEqual(gz_header[4:8], b"\x00\x00\x00\x00")
        with gzip.open(out_dir_1 / "base-prefix-delta.tar.gz", "rb") as gz_fh:
            self.assertGreater(len(gz_fh.read()), 0)

    def test_update_timestamp_fallback_to_default_mtime(self) -> None:
        wine_contents, base_prefix = self._build_fake_runtime_and_prefix()
        ts_path = base_prefix / ".update-timestamp"

        # Invalid numeric content falls back to DEFAULT_DETERMINISTIC_MTIME
        ts_path.write_text("not-a-timestamp\n", encoding="utf-8")
        self.assertEqual(
            dehydrate_base_prefix.read_deterministic_mtime(str(base_prefix)),
            dehydrate_base_prefix.DEFAULT_DETERMINISTIC_MTIME,
        )

        # Missing file falls back to DEFAULT_DETERMINISTIC_MTIME
        ts_path.unlink()
        self.assertEqual(
            dehydrate_base_prefix.read_deterministic_mtime(str(base_prefix)),
            dehydrate_base_prefix.DEFAULT_DETERMINISTIC_MTIME,
        )

        out_dir = self.tmp_dir / "out-default-mtime"
        proc = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(base_prefix),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir),
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        with tarfile.open(out_dir / "base-prefix-delta.tar.gz", mode="r:gz") as tf:
            for member in tf.getmembers():
                self.assertEqual(member.mtime, dehydrate_base_prefix.DEFAULT_DETERMINISTIC_MTIME)

    def test_error_handling_for_missing_inputs_and_missing_system_reg(self) -> None:
        wine_contents, base_prefix = self._build_fake_runtime_and_prefix()
        out_dir = self.tmp_dir / "out-err"

        # Missing --base-prefix
        proc = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(self.tmp_dir / "missing-prefix"),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir),
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("--base-prefix directory not found", proc.stderr)

        # Missing system.reg inside --base-prefix
        empty_prefix = self.tmp_dir / "empty-prefix"
        empty_prefix.mkdir()
        proc = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(empty_prefix),
            "--wine-app-contents",
            str(wine_contents),
            "--out-dir",
            str(out_dir),
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("does not contain system.reg", proc.stderr)

        # Missing --wine-app-contents
        proc = _run_cli(
            DEHYDRATE_SCRIPT,
            "--base-prefix",
            str(base_prefix),
            "--wine-app-contents",
            str(self.tmp_dir / "missing-wine"),
            "--out-dir",
            str(out_dir),
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("--wine-app-contents directory not found", proc.stderr)

    def test_scan_tree_rejects_special_filesystem_entries(self) -> None:
        fifo_dir = self.tmp_dir / "with-fifo"
        fifo_dir.mkdir()
        os.mkfifo(fifo_dir / "pipe")
        with self.assertRaisesRegex(RuntimeError, "Unsupported special filesystem entry"):
            dehydrate_base_prefix.scan_tree(str(fifo_dir))


class TestPublishShaderCache(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="dm_publish_cache_test_")
        self.tmp_dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_export_local_honors_env_root_and_builds_valid_index(self) -> None:
        script = REPO_ROOT / "scripts" / "publish_shader_cache.sh"
        cache_root = self.tmp_dir / "local_shaders"
        out_dir = self.tmp_dir / "published"
        entry_dir = cache_root / "abcdef123456_1700000000_65536_apple9_25G241"
        entry_dir.mkdir(parents=True)
        (entry_dir / "pso_0.metallib").write_bytes(b"METAL_BINARY_ARCHIVE_TEST_0")
        (entry_dir / "pso_1.metallib").write_bytes(b"METAL_BINARY_ARCHIVE_TEST_1")

        env = os.environ.copy()
        env["DIRECTMETAL_SHADER_CACHE_ROOT"] = str(cache_root)
        proc = subprocess.run(
            [
                "bash",
                str(script),
                "--dir",
                str(out_dir),
                "--export-local",
                "--base-url",
                "https://cdn.example.test/v1.0.1",
                "--dry-run",
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=f"stderr={proc.stderr}\nstdout={proc.stdout}")

        index_path = out_dir / "index.json"
        self.assertTrue(index_path.is_file(), "index.json must be created")
        index_data = json.loads(index_path.read_text(encoding="utf-8"))
        self.assertEqual(index_data["schema"], "directmetal.shadercache.index.v1")
        self.assertEqual(len(index_data["entries"]), 1)

        entry = index_data["entries"][0]
        self.assertEqual(entry["build_hash"], "abcdef123456_1700000000_65536")
        self.assertEqual(entry["gpu_family"], "Apple9")
        self.assertEqual(entry["macos_build"], "25G241")
        self.assertEqual(entry["file_count"], 2)
        self.assertTrue(entry["archive_url"].startswith("https://cdn.example.test/v1.0.1/"))

        archive_path = out_dir / f"{entry_dir.name}.dmcache.tar.gz"
        self.assertTrue(archive_path.is_file(), "exported .dmcache.tar.gz must exist")
        actual_sha = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        self.assertEqual(entry["archive_sha256"], actual_sha)


if __name__ == "__main__":
    unittest.main()
