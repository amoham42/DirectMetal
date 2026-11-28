#include "dm_tbdr_optimizer.h"

#include <cstring>

static uint64_t safe_mul_u64(uint64_t a, uint64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a > UINT64_MAX / b) return UINT64_MAX;
    return a * b;
}

static uint64_t safe_add_u64(uint64_t a, uint64_t b) {
    if (a > UINT64_MAX - b) return UINT64_MAX;
    return a + b;
}

bool dm_tbdr_optimize_passes(const dm_dx_attachment_desc_t *attachments,
                              size_t attachment_count,
                              const dm_dx_pass_op_t *ops,
                              size_t op_count,
                              dm_tbdr_optimized_plan_t *out_plan) {
    if (!attachments || !ops || !out_plan || attachment_count == 0 || op_count == 0 ||
        attachment_count > DM_TBDR_MAX_ATTACHMENTS) {
        return false;
    }
    memset(out_plan, 0, sizeof(*out_plan));

    // Track whether an attachment is ever read by an SRV barrier or exported
    bool read_externally[DM_TBDR_MAX_ATTACHMENTS] = {false};
    bool resolved_target[DM_TBDR_MAX_ATTACHMENTS] = {false};
    uint32_t raw_passes = 0;

    for (size_t i = 0; i < op_count; ++i) {
        if (ops[i].kind == DM_DX_OP_DRAW_BATCH || ops[i].kind == DM_DX_OP_RESOLVE_MSAA) {
            if (raw_passes < UINT32_MAX) {
                raw_passes += 1;
            }
        }
        if (ops[i].kind == DM_DX_OP_READ_SRV_BARRIER && ops[i].srv_read_id != UINT32_MAX) {
            for (size_t a = 0; a < attachment_count; ++a) {
                if (attachments[a].attachment_id == ops[i].srv_read_id) {
                    read_externally[a] = true;
                }
            }
        }
        if (ops[i].kind == DM_DX_OP_RESOLVE_MSAA && ops[i].resolve_dst_id != UINT32_MAX) {
            for (size_t a = 0; a < attachment_count; ++a) {
                if (attachments[a].attachment_id == ops[i].resolve_dst_id) {
                    resolved_target[a] = true;
                }
            }
        }
    }
    const uint32_t clamped_ops = op_count > UINT32_MAX ? UINT32_MAX : static_cast<uint32_t>(op_count);
    out_plan->original_pass_count = raw_passes > 0 ? raw_passes : clamped_ops;

    // Coalesce adjacent operations sharing compatible (color_rtv_id, dsv_id) unless broken by SRV barrier
    uint32_t pass_idx = 0;
    bool have_active = false;
    bool color_cleared_or_discarded = false;
    bool depth_cleared_or_discarded = false;

    for (size_t i = 0; i < op_count; ++i) {
        const dm_dx_pass_op_t &op = ops[i];
        if (op.kind == DM_DX_OP_READ_SRV_BARRIER) {
            have_active = false;
            continue;
        }

        const bool compatible = have_active &&
                                out_plan->passes[pass_idx - 1].color_rtv_id == op.color_rtv_id &&
                                (out_plan->passes[pass_idx - 1].dsv_id == op.dsv_id ||
                                 op.dsv_id == UINT32_MAX ||
                                 out_plan->passes[pass_idx - 1].dsv_id == UINT32_MAX);

        if (!compatible) {
            if (pass_idx >= DM_TBDR_MAX_PASSES) return false;
            dm_tbdr_metal_pass_t &mp = out_plan->passes[pass_idx++];
            mp.color_rtv_id = op.color_rtv_id;
            mp.resolve_dst_id = op.resolve_dst_id;
            mp.dsv_id = op.dsv_id;
            mp.color_load = DM_TBDR_LOAD_LOAD;
            mp.color_store = DM_TBDR_STORE_STORE;
            mp.depth_load = DM_TBDR_LOAD_LOAD;
            mp.depth_store = DM_TBDR_STORE_STORE;
            mp.merged_op_count = 0;
            mp.total_draws = 0;
            have_active = true;
            color_cleared_or_discarded = false;
            depth_cleared_or_discarded = false;
        }

        dm_tbdr_metal_pass_t &cur = out_plan->passes[pass_idx - 1];
        if (cur.dsv_id == UINT32_MAX && op.dsv_id != UINT32_MAX) cur.dsv_id = op.dsv_id;
        if (cur.resolve_dst_id == UINT32_MAX && op.resolve_dst_id != UINT32_MAX) {
            cur.resolve_dst_id = op.resolve_dst_id;
        }
        if (cur.merged_op_count < UINT32_MAX) {
            cur.merged_op_count += 1;
        }

        switch (op.kind) {
            case DM_DX_OP_CLEAR_RTV:
                if (cur.total_draws == 0) {
                    cur.color_load = DM_TBDR_LOAD_CLEAR;
                    color_cleared_or_discarded = true;
                }
                break;
            case DM_DX_OP_CLEAR_DSV:
                if (cur.total_draws == 0) {
                    cur.depth_load = DM_TBDR_LOAD_CLEAR;
                    depth_cleared_or_discarded = true;
                }
                break;
            case DM_DX_OP_DISCARD_ATTACHMENT:
                if (cur.total_draws == 0 && op.color_rtv_id != UINT32_MAX && !color_cleared_or_discarded) {
                    cur.color_load = DM_TBDR_LOAD_DONT_CARE;
                }
                if (cur.total_draws == 0 && op.dsv_id != UINT32_MAX && !depth_cleared_or_discarded) {
                    cur.depth_load = DM_TBDR_LOAD_DONT_CARE;
                }
                break;
            case DM_DX_OP_DRAW_BATCH:
                if (op.draw_count > UINT32_MAX - cur.total_draws) {
                    cur.total_draws = UINT32_MAX;
                } else {
                    cur.total_draws += op.draw_count;
                }
                break;
            case DM_DX_OP_RESOLVE_MSAA:
                cur.color_store = DM_TBDR_STORE_MULTISAMPLE_RESOLVE;
                break;
            case DM_DX_OP_READ_SRV_BARRIER:
                break;
        }
    }
    out_plan->coalesced_pass_count = pass_idx;

    // Infer StoreActionDontCare for transient attachments not read externally or exported
    for (uint32_t p = 0; p < out_plan->coalesced_pass_count; ++p) {
        dm_tbdr_metal_pass_t &mp = out_plan->passes[p];
        if (mp.dsv_id != UINT32_MAX) {
            for (size_t a = 0; a < attachment_count; ++a) {
                if (attachments[a].attachment_id == mp.dsv_id &&
                    !attachments[a].is_backbuffer_or_exported && !read_externally[a]) {
                    mp.depth_store = DM_TBDR_STORE_DONT_CARE;
                }
            }
        }
        if (mp.color_rtv_id != UINT32_MAX && mp.color_store == DM_TBDR_STORE_STORE) {
            for (size_t a = 0; a < attachment_count; ++a) {
                if (attachments[a].attachment_id == mp.color_rtv_id &&
                    !attachments[a].is_backbuffer_or_exported && !read_externally[a]) {
                    mp.color_store = DM_TBDR_STORE_DONT_CARE;
                }
            }
        }
    }

    // Determine Memoryless promotion & DRAM savings per attachment
    out_plan->attachment_count = static_cast<uint32_t>(attachment_count);
    for (size_t a = 0; a < attachment_count; ++a) {
        const dm_dx_attachment_desc_t &att = attachments[a];
        const uint64_t samples = att.sample_count > 0 ? static_cast<uint64_t>(att.sample_count) : 1ULL;
        const uint64_t pixels = safe_mul_u64(static_cast<uint64_t>(att.width), static_cast<uint64_t>(att.height));
        const uint64_t sample_pixels = safe_mul_u64(pixels, samples);
        const uint64_t dram = safe_mul_u64(sample_pixels, static_cast<uint64_t>(att.bytes_per_pixel));

        bool used_load = false;
        bool used_store = false;
        bool used_in_any_pass = false;
        for (uint32_t p = 0; p < out_plan->coalesced_pass_count; ++p) {
            const dm_tbdr_metal_pass_t &mp = out_plan->passes[p];
            if (mp.color_rtv_id == att.attachment_id) {
                used_in_any_pass = true;
                if (mp.color_load == DM_TBDR_LOAD_LOAD) used_load = true;
                if (mp.color_store == DM_TBDR_STORE_STORE) used_store = true;
            }
            if (mp.dsv_id == att.attachment_id) {
                used_in_any_pass = true;
                if (mp.depth_load == DM_TBDR_LOAD_LOAD) used_load = true;
                if (mp.depth_store == DM_TBDR_STORE_STORE) used_store = true;
            }
        }

        const bool can_memoryless = used_in_any_pass &&
                                    !att.is_backbuffer_or_exported &&
                                    !read_externally[a] &&
                                    !resolved_target[a] &&
                                    !used_load && !used_store &&
                                    (att.is_depth_stencil || att.sample_count > 1);

        dm_tbdr_attachment_plan_t &ap = out_plan->attachments[a];
        ap.attachment_id = att.attachment_id;
        ap.promote_memoryless = can_memoryless;
        ap.baseline_dram_bytes = dram;
        ap.optimized_dram_bytes = can_memoryless ? 0 : dram;

        out_plan->total_baseline_dram_bytes = safe_add_u64(out_plan->total_baseline_dram_bytes, ap.baseline_dram_bytes);
        out_plan->total_optimized_dram_bytes = safe_add_u64(out_plan->total_optimized_dram_bytes, ap.optimized_dram_bytes);
    }

    return true;
}
