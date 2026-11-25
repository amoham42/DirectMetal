#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum dm_upscaler_vendor {
    DM_UPSCALER_METALFX = 0,
    DM_UPSCALER_DLSS = 1,
    DM_UPSCALER_FSR = 2,
    DM_UPSCALER_XESS = 3,
} dm_upscaler_vendor_t;

typedef enum dm_upscale_quality {
    DM_UPSCALE_ULTRA_QUALITY = 0,
    DM_UPSCALE_QUALITY = 1,
    DM_UPSCALE_BALANCED = 2,
    DM_UPSCALE_PERFORMANCE = 3,
    DM_UPSCALE_ULTRA_PERFORMANCE = 4,
} dm_upscale_quality_t;

typedef struct dm_metalfx_caps {
    bool spatial_supported;
    bool temporal_supported;
    bool metal4fx_spatial;
    bool metal4fx_temporal;
    float temporal_min_scale;
    float temporal_max_scale;
} dm_metalfx_caps_t;

typedef struct dm_metalfx_spatial dm_metalfx_spatial_t;
typedef struct dm_metalfx_temporal dm_metalfx_temporal_t;

bool dm_metalfx_query_caps(dm_metalfx_caps_t *out_caps);

void dm_metalfx_resolve_render_size(dm_upscaler_vendor_t vendor,
                                    dm_upscale_quality_t quality,
                                    uint32_t output_width,
                                    uint32_t output_height,
                                    uint32_t *out_render_width,
                                    uint32_t *out_render_height);

dm_metalfx_spatial_t *dm_metalfx_spatial_create(uint32_t input_width,
                                                uint32_t input_height,
                                                uint32_t output_width,
                                                uint32_t output_height,
                                                uint32_t mtl_pixel_format,
                                                bool hdr);
void dm_metalfx_spatial_destroy(dm_metalfx_spatial_t *scaler);
bool dm_metalfx_spatial_encode(dm_metalfx_spatial_t *scaler,
                               void *mtl_command_buffer,
                               void *mtl_color_tex,
                               void *mtl_output_tex,
                               uint32_t content_width,
                               uint32_t content_height);

dm_metalfx_temporal_t *dm_metalfx_temporal_create(uint32_t input_width,
                                                  uint32_t input_height,
                                                  uint32_t output_width,
                                                  uint32_t output_height,
                                                  uint32_t color_format,
                                                  uint32_t depth_format,
                                                  uint32_t motion_format,
                                                  uint32_t output_format);
void dm_metalfx_temporal_destroy(dm_metalfx_temporal_t *scaler);
bool dm_metalfx_temporal_encode(dm_metalfx_temporal_t *scaler,
                                void *mtl_command_buffer,
                                void *mtl_color_tex,
                                void *mtl_depth_tex,
                                void *mtl_motion_tex,
                                void *mtl_output_tex,
                                float jitter_x,
                                float jitter_y,
                                float motion_scale_x,
                                float motion_scale_y,
                                bool reset_history);

#ifdef __cplusplus
}
#endif
