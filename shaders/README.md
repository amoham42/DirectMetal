# DirectMetal Subsystem — Shaders

Manages DXBC / DXIL → Metal IR translation (`airconv`), offline and runtime `MTLBinaryArchive` caches keyed by `(game_build, apple_gpu_family, macos_version)`, and pre-warmed pipeline libraries.

- Phase 0–1: Runtime shader conversion via Mullion `airconv` + family-keyed persistent cache directory managed by `DirectMetal.app`.
- Phase 2: Explicit `MTLBinaryArchive` serialization & pre-warming pipeline.
