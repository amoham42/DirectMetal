#include "dm_metalfx_bridge.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <cstring>

static uint32_t even_dim(uint32_t v) {
    uint32_t clamped = v < 64u ? 64u : v;
    return clamped & ~1u;
}

bool dm_metalfx_query_caps(dm_metalfx_caps_t *out_caps) {
    if (!out_caps) return false;
    memset(out_caps, 0, sizeof(*out_caps));
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return false;
        out_caps->spatial_supported = [MTLFXSpatialScalerDescriptor supportsDevice:dev];
        out_caps->temporal_supported = [MTLFXTemporalScalerDescriptor supportsDevice:dev];
        if (@available(macOS 26.0, *)) {
            out_caps->metal4fx_spatial = [MTLFXSpatialScalerDescriptor supportsMetal4FX:dev];
            out_caps->metal4fx_temporal = [MTLFXTemporalScalerDescriptor supportsMetal4FX:dev];
        }
        out_caps->temporal_min_scale = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:dev];
        out_caps->temporal_max_scale = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:dev];
        return true;
    }
}

void dm_metalfx_resolve_render_size(dm_upscaler_vendor_t vendor,
                                    dm_upscale_quality_t quality,
                                    uint32_t output_width,
                                    uint32_t output_height,
                                    uint32_t *out_render_width,
                                    uint32_t *out_render_height) {
    (void)vendor;
    float factor = 1.5f;
    switch (quality) {
        case DM_UPSCALE_ULTRA_QUALITY:     factor = 1.3f; break;
        case DM_UPSCALE_QUALITY:           factor = 1.5f; break;
        case DM_UPSCALE_BALANCED:          factor = 1.7f; break;
        case DM_UPSCALE_PERFORMANCE:       factor = 2.0f; break;
        case DM_UPSCALE_ULTRA_PERFORMANCE: factor = 3.0f; break;
    }
    if (out_render_width) {
        *out_render_width = even_dim((uint32_t)((float)output_width / factor + 0.5f));
    }
    if (out_render_height) {
        *out_render_height = even_dim((uint32_t)((float)output_height / factor + 0.5f));
    }
}

struct dm_metalfx_spatial {
    id<MTLFXSpatialScaler> scaler;
};

dm_metalfx_spatial_t *dm_metalfx_spatial_create(uint32_t input_width,
                                                uint32_t input_height,
                                                uint32_t output_width,
                                                uint32_t output_height,
                                                uint32_t mtl_pixel_format,
                                                bool hdr) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || ![MTLFXSpatialScalerDescriptor supportsDevice:dev]) return nullptr;

        MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
        desc.colorTextureFormat = (MTLPixelFormat)mtl_pixel_format;
        desc.outputTextureFormat = (MTLPixelFormat)mtl_pixel_format;
        desc.inputWidth = input_width;
        desc.inputHeight = input_height;
        desc.outputWidth = output_width;
        desc.outputHeight = output_height;
        desc.colorProcessingMode = hdr ? MTLFXSpatialScalerColorProcessingModeHDR
                                       : MTLFXSpatialScalerColorProcessingModePerceptual;

        id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:dev];
        if (!scaler) return nullptr;

        auto *handle = new dm_metalfx_spatial();
        handle->scaler = scaler;
        return handle;
    }
}

void dm_metalfx_spatial_destroy(dm_metalfx_spatial_t *scaler) {
    if (!scaler) return;
    @autoreleasepool {
        scaler->scaler = nil;
    }
    delete scaler;
}

bool dm_metalfx_spatial_encode(dm_metalfx_spatial_t *scaler,
                               void *mtl_command_buffer,
                               void *mtl_color_tex,
                               void *mtl_output_tex,
                               uint32_t content_width,
                               uint32_t content_height) {
    if (!scaler || !mtl_command_buffer || !mtl_color_tex || !mtl_output_tex) return false;
    @autoreleasepool {
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)mtl_command_buffer;
        id<MTLTexture> col = (__bridge id<MTLTexture>)mtl_color_tex;
        id<MTLTexture> out = (__bridge id<MTLTexture>)mtl_output_tex;
        scaler->scaler.colorTexture = col;
        scaler->scaler.outputTexture = out;
        scaler->scaler.inputContentWidth = content_width;
        scaler->scaler.inputContentHeight = content_height;
        [scaler->scaler encodeToCommandBuffer:cb];
        return true;
    }
}

struct dm_metalfx_temporal {
    id<MTLFXTemporalScaler> scaler;
};

dm_metalfx_temporal_t *dm_metalfx_temporal_create(uint32_t input_width,
                                                  uint32_t input_height,
                                                  uint32_t output_width,
                                                  uint32_t output_height,
                                                  uint32_t color_format,
                                                  uint32_t depth_format,
                                                  uint32_t motion_format,
                                                  uint32_t output_format) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || ![MTLFXTemporalScalerDescriptor supportsDevice:dev]) return nullptr;

        MTLFXTemporalScalerDescriptor *desc = [MTLFXTemporalScalerDescriptor new];
        desc.colorTextureFormat = (MTLPixelFormat)color_format;
        desc.depthTextureFormat = (MTLPixelFormat)depth_format;
        desc.motionTextureFormat = (MTLPixelFormat)motion_format;
        desc.outputTextureFormat = (MTLPixelFormat)output_format;
        desc.inputWidth = input_width;
        desc.inputHeight = input_height;
        desc.outputWidth = output_width;
        desc.outputHeight = output_height;
        desc.autoExposureEnabled = YES;
        desc.requiresSynchronousInitialization = YES;

        id<MTLFXTemporalScaler> scaler = [desc newTemporalScalerWithDevice:dev];
        if (!scaler) return nullptr;

        auto *handle = new dm_metalfx_temporal();
        handle->scaler = scaler;
        return handle;
    }
}

void dm_metalfx_temporal_destroy(dm_metalfx_temporal_t *scaler) {
    if (!scaler) return;
    @autoreleasepool {
        scaler->scaler = nil;
    }
    delete scaler;
}

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
                                bool reset_history) {
    if (!scaler || !mtl_command_buffer || !mtl_color_tex || !mtl_depth_tex ||
        !mtl_motion_tex || !mtl_output_tex) {
        return false;
    }
    @autoreleasepool {
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)mtl_command_buffer;
        id<MTLTexture> col = (__bridge id<MTLTexture>)mtl_color_tex;
        id<MTLTexture> dep = (__bridge id<MTLTexture>)mtl_depth_tex;
        id<MTLTexture> mot = (__bridge id<MTLTexture>)mtl_motion_tex;
        id<MTLTexture> out = (__bridge id<MTLTexture>)mtl_output_tex;

        scaler->scaler.colorTexture = col;
        scaler->scaler.depthTexture = dep;
        scaler->scaler.motionTexture = mot;
        scaler->scaler.outputTexture = out;
        scaler->scaler.inputContentWidth = col.width;
        scaler->scaler.inputContentHeight = col.height;
        scaler->scaler.jitterOffsetX = jitter_x;
        scaler->scaler.jitterOffsetY = jitter_y;
        scaler->scaler.motionVectorScaleX = motion_scale_x;
        scaler->scaler.motionVectorScaleY = motion_scale_y;
        scaler->scaler.depthReversed = NO;
        scaler->scaler.reset = reset_history ? YES : NO;
        [scaler->scaler encodeToCommandBuffer:cb];
        return true;
    }
}
