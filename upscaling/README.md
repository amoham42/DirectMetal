# DirectMetal Subsystem — Upscaling

Transparent DLSS (`nvngx_dlss`), FSR (`ffx_fsr`), and XeSS (`libxess`) interceptor layer backed by Apple **MetalFX** (`MTLFXSpatialScaler` / `MTLFXTemporalScaler` and Metal 4 FX).

## Components
- `dm_metalfx_bridge/` (`libdm_metalfx_bridge.a` + `dm_metalfx_bench`): Native Objective-C++ bridge driving Apple `MTLFXSpatialScaler` and `MTLFXTemporalScaler` on Apple Silicon with `MTLStorageModePrivate` targets, Halton jitter, motion-vector scaling, and auto-exposure.
- `shims/`: C ABI dispatchers (`dm_upscaler_abi.h`, `ffx_fsr_shim.c`, `libxess_shim.c`) mapping FSR 2/3 & XeSS quality presets and dispatches to MetalFX, complementing Mullion's bundled `nvngx.dll` DLSS→MetalFX interceptor and `MULLION_METALFX_SPATIAL_SWAPCHAIN` support in `DirectMetal.app`.
