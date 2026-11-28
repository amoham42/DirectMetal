#!/usr/bin/env python3
"""Deduplicate identical regular files inside a macOS bundle using atomic hardlinks.

Walks all regular non-symlink files >= 4096 bytes inside --bundle (skipping any
_CodeSignature/ directory), groups by (st_dev, st_size, st_mode & 0o7777), hashes
candidates with SHA-256, and replaces exact duplicates with atomic hardlinks
(os.link + os.replace) to the canonical file while preserving code-signature validity.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
import posixpath
import stat
import subprocess
import sys
import time
from typing import Dict, List, Optional, Set, Tuple

MIB = 1024.0 * 1024.0
DEFAULT_MIN_SIZE = 4096


def normalize_rel_posix(root: str, full_path: str) -> str:
    rel = os.path.relpath(full_path, root)
    if os.sep != "/":
        rel = rel.replace(os.sep, "/")
    return posixpath.normpath(rel)


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


def du_sk(path: str) -> int:
    proc = subprocess.run(
        ["du", "-sk", path],
        check=True,
        capture_output=True,
        text=True,
    )
    first_token = proc.stdout.strip().split()[0]
    return int(first_token)


def scan_candidate_files(
    bundle_root: str, min_size: int
) -> List[Tuple[str, str, os.stat_result]]:
    """Return sorted (rel_posix, full_path, lstat) for regular non-symlink files >= min_size."""
    candidates: List[Tuple[str, str, os.stat_result]] = []
    stack = [bundle_root]
    while stack:
        current = stack.pop()
        with os.scandir(current) as it:
            for entry in it:
                name = entry.name
                if name == "_CodeSignature":
                    continue
                full = entry.path
                st = os.lstat(full)
                mode = st.st_mode
                if stat.S_ISLNK(mode):
                    continue
                if stat.S_ISDIR(mode):
                    stack.append(full)
                elif stat.S_ISREG(mode) and st.st_size >= min_size:
                    rel = normalize_rel_posix(bundle_root, full)
                    candidates.append((rel, full, st))
    candidates.sort(key=lambda item: item[0])
    return candidates


def atomic_hardlink_replace(canon_path: str, dup_path: str, seq: int) -> None:
    dup_dir = os.path.dirname(dup_path)
    dir_st = os.lstat(dup_dir)
    dir_mode = stat.S_IMODE(dir_st.st_mode)
    made_writable = False
    tmp_path = os.path.join(dup_dir, f".dm_dedup_hl_{os.getpid()}_{seq}")
    try:
        if not (dir_mode & stat.S_IWUSR):
            os.chmod(dup_dir, dir_mode | stat.S_IWUSR)
            made_writable = True
        if os.path.lexists(tmp_path):
            os.unlink(tmp_path)
        os.link(canon_path, tmp_path)
        os.replace(tmp_path, dup_path)
    finally:
        if os.path.lexists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        if made_writable:
            os.chmod(dup_dir, dir_mode)


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deduplicate identical regular files inside a macOS bundle via atomic hardlinks."
    )
    parser.add_argument(
        "--bundle",
        required=True,
        help="Path to the target .app or bundle directory.",
    )
    parser.add_argument(
        "--min-size",
        type=int,
        default=DEFAULT_MIN_SIZE,
        help=f"Minimum regular file size in bytes to consider (default: {DEFAULT_MIN_SIZE}).",
    )
    parser.add_argument(
        "--verify-codesign",
        action="store_true",
        help="Run 'codesign --verify --strict --deep <bundle>' after deduplication.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    t0 = time.monotonic()
    args = parse_args(argv)
    bundle = os.path.abspath(args.bundle)

    if not os.path.isdir(bundle):
        print(f"error: bundle directory not found: {bundle}", file=sys.stderr)
        return 1

    du_before_kb = du_sk(bundle)
    candidates = scan_candidate_files(bundle, args.min_size)

    # Group by (st_dev, st_size, st_mode & 0o7777)
    by_meta: Dict[Tuple[int, int, int], List[Tuple[str, str, os.stat_result]]] = defaultdict(list)
    for item in candidates:
        _rel, _full, st = item
        key = (st.st_dev, st.st_size, st.st_mode & 0o7777)
        by_meta[key].append(item)

    # Only hash distinct inodes in groups that have >= 2 distinct inodes
    inodes_to_hash: Dict[Tuple[int, int], str] = {}
    collision_groups: List[Tuple[Tuple[int, int, int], List[Tuple[str, str, os.stat_result]]]] = []
    for meta_key, items in by_meta.items():
        distinct_inos: Set[Tuple[int, int]] = {(it[2].st_dev, it[2].st_ino) for it in items}
        if len(distinct_inos) < 2:
            continue
        collision_groups.append((meta_key, items))
        for _rel, full, st in items:
            ino_key = (st.st_dev, st.st_ino)
            if ino_key not in inodes_to_hash:
                inodes_to_hash[ino_key] = full

    inode_list = list(inodes_to_hash.items())
    inode_digests: Dict[Tuple[int, int], str] = {}
    if inode_list:
        max_workers = min(16, max(4, (os.cpu_count() or 4) * 2))
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            digests = list(pool.map(sha256_file, (path for _ino, path in inode_list)))
        for (ino_key, _path), digest in zip(inode_list, digests):
            inode_digests[ino_key] = digest

    files_hardlinked = 0
    bytes_saved = 0
    seq = 0

    for (dev, size, mode_perms), items in collision_groups:
        by_hash: Dict[str, List[Tuple[str, str, os.stat_result]]] = defaultdict(list)
        for item in items:
            st = item[2]
            digest = inode_digests[(st.st_dev, st.st_ino)]
            by_hash[digest].append(item)

        for _digest, dup_items in by_hash.items():
            if len(dup_items) < 2:
                continue
            _canon_rel, canon_full, canon_st = dup_items[0]
            canon_ino = (canon_st.st_dev, canon_st.st_ino)
            reclaimed_inos: Set[Tuple[int, int]] = set()
            for _dup_rel, dup_full, dup_st in dup_items[1:]:
                dup_ino = (dup_st.st_dev, dup_st.st_ino)
                if dup_ino == canon_ino:
                    continue
                seq += 1
                atomic_hardlink_replace(canon_full, dup_full, seq)
                files_hardlinked += 1
                if dup_ino not in reclaimed_inos:
                    reclaimed_inos.add(dup_ino)
                    bytes_saved += size

    du_after_kb = du_sk(bundle)
    du_saved_kb = du_before_kb - du_after_kb
    elapsed = time.monotonic() - t0

    print(
        f"[DirectMetal] Hardlink deduplication complete for {os.path.basename(bundle)} in {elapsed:.2f}s:\n"
        f"  Scanned files (>={args.min_size} B): {len(candidates)} ({len(inode_list)} unique candidate inodes hashed)\n"
        f"  Files hardlinked:     {files_hardlinked}\n"
        f"  Logical bytes saved:  {bytes_saved} bytes ({bytes_saved / MIB:.2f} MiB)\n"
        f"  Disk usage (du -sk):  {du_before_kb} KiB -> {du_after_kb} KiB "
        f"(saved {du_saved_kb} KiB / {du_saved_kb / 1024.0:.2f} MiB)"
    )

    if args.verify_codesign:
        proc = subprocess.run(["codesign", "--verify", "--strict", "--deep", bundle])
        if proc.returncode != 0:
            print(
                f"error: codesign verification failed (rc={proc.returncode}) for {bundle}",
                file=sys.stderr,
            )
            return proc.returncode
        print(f"[DirectMetal] Verified strict deep code signature: {bundle} (rc=0)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
