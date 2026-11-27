#!/usr/bin/env python3
"""Dehydrate a Wine base-prefix against signed MetalSharp-Wine.app/Contents.

Indexes all regular non-symlink files inside --wine-app-contents by (size, sha256)
and splits --base-prefix into:
  1. base-prefix-links.tsv        (rel_dst\trel_src for exact duplicates)
  2. base-prefix-delta.tar.gz     (unique regular files, symlinks, and all directories)
  3. base-prefix-fingerprint.txt  (first 16 hex chars of SHA256(links.tsv + delta.tar.gz))
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import os
import posixpath
import shutil
import stat
import sys
import tarfile
import time
from typing import Dict, List, Optional, Tuple

DEFAULT_DETERMINISTIC_MTIME = 1700000000
MIB = 1024.0 * 1024.0


def normalize_rel_posix(root: str, full_path: str) -> str:
    rel = os.path.relpath(full_path, root)
    if os.sep != "/":
        rel = rel.replace(os.sep, "/")
    rel = posixpath.normpath(rel)
    if rel in ("", ".") or rel.startswith("/") or rel.startswith("../"):
        raise ValueError(f"Invalid normalized relative path {rel!r} for {full_path!r}")
    return rel


def sha256_file(path: str) -> str:
    with open(path, "rb") as fh:
        if hasattr(hashlib, "file_digest"):
            return hashlib.file_digest(fh, "sha256").hexdigest()
        hasher = hashlib.sha256()
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
        return hasher.hexdigest()


def scan_tree(
    root: str,
) -> Tuple[
    List[Tuple[str, str, os.stat_result]],
    List[Tuple[str, str, os.stat_result, str]],
    List[Tuple[str, str, os.stat_result]],
]:
    """Scan root without following symlinks.

    Returns sorted lists of:
      - dirs:      (rel_path, full_path, lstat)
      - symlinks:  (rel_path, full_path, lstat, link_target)
      - reg_files: (rel_path, full_path, lstat)
    """
    dirs: List[Tuple[str, str, os.stat_result]] = []
    symlinks: List[Tuple[str, str, os.stat_result, str]] = []
    reg_files: List[Tuple[str, str, os.stat_result]] = []

    stack = [root]
    while stack:
        current = stack.pop()
        with os.scandir(current) as it:
            for entry in it:
                full = entry.path
                st = os.lstat(full)
                rel = normalize_rel_posix(root, full)
                mode = st.st_mode
                if stat.S_ISLNK(mode):
                    symlinks.append((rel, full, st, os.readlink(full)))
                elif stat.S_ISDIR(mode):
                    dirs.append((rel, full, st))
                    stack.append(full)
                elif stat.S_ISREG(mode):
                    reg_files.append((rel, full, st))
                else:
                    raise RuntimeError(
                        f"Unsupported special filesystem entry in {root}: {full} (mode={oct(mode)})"
                    )

    dirs.sort(key=lambda item: item[0])
    symlinks.sort(key=lambda item: item[0])
    reg_files.sort(key=lambda item: item[0])
    return dirs, symlinks, reg_files


def read_deterministic_mtime(base_prefix: str) -> int:
    ts_path = os.path.join(base_prefix, ".update-timestamp")
    if os.path.isfile(ts_path) and not os.path.islink(ts_path):
        try:
            with open(ts_path, "r", encoding="utf-8", errors="replace") as fh:
                val = int(fh.read().strip())
                if val > 0:
                    return val
        except ValueError:
            pass
    return DEFAULT_DETERMINISTIC_MTIME


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Dehydrate a Wine base-prefix against MetalSharp-Wine.app/Contents."
    )
    parser.add_argument(
        "--base-prefix",
        required=True,
        help="Path to initialized Wine base-prefix directory.",
    )
    parser.add_argument(
        "--wine-app-contents",
        required=True,
        help="Path to signed MetalSharp-Wine.app/Contents directory.",
    )
    parser.add_argument(
        "--out-dir",
        required=True,
        help="Destination directory for base-prefix-{links.tsv,delta.tar.gz,fingerprint.txt}.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    t0 = time.monotonic()
    args = parse_args(argv)

    base_prefix = os.path.abspath(args.base_prefix)
    wine_contents = os.path.abspath(args.wine_app_contents)
    out_dir = os.path.abspath(args.out_dir)

    if not os.path.isdir(base_prefix):
        print(f"error: --base-prefix directory not found: {base_prefix}", file=sys.stderr)
        return 1
    if not os.path.isfile(os.path.join(base_prefix, "system.reg")):
        print(
            f"error: --base-prefix does not contain system.reg: {base_prefix}",
            file=sys.stderr,
        )
        return 1
    if not os.path.isdir(wine_contents):
        print(
            f"error: --wine-app-contents directory not found: {wine_contents}",
            file=sys.stderr,
        )
        return 1

    max_workers = min(16, max(4, (os.cpu_count() or 4) * 2))

    # 1. Index all regular non-symlink files inside --wine-app-contents by (size, sha256)
    _, _, wine_reg_files = scan_tree(wine_contents)
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        wine_digests = list(pool.map(sha256_file, (item[1] for item in wine_reg_files)))

    wine_index: Dict[Tuple[int, str], str] = {}
    for (rel_src, _full, st), digest in zip(wine_reg_files, wine_digests):
        key = (st.st_size, digest)
        if key not in wine_index:
            wine_index[key] = rel_src

    # 2. Scan --base-prefix and partition regular files into deduplicated links vs unique delta
    prefix_dirs, prefix_symlinks, prefix_reg_files = scan_tree(base_prefix)
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        prefix_digests = list(pool.map(sha256_file, (item[1] for item in prefix_reg_files)))

    links: List[Tuple[str, str]] = []
    unique_files: List[Tuple[str, str, os.stat_result]] = []
    orig_bytes = 0
    dedup_bytes = 0
    unique_raw_bytes = 0

    for (rel_dst, full_dst, st), digest in zip(prefix_reg_files, prefix_digests):
        size = st.st_size
        orig_bytes += size
        rel_src = wine_index.get((size, digest))
        if rel_src is not None:
            links.append((rel_dst, rel_src))
            dedup_bytes += size
        else:
            unique_files.append((rel_dst, full_dst, st))
            unique_raw_bytes += size

    links.sort(key=lambda pair: (pair[0], pair[1]))

    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    links_tsv_path = os.path.join(out_dir, "base-prefix-links.tsv")
    delta_tar_gz_path = os.path.join(out_dir, "base-prefix-delta.tar.gz")
    fingerprint_path = os.path.join(out_dir, "base-prefix-fingerprint.txt")

    # 3. Write base-prefix-links.tsv (sorted, UTF-8, normalized POSIX paths, no leading slash)
    with open(links_tsv_path, "w", encoding="utf-8", newline="\n") as fh:
        for rel_dst, rel_src in links:
            if "\t" in rel_dst or "\n" in rel_dst or "\t" in rel_src or "\n" in rel_src:
                raise ValueError(f"Unsupported control character in path: {rel_dst!r} -> {rel_src!r}")
            fh.write(f"{rel_dst}\t{rel_src}\n")

    # 4. Pack unique regular files, symlinks, and all directories into base-prefix-delta.tar.gz
    det_mtime = read_deterministic_mtime(base_prefix)
    delta_entries: List[Tuple[str, str, str, os.stat_result, Optional[str]]] = []
    for rel_path, full_path, st in prefix_dirs:
        delta_entries.append((rel_path, "dir", full_path, st, None))
    for rel_path, full_path, st, link_target in prefix_symlinks:
        delta_entries.append((rel_path, "symlink", full_path, st, link_target))
    for rel_path, full_path, st in unique_files:
        delta_entries.append((rel_path, "file", full_path, st, None))

    # Lexicographical sort on normalized POSIX paths is deterministic and places parent dirs first
    delta_entries.sort(key=lambda item: item[0])

    with open(delta_tar_gz_path, "wb") as raw_fh:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=raw_fh, compresslevel=9, mtime=0
        ) as gz_fh:
            with tarfile.open(mode="w", fileobj=gz_fh, format=tarfile.PAX_FORMAT) as tf:
                for rel_path, kind, full_path, st, link_target in delta_entries:
                    ti = tarfile.TarInfo(name=rel_path)
                    ti.mode = stat.S_IMODE(st.st_mode)
                    ti.mtime = det_mtime
                    ti.uid = 0
                    ti.gid = 0
                    ti.uname = ""
                    ti.gname = ""
                    if kind == "dir":
                        ti.type = tarfile.DIRTYPE
                        ti.size = 0
                        tf.addfile(ti)
                    elif kind == "symlink":
                        assert link_target is not None
                        ti.type = tarfile.SYMTYPE
                        ti.linkname = link_target
                        ti.size = 0
                        tf.addfile(ti)
                    elif kind == "file":
                        ti.type = tarfile.REGTYPE
                        ti.size = st.st_size
                        with open(full_path, "rb") as data_fh:
                            tf.addfile(ti, fileobj=data_fh)
                    else:
                        raise AssertionError(f"Unknown entry kind: {kind}")

    # 5. Compute SHA256(base-prefix-links.tsv + base-prefix-delta.tar.gz)[:16]
    fp_hasher = hashlib.sha256()
    for artifact_path in (links_tsv_path, delta_tar_gz_path):
        with open(artifact_path, "rb") as fh:
            while True:
                chunk = fh.read(1024 * 1024)
                if not chunk:
                    break
                fp_hasher.update(chunk)
    fingerprint = fp_hasher.hexdigest()[:16]
    with open(fingerprint_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"{fingerprint}\n")

    links_bytes = os.path.getsize(links_tsv_path)
    tar_gz_bytes = os.path.getsize(delta_tar_gz_path)
    fp_bytes = os.path.getsize(fingerprint_path)
    out_total_bytes = links_bytes + tar_gz_bytes + fp_bytes
    savings_pct = ((1.0 - (out_total_bytes / orig_bytes)) * 100.0) if orig_bytes > 0 else 0.0
    elapsed = time.monotonic() - t0

    print(
        f"[DirectMetal] Dehydrated base-prefix in {elapsed:.2f}s (fingerprint: {fingerprint}):\n"
        f"  Original:      {orig_bytes / MIB:8.2f} MiB ({len(prefix_reg_files)} files, "
        f"{len(prefix_symlinks)} symlinks, {len(prefix_dirs)} dirs)\n"
        f"  Deduplicated:  {dedup_bytes / MIB:8.2f} MiB ({len(links)} files -> base-prefix-links.tsv, "
        f"{links_bytes / MIB:.2f} MiB)\n"
        f"  Delta tarball: {tar_gz_bytes / MIB:8.2f} MiB ({len(unique_files)} unique files, "
        f"{unique_raw_bytes / MIB:.2f} MiB raw, gzip -9)\n"
        f"  Final size:    {out_total_bytes / MIB:8.2f} MiB ({savings_pct:.2f}% savings)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
