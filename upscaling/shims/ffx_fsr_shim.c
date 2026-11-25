#include "dm_upscaler_abi.h"

#include <stdlib.h>

struct dm_upscaler_context {
    dm_upscaler_vendor_t vendor;
    dm_upscale_quality_t quality;
    uint32_t render_width;
    uint32_t render_height;
    uint32_t output_width;
    uint32_t output_height;
    bool use_temporal;
    dm_metalfx_spatial_t *spatial;
    dm_metalfx_temporal_t *temporal;
};

dm_upscaler_context_t *dm_upscaler_create(dm_upscaler_vendor_t vendor,
                                          dm_upscale_quality_t quality,
                                          uint32_t output_width,
                                          uint32_t output_height,
                                          bool use_temporal,
                                          uint32_t color_format,
                                          uint32_t depth_format,
                                          uint32_t motion_format) {
    uint32_t rw = 0, rh = 0;
    dm_metalfx_resolve_render_size(vendor, quality, output_width, output_height, &rw, &rh);

    dm_upscaler_context_t *ctx = (dm_upscaler_context_t *)calloc(1, sizeof(dm_upscaler_context_t));
    if (!ctx) return NULL;
    ctx->vendor = vendor;
    ctx->quality = quality;
    ctx->render_width = rw;
    ctx->render_height = rh;
    ctx->output_width = output_width;
    ctx->output_height = output_height;
    ctx->use_temporal = use_temporal;

    if (use_temporal) {
        ctx->temporal = dm_metalfx_temporal_create(
            rw, rh, output_width, output_height,
            color_format, depth_format, motion_format, color_format);
        if (!ctx->temporal) {
            free(ctx);
            return NULL;
        }
    } else {
        ctx->spatial = dm_metalfx_spatial_create(rw, rh, output_width, output_height, color_format, false);
        if (!ctx->spatial) {
            free(ctx);
            return NULL;
        }
    }
    return ctx;
}

void dm_upscaler_destroy(dm_upscaler_context_t *ctx) {
    if (!ctx) return;
    if (ctx->temporal) dm_metalfx_temporal_destroy(ctx->temporal);
    if (ctx->spatial) dm_metalfx_spatial_destroy(ctx->spatial);
    free(ctx);
}

bool dm_upscaler_dispatch(dm_upscaler_context_t *ctx, const dm_upscale_dispatch_desc_t *desc) {
    if (!ctx || !desc) return false;
    if (ctx->use_temporal && ctx->temporal) {
        return dm_metalfx_temporal_encode(
            ctx->temporal, desc->command_buffer, desc->color_texture,
            desc->depth_texture, desc->motion_texture, desc->output_texture,
            desc->jitter_x, desc->jitter_y,
            desc->motion_scale_x, desc->motion_scale_y, desc->reset);
    }
    if (ctx->spatial) {
        return dm_metalfx_spatial_encode(
            ctx->spatial, desc->command_buffer, desc->color_texture,
            desc->output_texture,
            desc->render_width ? desc->render_width : ctx->render_width,
            desc->render_height ? desc->render_height : ctx->render_height);
    }
    return false;
}

void dm_upscaler_get_render_resolution(const dm_upscaler_context_t *ctx, uint32_t *out_w, uint32_t *out_h) {
    if (!ctx) return;
    if (out_w) *out_w = ctx->render_width;
    if (out_h) *out_h = ctx->render_height;
}

// Intercepted AMD FidelityFX Super Resolution (FSR 2/3) ABI entry points -> MetalFX
int dm_ffx_fsr_query_render_resolution(int quality_mode, uint32_t out_w, uint32_t out_h,
                                       uint32_t *in_w, uint32_t *in_h) {
    dm_upscale_quality_t q = DM_UPSCALE_QUALITY;
    if (quality_mode == 2) q = DM_UPSCALE_BALANCED;
    else if (quality_mode == 3) q = DM_UPSCALE_PERFORMANCE;
    else if (quality_mode == 4) q = DM_UPSCALE_ULTRA_PERFORMANCE;
    dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, q, out_w, out_h, in_w, in_h);
    return 0;
}
