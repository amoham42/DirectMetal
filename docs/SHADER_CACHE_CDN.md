# DirectMetal Cloud Shader Cache CDN

DirectMetal eliminates shader compilation stutter on Apple Silicon by pre-compiling DirectX pipelines into hardware-keyed **`MTLBinaryArchive`** caches and distributing verified archives over GitHub Releases.

---

## 1. How Hardware Keying Works

Metal compiled binary archives are specific to both the **Apple Silicon GPU family** and the **macOS Metal compiler build**:

```text
<pe_build_hash>_<gpu_family>_<macos_build>
Example: 4b7170222eb0_1453676040_169029632_apple9_25G241
```

| Chip Generation | GPU Family Tag | Measured Warm Load Speedup (`dm_shader_cache`) |
| :--- | :--- | ---: |
| **Apple M1 / M1 Pro / M1 Max / M1 Ultra** | `apple7` | **`66.7×`** (`88.18 ms → 1.32 ms`, 24/24 hits) |
| **Apple M2 / M2 Pro / M2 Max / M2 Ultra** | `apple8` | Supported |
| **Apple M3 / M4 / M4 Pro / M4 Max** | `apple9` | **`254.1×`** (`252.81 ms → 1.00 ms`, 24/24 hits) |
| **Apple M5+** | `apple10` | Supported (runtime-probed, macOS 15 SDK compatible) |

---

## 2. Double-SHA-256 Security Model

Every `DirectMetal cache sync` performs **two independent SHA-256 verifications** before installing any file into `~/Library/Caches/DirectMetal/Shaders` (or `$DIRECTMETAL_SHADER_CACHE_ROOT`):

1. **Outer Archive Digest:** Verifies the downloaded `.dmcache.tar.gz` against `archive_sha256` in `shader-cache-index.json` before invoking `tar`.
2. **Per-File Manifest Digest (Parallel):** Validates every extracted file's relative path (rejecting `..` or absolute paths) and verifies every file's SHA-256 against `manifest.json` using multi-core `DispatchQueue.concurrentPerform`.

---

## 3. Syncing, Inspecting & Pruning Local Caches

```bash
# Sync a verified cloud cache matching your exact Apple Silicon GPU + macOS build
DirectMetal cache sync \
  https://github.com/amoham42/DirectMetal/releases/download/v1.0.1/shader-cache-index.json \
  --exe "/path/to/game.exe"

# Inspect local caches (highlights current vs stale OS-build entries)
DirectMetal cache list

# Preview & reclaim disk space from older macOS builds without touching current caches
DirectMetal cache prune --dry-run
DirectMetal cache prune
```

---

## 4. Contributing Shader Caches for Your Apple Silicon Mac

After playing a title on your Mac (e.g., M2, M3, M4, or M5):

```bash
# Export a verified archive for one game
DirectMetal cache export ./my-game.dmcache.tar.gz --filter <build_hash>

# Or publish & merge directly into a release index (maintainers)
./scripts/publish_shader_cache.sh --tag v1.0.1 --filter <build_hash>
```
