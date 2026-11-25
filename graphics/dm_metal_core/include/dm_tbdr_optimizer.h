#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum dm_dx_pass_op_kind {
    DM_DX_OP_CLEAR_RTV = 0,
    DM_DX_OP_CLEAR_DSV = 1,
    DM_DX_OP_DRAW_BATCH = 2,
    DM_DX_OP_RESOLVE_MSAA = 3,
    DM_DX_OP_DISCARD_ATTACHMENT = 4,
    DM_DX_OP_READ_SRV_BARRIER = 5,
} dm_dx_pass_op_kind_t;

typedef enum dm_tbdr_load_action {
    DM_TBDR_LOAD_DONT_CARE = 0,
    DM_TBDR_LOAD_LOAD = 1,
    DM_TBDR_LOAD_CLEAR = 2,
} dm_tbdr_load_action_t;

typedef enum dm_tbdr_store_action {
    DM_TBDR_STORE_DONT_CARE = 0,
    DM_TBDR_STORE_STORE = 1,
    DM_TBDR_STORE_MULTISAMPLE_RESOLVE = 2,
} dm_tbdr_store_action_t;

typedef struct dm_dx_attachment_desc {
    uint32_t attachment_id;
    uint32_t width;
    uint32_t height;
    uint32_t sample_count;
    uint32_t bytes_per_pixel;
    bool is_depth_stencil;
    bool is_backbuffer_or_exported;
} dm_dx_attachment_desc_t;

typedef struct dm_dx_pass_op {
    dm_dx_pass_op_kind_t kind;
    uint32_t color_rtv_id;      // UINT32_MAX if none
    uint32_t resolve_dst_id;    // UINT32_MAX if none
    uint32_t dsv_id;            // UINT32_MAX if none
    uint32_t srv_read_id;       // attachment read as SRV on barrier/draw
    uint32_t draw_count;
} dm_dx_pass_op_t;

#define DM_TBDR_MAX_PASSES 64
#define DM_TBDR_MAX_ATTACHMENTS 32

typedef struct dm_tbdr_metal_pass {
    uint32_t color_rtv_id;
    uint32_t resolve_dst_id;
    uint32_t dsv_id;
    dm_tbdr_load_action_t color_load;
    dm_tbdr_store_action_t color_store;
    dm_tbdr_load_action_t depth_load;
    dm_tbdr_store_action_t depth_store;
    uint32_t merged_op_count;
    uint32_t total_draws;
} dm_tbdr_metal_pass_t;

typedef struct dm_tbdr_attachment_plan {
    uint32_t attachment_id;
    bool promote_memoryless;
    uint64_t baseline_dram_bytes;
    uint64_t optimized_dram_bytes;
} dm_tbdr_attachment_plan_t;

typedef struct dm_tbdr_optimized_plan {
    uint32_t original_pass_count;
    uint32_t coalesced_pass_count;
    dm_tbdr_metal_pass_t passes[DM_TBDR_MAX_PASSES];
    uint32_t attachment_count;
    dm_tbdr_attachment_plan_t attachments[DM_TBDR_MAX_ATTACHMENTS];
    uint64_t total_baseline_dram_bytes;
    uint64_t total_optimized_dram_bytes;
} dm_tbdr_optimized_plan_t;

bool dm_tbdr_optimize_passes(const dm_dx_attachment_desc_t *attachments,
                              size_t attachment_count,
                              const dm_dx_pass_op_t *ops,
                              size_t op_count,
                              dm_tbdr_optimized_plan_t *out_plan);

#ifdef __cplusplus
}
#endif
