#pragma once

#include "dm_metalfx_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_upscale_dispatch_desc {
    dm_upscaler_vendor_t vendor;
    dm_upscale_quality_t quality;
    void *command_buffer;
    void *color_texture;
    void *depth_texture;
    void *motion_texture;
    void *output_texture;
    uint32_t render_width;
    uint32_t render_height;
    uint32_t output_width;
    uint32_t output_height;
    float jitter_x;
    float jitter_y;
    float motion_scale_x;
    float motion_scale_y;
    bool reset;
} dm_upscale_dispatch_desc_t;

typedef struct dm_upscaler_context dm_upscaler_context_t;

dm_upscaler_context_t *dm_upscaler_create(dm_upscaler_vendor_t vendor,
                                          dm_upscale_quality_t quality,
                                          uint32_t output_width,
                                          uint32_t output_height,
                                          bool use_temporal,
                                          uint32_t color_format,
                                          uint32_t depth_format,
                                          uint32_t motion_format);
void dm_upscaler_destroy(dm_upscaler_context_t *ctx);
bool dm_upscaler_dispatch(dm_upscaler_context_t *ctx, const dm_upscale_dispatch_desc_t *desc);
void dm_upscaler_get_render_resolution(const dm_upscaler_context_t *ctx,
                                       uint32_t *out_w,
                                       uint32_t *out_h);

#ifdef __cplusplus
}
#endif
