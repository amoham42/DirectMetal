#!/usr/bin/env bash
set -euo pipefail

# DirectMetal Cloud Shader Cache Publisher
# Scans a directory of .dmcache.tar.gz archives (or exports local shader cache entries),
# verifies each archive's directmetal.shadercache.v1 manifest.json, computes outer SHA-256
# digests, writes index.json (directmetal.shadercache.index.v1), and optionally uploads
# to GitHub Releases (--gh-release <tag>) or any static S3/R2/Cloudflare/HTTP bucket.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_DIR=""
OUTPUT_INDEX=""
BASE_URL=""
GH_RELEASE_TAG=""
GH_REPO=""
EXPORT_LOCAL=0
LOCAL_CACHE_ROOT="${DIRECTMETAL_SHADER_CACHE_DIR:-${HOME}/Library/Caches/DirectMetal/Shaders}"
DEFAULT_BUILD_HASH=""
DEFAULT_TITLE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|-d)
      TARGET_DIR="$2"
      shift 2
      ;;
    --output|-o)
      OUTPUT_INDEX="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --gh-release)
      GH_RELEASE_TAG="$2"
      shift 2
      ;;
    --repo)
      GH_REPO="$2"
      shift 2
      ;;
    --export-local)
      EXPORT_LOCAL=1
      shift
      ;;
    --cache-root)
      LOCAL_CACHE_ROOT="$2"
      shift 2
      ;;
    --build-hash)
      DEFAULT_BUILD_HASH="$2"
      shift 2
      ;;
    --title)
      DEFAULT_TITLE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--dir <archives_dir>] [options]

Scans .dmcache.tar.gz shader cache archives (or exports local shader cache entries),
validates each archive's manifest.json, computes SHA-256 digests, and writes index.json
(schema: directmetal.shadercache.index.v1) for static CDN / S3 / R2 / GitHub Releases.

Options:
  --dir, -d <dir>          Directory of .dmcache.tar.gz archives (default: dist/shader-cache)
  --output, -o <path>      Output index.json path (default: <dir>/index.json)
  --export-local           Export local shader cache entries into <dir> before indexing
  --cache-root <dir>       Override local shader cache root (default: ~/Library/Caches/DirectMetal/Shaders)
  --base-url <url>         Public URL prefix for archive_url entries (default: relative filename or GitHub Release URL)
  --build-hash <hash>      Fallback PE buildHash if an archive does not encode one in its entry folder/name
  --title <title>          Fallback human-readable game title
  --gh-release <tag>       Upload index.json + .dmcache.tar.gz archives via 'gh release upload <tag> --clobber'
  --repo <owner/repo>      GitHub repository for --gh-release (auto-detected from git remote if omitted)
  --dry-run                Generate index.json without running 'gh release upload'
  -h, --help               Show this help message
EOF
      exit 0
      ;;
    -*)
      echo "error: unknown option '$1' (pass --help for usage)" >&2
      exit 1
      ;;
    *)
      if [[ -z "${TARGET_DIR}" ]]; then
        TARGET_DIR="$1"
        shift
      else
        echo "error: unexpected positional argument '$1'" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "${TARGET_DIR}" ]]; then
  TARGET_DIR="${REPO_ROOT}/dist/shader-cache"
fi

mkdir -p "${TARGET_DIR}"
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"

if [[ -z "${OUTPUT_INDEX}" ]]; then
  OUTPUT_INDEX="${TARGET_DIR}/index.json"
fi

# Resolve GitHub Release base URL automatically when --gh-release is used without --base-url
if [[ -n "${GH_RELEASE_TAG}" && -z "${BASE_URL}" ]]; then
  RESOLVED_REPO="${GH_REPO}"
  if [[ -z "${RESOLVED_REPO}" ]] && command -v gh >/dev/null 2>&1; then
    RESOLVED_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "${RESOLVED_REPO}" ]]; then
    ORIGIN_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
    if [[ "${ORIGIN_URL}" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
      RESOLVED_REPO="${BASH_REMATCH[1]}"
    fi
  fi
  if [[ -n "${RESOLVED_REPO}" ]]; then
    GH_REPO="${RESOLVED_REPO}"
    BASE_URL="https://github.com/${RESOLVED_REPO}/releases/download/${GH_RELEASE_TAG}"
  fi
fi

python3 - "${TARGET_DIR}" "${OUTPUT_INDEX}" "${BASE_URL}" "${EXPORT_LOCAL}" "${LOCAL_CACHE_ROOT}" "${DEFAULT_BUILD_HASH}" "${DEFAULT_TITLE}" <<'PY'
import datetime
import hashlib
import io
import json
import os
import platform
import re
import subprocess
import sys
import tarfile
from pathlib import Path

target_dir = Path(sys.argv[1]).resolve()
output_index = Path(sys.argv[2]).resolve()
base_url = sys.argv[3].rstrip("/")
export_local = sys.argv[4] == "1"
local_cache_root = Path(sys.argv[5]).expanduser()
default_build_hash = sys.argv[6].strip()
default_title = sys.argv[7].strip()


def utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def detect_host_metadata():
    try:
        macos_build = subprocess.check_output(["sysctl", "-n", "kern.osversion"], text=True).strip()
    except Exception:
        macos_build = "unknown"
    macos_ver = platform.mac_ver()[0] or "15.0"
    try:
        sp = subprocess.check_output(["system_profiler", "SPDisplaysDataType", "-json"], text=True, stderr=subprocess.DEVNULL)
        data = json.loads(sp)
        displays = data.get("SPDisplaysDataType", [])
        gpu_name = displays[0].get("sppci_model", "Apple Silicon GPU") if displays else "Apple Silicon GPU"
    except Exception:
        gpu_name = "Apple Silicon GPU"

    gpu_family = "Apple9"
    upper = gpu_name.upper()
    if "M5" in upper:
        gpu_family = "Apple10"
    elif "M4" in upper or "M3" in upper:
        gpu_family = "Apple9"
    elif "M2" in upper:
        gpu_family = "Apple8"
    elif "M1" in upper:
        gpu_family = "Apple7"
    cache_key = f"{gpu_family.lower()}_{macos_build}"
    return gpu_name, gpu_family, macos_ver, macos_build, cache_key


def export_local_cache_entries():
    if not local_cache_root.is_dir():
        return 0
    entry_dirs = sorted([p for p in local_cache_root.iterdir() if p.is_dir()])
    if not entry_dirs:
        return 0

    gpu_name, host_family, macos_ver, host_build, host_cache_key = detect_host_metadata()
    exported = 0

    for entry_dir in entry_dirs:
        files_meta = []
        total_bytes = 0
        for root, _, filenames in os.walk(entry_dir):
            for fname in sorted(filenames):
                fpath = Path(root) / fname
                if not fpath.is_file() or fpath.is_symlink():
                    continue
                rel_inside_entry = fpath.relative_to(entry_dir).as_posix()
                rel_path = f"{entry_dir.name}/{rel_inside_entry}"
                sz = fpath.stat().st_size
                digest = sha256_file(fpath)
                files_meta.append({
                    "relative_path": rel_path,
                    "sha256": digest,
                    "size_bytes": sz,
                })
                total_bytes += sz

        if not files_meta:
            continue
        files_meta.sort(key=lambda r: r["relative_path"])

        # Infer gpu_family / macos_build from '<buildHash>_<appleN>_<macosBuild>' directory name if present
        m = re.match(r"^(.+)_(apple\d+|mac\d+)_([A-Za-z0-9]+)$", entry_dir.name, re.IGNORECASE)
        if m:
            fam_raw = m.group(2)
            gpu_family = fam_raw.capitalize()
            macos_build = m.group(3)
            cache_key = f"{fam_raw.lower()}_{macos_build}"
        else:
            gpu_family = host_family
            macos_build = host_build
            cache_key = host_cache_key

        manifest = {
            "cache_key": cache_key,
            "created_utc": utc_now_iso(),
            "entry_count": 1,
            "file_count": len(files_meta),
            "files": files_meta,
            "gpu_family": gpu_family,
            "gpu_name": gpu_name,
            "macos_build": macos_build,
            "macos_version": macos_ver,
            "schema": "directmetal.shadercache.v1",
            "total_bytes": total_bytes,
        }
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")

        archive_path = target_dir / f"{entry_dir.name}.dmcache.tar.gz"
        with tarfile.open(archive_path, "w:gz") as tf:
            mi = tarfile.TarInfo(name="manifest.json")
            mi.size = len(manifest_bytes)
            mi.mtime = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
            mi.mode = 0o644
            tf.addfile(mi, io.BytesIO(manifest_bytes))

            si = tarfile.TarInfo(name="shaders")
            si.type = tarfile.DIRTYPE
            si.mode = 0o755
            tf.addfile(si)

            tf.add(entry_dir, arcname=f"shaders/{entry_dir.name}")
        exported += 1
        print(f"[DirectMetal] Exported local shader cache entry -> {archive_path.name} ({len(files_meta)} files)")
    return exported


existing_archives = sorted(target_dir.glob("*.dmcache.tar.gz"))
if export_local or (not existing_archives and local_cache_root.is_dir()):
    export_local_cache_entries()

archives = sorted(target_dir.glob("*.dmcache.tar.gz"))
if not archives:
    print(f"error: no .dmcache.tar.gz archives found in {target_dir}", file=sys.stderr)
    sys.exit(1)


def infer_build_hash_and_title(archive_path: Path, manifest: dict):
    # 1. Explicit manifest fields if present
    b_hash = str(manifest.get("build_hash") or manifest.get("buildHash") or "").strip()
    title = str(manifest.get("title") or "").strip()

    cache_key = str(manifest.get("cache_key") or "").strip()
    top_dirs = []
    for rec in manifest.get("files", []):
        rel = str(rec.get("relative_path") or "")
        if "/" in rel:
            top = rel.split("/", 1)[0]
            if top not in top_dirs:
                top_dirs.append(top)

    # 2. Infer buildHash from 'shaders/<buildHash>_<cacheKey>/' directory convention
    if not b_hash and top_dirs:
        first_dir = top_dirs[0]
        if cache_key and first_dir.lower().endswith("_" + cache_key.lower()):
            b_hash = first_dir[: -(len(cache_key) + 1)]
        else:
            m = re.match(r"^([0-9a-fA-F]{8,64})(?:_|$)", first_dir)
            if m:
                b_hash = m.group(1)
            elif "_" in first_dir:
                b_hash = first_dir.split("_", 1)[0]
            else:
                b_hash = first_dir

    # 3. Infer from archive filename stem '<stem>.dmcache.tar.gz'
    stem = archive_path.name
    if stem.endswith(".dmcache.tar.gz"):
        stem = stem[: -len(".dmcache.tar.gz")]
    elif stem.endswith(".tar.gz"):
        stem = stem[: -len(".tar.gz")]

    if not b_hash:
        if default_build_hash:
            b_hash = default_build_hash
        elif cache_key and stem.lower().endswith("_" + cache_key.lower()):
            b_hash = stem[: -(len(cache_key) + 1)]
        else:
            m = re.match(r"^([0-9a-fA-F]{8,64})(?:[-_]|$)", stem)
            b_hash = m.group(1) if m else stem

    if not title:
        if default_title:
            title = default_title
        else:
            # Strip buildHash and cacheKey tokens from stem if extra title text exists
            cleaned = stem
            for tok in (cache_key, b_hash):
                if tok:
                    cleaned = re.sub(re.escape(tok), "", cleaned, flags=re.IGNORECASE)
            cleaned = cleaned.strip("-_ ")
            title = cleaned if cleaned else f"DirectMetal Cache ({b_hash})"

    return b_hash, title


entries = []
for archive in archives:
    archive_bytes = archive.stat().st_size
    archive_sha256 = sha256_file(archive)

    try:
        with tarfile.open(archive, "r:gz") as tf:
            manifest_member = None
            for member in tf.getmembers():
                norm = member.name.lstrip("./")
                if norm == "manifest.json":
                    manifest_member = member
                    break
            if manifest_member is None:
                raise ValueError("missing manifest.json")
            extracted = tf.extractfile(manifest_member)
            if extracted is None:
                raise ValueError("unreadable manifest.json")
            manifest = json.loads(extracted.read().decode("utf-8"))
    except Exception as exc:
        print(f"error: invalid shader cache archive {archive.name}: {exc}", file=sys.stderr)
        sys.exit(1)

    if manifest.get("schema") != "directmetal.shadercache.v1":
        print(
            f"error: {archive.name} has unsupported manifest schema '{manifest.get('schema')}' (expected directmetal.shadercache.v1)",
            file=sys.stderr,
        )
        sys.exit(1)

    build_hash, title = infer_build_hash_and_title(archive, manifest)
    gpu_family = str(manifest.get("gpu_family") or "Unknown")
    macos_build = str(manifest.get("macos_build") or "unknown")
    file_count = int(manifest.get("file_count") or len(manifest.get("files", [])))
    updated_utc = str(manifest.get("created_utc") or utc_now_iso())
    archive_url = f"{base_url}/{archive.name}" if base_url else archive.name

    entries.append({
        "archive_bytes": archive_bytes,
        "archive_sha256": archive_sha256,
        "archive_url": archive_url,
        "build_hash": build_hash,
        "file_count": file_count,
        "gpu_family": gpu_family,
        "macos_build": macos_build,
        "title": title,
        "updated_utc": updated_utc,
    })
    print(
        f"[DirectMetal] Indexed {archive.name}: build_hash={build_hash} "
        f"target={gpu_family}/{macos_build} files={file_count} sha256={archive_sha256[:16]}…"
    )

entries.sort(key=lambda e: (e["build_hash"], e["gpu_family"], e["macos_build"]))

index_doc = {
    "entries": entries,
    "schema": "directmetal.shadercache.index.v1",
    "updated_utc": utc_now_iso(),
}

output_index.parent.mkdir(parents=True, exist_ok=True)
output_index.write_text(json.dumps(index_doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"[DirectMetal] Wrote {output_index} ({len(entries)} entries, schema=directmetal.shadercache.index.v1)")
PY

if [[ -n "${GH_RELEASE_TAG}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DirectMetal] --dry-run enabled: skipping 'gh release upload ${GH_RELEASE_TAG}'."
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "error: GitHub CLI ('gh') is required for --gh-release ${GH_RELEASE_TAG}" >&2
      exit 1
    fi
    shopt -s nullglob
    UPLOAD_FILES=("${OUTPUT_INDEX}" "${TARGET_DIR}"/*.dmcache.tar.gz)
    shopt -u nullglob
    GH_ARGS=(release upload "${GH_RELEASE_TAG}" "${UPLOAD_FILES[@]}" --clobber)
    if [[ -n "${GH_REPO}" ]]; then
      GH_ARGS+=(--repo "${GH_REPO}")
    fi
    echo "[DirectMetal] Uploading index.json + shader cache archives to GitHub Release '${GH_RELEASE_TAG}'..."
    gh "${GH_ARGS[@]}"
  fi
fi
