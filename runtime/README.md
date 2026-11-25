# DirectMetal Subsystem — Runtime

DirectMetal's native ARM64 host runtime layer keeps Win32 synchronization, filesystem prefix isolation, audio, and input execution native on Apple Silicon while isolating x86-64 translation strictly to Windows game binaries.

## Components
- **`dm_sync/` (`libdm_sync.a`):** Native Darwin NT synchronization primitives (`dm_nt_event_t`, `dm_nt_semaphore_t`, `dm_nt_wait_multiple`) implemented directly on `<os/os_sync_wait_on_address.h>` (`os_sync_wait_on_address` / `os_sync_wake_by_address_*`).
- **`dm_prefix/` (`libdm_prefix.a`):** Instant APFS copy-on-write per-game prefix manager backed by Darwin `<sys/clonefile.h>` (`clonefile(2)`).
- **`dm_host_io/` (`libdm_host_io.a`):** Native ARM64 audio (`CoreAudio`) and controller/keyboard/mouse (`GameController.framework`) host capability probes and latency telemetry.
- **`config/mullion.conf`:** Tuned Mullion D3D10/11/12 configuration.

## Execution Engines (Fetched Externally via `scripts/`)
- **Primary (Post-Rosetta):** Native ARM64 Wine + ARM64EC + FEX-Emu + Mullion ARM64X (`scripts/setup_runtime_arm64ec.sh`, using Wine/Mullion LGPL-2.1 and MetalSharp-Wine AGPL-3.0 external prebuilt runtime).
- **Fallback (Rosetta 2):** Wine 11.21 x86_64 (`Gcenx/macOS_Wine_builds`, LGPL-2.1) + Mullion `v0.5-alpha.4` (`dttdrv/mullion`, LGPL-2.1) (`scripts/setup_runtime.sh`).
