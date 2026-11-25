#include "dm_upscaler_abi.h"

// Intercepted Intel XeSS ABI entry points -> MetalFX
int dm_xess_get_input_resolution(int quality_preset, uint32_t out_w, uint32_t out_h,
                                 uint32_t *in_w, uint32_t *in_h) {
    dm_upscale_quality_t q = DM_UPSCALE_QUALITY;
    switch (quality_preset) {
        case 100: q = DM_UPSCALE_PERFORMANCE; break;
        case 101: q = DM_UPSCALE_BALANCED; break;
        case 102: q = DM_UPSCALE_QUALITY; break;
        case 103: q = DM_UPSCALE_ULTRA_QUALITY; break;
        default: break;
    }
    dm_metalfx_resolve_render_size(DM_UPSCALER_XESS, q, out_w, out_h, in_w, in_h);
    return 0;
}
