#include "dm_dxgi_select.hpp"
#include "dm_metrics.hpp"
#include "dm_png_writer.hpp"

#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#ifdef DM_HAS_SIGNED_DXIL
#include "d3d12_dxil_compute.h"
#endif

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kWidth = 512;
constexpr UINT kHeight = 512;

struct VertexPosColor {
    float x, y, z;
    float r, g, b, a;
};

struct GridVertex {
    float x, y;
    uint32_t quad_id;
};

struct GridCB {
    float colors[16][4];
};

struct BenchCB {
    float transform[4];
    float color[4];
};

inline D3D12_HEAP_PROPERTIES make_heap_props(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES p{};
    p.Type = type;
    p.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    p.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
    return p;
}

inline D3D12_RESOURCE_DESC make_buffer_desc(UINT64 size, D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    d.Width = size;
    d.Height = 1;
    d.DepthOrArraySize = 1;
    d.MipLevels = 1;
    d.Format = DXGI_FORMAT_UNKNOWN;
    d.SampleDesc = {1, 0};
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    d.Flags = flags;
    return d;
}

inline D3D12_RESOURCE_DESC make_tex2d_desc(UINT w, UINT h, DXGI_FORMAT fmt,
                                           D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    d.Width = w;
    d.Height = h;
    d.DepthOrArraySize = 1;
    d.MipLevels = 1;
    d.Format = fmt;
    d.SampleDesc = {1, 0};
    d.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    d.Flags = flags;
    return d;
}

inline D3D12_RESOURCE_BARRIER make_transition(ID3D12Resource* res,
                                              D3D12_RESOURCE_STATES before,
                                              D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    return b;
}

inline D3D12_RASTERIZER_DESC default_rasterizer() {
    D3D12_RASTERIZER_DESC r{};
    r.FillMode = D3D12_FILL_MODE_SOLID;
    r.CullMode = D3D12_CULL_MODE_NONE;
    r.DepthClipEnable = TRUE;
    return r;
}

inline D3D12_BLEND_DESC default_blend() {
    D3D12_BLEND_DESC b{};
    b.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    return b;
}

inline D3D12_DEPTH_STENCIL_DESC default_depth_off() {
    D3D12_DEPTH_STENCIL_DESC ds{};
    ds.DepthEnable = FALSE;
    ds.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    ds.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    return ds;
}

bool compile_hlsl(const char* src, const char* entry, const char* target,
                  ComPtr<ID3DBlob>& blob, std::string& err) {
    ComPtr<ID3DBlob> e;
    HRESULT hr = D3DCompile(src, std::strlen(src), entry, nullptr, nullptr,
                            entry, target, D3DCOMPILE_ENABLE_STRICTNESS, 0,
                            &blob, &e);
    if (FAILED(hr)) {
        if (e) {
            err.assign(static_cast<const char*>(e->GetBufferPointer()), e->GetBufferSize());
        } else {
            err = "D3DCompile failed HR=" + std::to_string(static_cast<long>(hr));
        }
        return false;
    }
    return true;
}

struct D3D12Runner {
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> cmd;
    ComPtr<ID3D12Fence> fence;
    HANDLE event_handle = nullptr;
    UINT64 fence_val = 0;

    ComPtr<ID3D12DescriptorHeap> rtv_heap;
    ComPtr<ID3D12Resource> rt_tex;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_handle{};

    ~D3D12Runner() {
        if (event_handle) CloseHandle(event_handle);
    }

    bool init(IDXGIAdapter1* adapter) {
        if (FAILED(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)))) {
            return false;
        }
        D3D12_COMMAND_QUEUE_DESC qd{};
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        if (FAILED(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) return false;
        if (FAILED(dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&alloc)))) return false;
        if (FAILED(dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc.Get(), nullptr, IID_PPV_ARGS(&cmd)))) return false;
        cmd->Close();
        if (FAILED(dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) return false;
        event_handle = CreateEventA(nullptr, FALSE, FALSE, nullptr);
        if (!event_handle) return false;

        D3D12_DESCRIPTOR_HEAP_DESC hd{};
        hd.NumDescriptors = 4;
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        if (FAILED(dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&rtv_heap)))) return false;
        rtv_handle = rtv_heap->GetCPUDescriptorHandleForHeapStart();

        auto hp = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
        auto td = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        D3D12_CLEAR_VALUE cv{};
        cv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td,
                                                D3D12_RESOURCE_STATE_COMMON, &cv,
                                                IID_PPV_ARGS(&rt_tex)))) {
            return false;
        }
        dev->CreateRenderTargetView(rt_tex.Get(), nullptr, rtv_handle);
        return true;
    }

    void wait_idle() {
        ++fence_val;
        queue->Signal(fence.Get(), fence_val);
        if (fence->GetCompletedValue() < fence_val) {
            fence->SetEventOnCompletion(fence_val, event_handle);
            WaitForSingleObject(event_handle, INFINITE);
        }
    }

    bool reset_cmd(ID3D12PipelineState* pso = nullptr) {
        if (FAILED(alloc->Reset())) return false;
        return SUCCEEDED(cmd->Reset(alloc.Get(), pso));
    }

    void submit_and_wait() {
        cmd->Close();
        ID3D12CommandList* lists[1] = {cmd.Get()};
        queue->ExecuteCommandLists(1, lists);
        wait_idle();
    }

    bool create_upload_buffer(const void* data, UINT64 size, ComPtr<ID3D12Resource>& out_res) {
        auto hp = make_heap_props(D3D12_HEAP_TYPE_UPLOAD);
        auto bd = make_buffer_desc(size);
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd,
                                                D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                                                IID_PPV_ARGS(&out_res)))) {
            return false;
        }
        if (data) {
            void* mapped = nullptr;
            D3D12_RANGE rr{0, 0};
            if (FAILED(out_res->Map(0, &rr, &mapped))) return false;
            std::memcpy(mapped, data, static_cast<size_t>(size));
            out_res->Unmap(0, nullptr);
        }
        return true;
    }

    bool create_default_buffer_uploaded(const void* data, UINT64 size,
                                        D3D12_RESOURCE_STATES final_state,
                                        ComPtr<ID3D12Resource>& def_res) {
        ComPtr<ID3D12Resource> up;
        if (!create_upload_buffer(data, size, up)) return false;
        auto hp = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
        auto bd = make_buffer_desc(size);
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd,
                                                D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                IID_PPV_ARGS(&def_res)))) {
            return false;
        }
        reset_cmd();
        cmd->CopyBufferRegion(def_res.Get(), 0, up.Get(), 0, size);
        auto b = make_transition(def_res.Get(), D3D12_RESOURCE_STATE_COPY_DEST, final_state);
        cmd->ResourceBarrier(1, &b);
        submit_and_wait();
        return true;
    }

    bool readback_tex_to_png(ID3D12Resource* tex, D3D12_RESOURCE_STATES cur_state,
                             const std::string& out_dir, dm::TestRecord& rec,
                             std::vector<uint8_t>* out_px = nullptr) {
        const auto desc = tex->GetDesc();
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};
        UINT num_rows = 0;
        UINT64 row_size = 0, total_bytes = 0;
        dev->GetCopyableFootprints(&desc, 0, 1, 0, &fp, &num_rows, &row_size, &total_bytes);

        auto hp = make_heap_props(D3D12_HEAP_TYPE_READBACK);
        auto bd = make_buffer_desc(total_bytes);
        ComPtr<ID3D12Resource> rb;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd,
                                                D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                IID_PPV_ARGS(&rb)))) {
            rec.detail = "CreateCommittedResource readback failed";
            return false;
        }

        reset_cmd();
        if (cur_state != D3D12_RESOURCE_STATE_COPY_SOURCE) {
            auto b0 = make_transition(tex, cur_state, D3D12_RESOURCE_STATE_COPY_SOURCE);
            cmd->ResourceBarrier(1, &b0);
        }
        D3D12_TEXTURE_COPY_LOCATION dst_loc{};
        dst_loc.pResource = rb.Get();
        dst_loc.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        dst_loc.PlacedFootprint = fp;
        D3D12_TEXTURE_COPY_LOCATION src_loc{};
        src_loc.pResource = tex;
        src_loc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src_loc.SubresourceIndex = 0;
        cmd->CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, nullptr);
        if (cur_state != D3D12_RESOURCE_STATE_COPY_SOURCE) {
            auto b1 = make_transition(tex, D3D12_RESOURCE_STATE_COPY_SOURCE, cur_state);
            cmd->ResourceBarrier(1, &b1);
        }
        submit_and_wait();

        void* mapped = nullptr;
        D3D12_RANGE rr{0, static_cast<SIZE_T>(total_bytes)};
        if (FAILED(rb->Map(0, &rr, &mapped))) {
            rec.detail = "Readback map failed";
            return false;
        }
        std::vector<uint8_t> tight(static_cast<size_t>(kWidth) * kHeight * 4u);
        const uint8_t* src = static_cast<const uint8_t*>(mapped) + fp.Offset;
        for (UINT y = 0; y < kHeight; ++y) {
            std::memcpy(tight.data() + static_cast<size_t>(y) * kWidth * 4u,
                        src + static_cast<size_t>(y) * fp.Footprint.RowPitch,
                        static_cast<size_t>(kWidth) * 4u);
        }
        D3D12_RANGE empty{0, 0};
        rb->Unmap(0, &empty);

        rec.png_file = rec.name + ".png";
        if (!dm::write_png_rgba8(dm::join_path(out_dir, rec.png_file), kWidth, kHeight,
                                 tight.data(), kWidth * 4u)) {
            rec.detail = "PNG write failed";
            return false;
        }
        rec.pixel_checksum = dm::hex64(dm::fnv1a64(tight.data(), tight.size()));
        if (out_px) *out_px = std::move(tight);
        return true;
    }

    void set_viewport_scissor() {
        D3D12_VIEWPORT vp{0.0f, 0.0f, static_cast<float>(kWidth), static_cast<float>(kHeight), 0.0f, 1.0f};
        D3D12_RECT sc{0, 0, static_cast<LONG>(kWidth), static_cast<LONG>(kHeight)};
        cmd->RSSetViewports(1, &vp);
        cmd->RSSetScissorRects(1, &sc);
    }

    std::string max_feature_level_str() const {
        const D3D_FEATURE_LEVEL list[] = {
            D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2};
        D3D12_FEATURE_DATA_FEATURE_LEVELS data{};
        data.NumFeatureLevels = static_cast<UINT>(std::size(list));
        data.pFeatureLevelsRequested = list;
        if (SUCCEEDED(dev->CheckFeatureSupport(D3D12_FEATURE_FEATURE_LEVELS, &data, sizeof(data)))) {
            switch (data.MaxSupportedFeatureLevel) {
                case D3D_FEATURE_LEVEL_12_2: return "12_2";
                case D3D_FEATURE_LEVEL_12_1: return "12_1";
                case D3D_FEATURE_LEVEL_12_0: return "12_0";
                case D3D_FEATURE_LEVEL_11_1: return "11_1";
                case D3D_FEATURE_LEVEL_11_0: return "11_0";
                default: break;
            }
        }
        return "11_0";
    }
};

bool create_root_sig(ID3D12Device* dev, const D3D12_ROOT_SIGNATURE_DESC& desc,
                     ComPtr<ID3D12RootSignature>& out_rs, std::string& err) {
    ComPtr<ID3DBlob> sig, e;
    HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &e);
    if (FAILED(hr)) {
        if (e) err.assign(static_cast<const char*>(e->GetBufferPointer()), e->GetBufferSize());
        return false;
    }
    return SUCCEEDED(dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&out_rs)));
}

const char* kPosColorHLSL = R"(
struct VSIn {
    float3 pos : POSITION;
    float4 col : COLOR0;
};
struct PSIn {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
};
PSIn VSMain(VSIn input) {
    PSIn o;
    o.pos = float4(input.pos, 1.0f);
    o.col = input.col;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return input.col;
}
)";

const char* kComputeFallbackHLSL = R"(
RWTexture2D<float4> outTex : register(u0);
RWStructuredBuffer<uint> outHashes : register(u1);
groupshared uint tile_sum[64];

[numthreads(8, 8, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint gidx : SV_GroupIndex) {
    float x = (float)dtid.x / 512.0f;
    float y = (float)dtid.y / 512.0f;
    float wave = 0.5f + 0.5f * cos(x * 22.0f + y * 9.0f) * sin(y * 22.0f - x * 9.0f);
    float radial = 0.5f + 0.5f * sin(length(float2(x - 0.5f, y - 0.5f)) * 36.0f);
    outTex[dtid.xy] = float4(radial, wave, 1.0f - 0.5f * (x + y), 1.0f);

    uint h = (dtid.x * 2654435761u) ^ (dtid.y * 2246822519u) ^ 0x85EBCA6Bu;
    tile_sum[gidx] = h;
    GroupMemoryBarrierWithGroupSync();
    if (gidx == 0u) {
        uint acc = 0u;
        [unroll]
        for (uint i = 0u; i < 64u; ++i) {
            acc += tile_sum[i];
        }
        outHashes[gid.y * 64u + gid.x] = acc;
    }
}
)";

}  // namespace

int main(int argc, char** argv) {
    const dm::CliOptions opts = dm::parse_cli(argc, argv);
    if (!dm::ensure_directory_recursive(opts.out_dir)) {
        std::cerr << "Failed to create output directory: " << opts.out_dir << "\n";
        return 1;
    }

    dm::SelectedAdapter selected;
    if (!dm::select_hardware_adapter(opts.adapter_filter, selected)) {
        std::cerr << "No DXGI hardware adapter found.\n";
        return 1;
    }

    D3D12Runner r;
    if (!r.init(selected.adapter.Get())) {
        std::cerr << "D3D12 initialization failed.\n";
        return 1;
    }

    const std::string max_fl = r.max_feature_level_str();
    std::cout << "[D3D12] Adapter: " << selected.meta.description
              << " | Max FL: " << max_fl << "\n";

    std::vector<dm::TestRecord> records;

    // 1. d3d12_01_clear_rtv
    {
        dm::TestRecord rec;
        rec.name = "d3d12_01_clear_rtv";
        const double t0 = dm::now_ms();
        r.reset_cmd();
        auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
        r.cmd->ResourceBarrier(1, &b0);
        const float cc[4] = {0.72f, 0.24f, 0.36f, 1.0f};
        r.cmd->ClearRenderTargetView(r.rtv_handle, cc, 0, nullptr);
        auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
        r.cmd->ResourceBarrier(1, &b1);
        r.submit_and_wait();

        std::vector<uint8_t> px;
        if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec, &px)) {
            const size_t c = (static_cast<size_t>(kHeight / 2) * kWidth + (kWidth / 2)) * 4u;
            const int dr = std::abs(static_cast<int>(px[c + 0]) - 184);
            const int dg = std::abs(static_cast<int>(px[c + 1]) - 61);
            const int db = std::abs(static_cast<int>(px[c + 2]) - 92);
            rec.status = (dr <= 2 && dg <= 2 && db <= 2) ? "pass" : "fail";
            rec.detail = rec.status == "pass" ? "ClearRenderTargetView matched" : "Clear value mismatch";
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 2. d3d12_02_triangle_pso
    {
        dm::TestRecord rec;
        rec.name = "d3d12_02_triangle_pso";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        ComPtr<ID3D12RootSignature> rs;
        D3D12_ROOT_SIGNATURE_DESC rsd{};
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        if (compile_hlsl(kPosColorHLSL, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(kPosColorHLSL, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pso_desc{};
            pso_desc.pRootSignature = rs.Get();
            pso_desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pso_desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pso_desc.BlendState = default_blend();
            pso_desc.SampleMask = UINT_MAX;
            pso_desc.RasterizerState = default_rasterizer();
            pso_desc.DepthStencilState = default_depth_off();
            pso_desc.InputLayout = {ied, 2};
            pso_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pso_desc.NumRenderTargets = 1;
            pso_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pso_desc.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pso_desc, IID_PPV_ARGS(&pso));

            const VertexPosColor verts[3] = {
                {0.0f, 0.80f, 0.0f, 1.0f, 0.2f, 0.1f, 1.0f},
                {0.80f, -0.75f, 0.0f, 0.1f, 0.9f, 0.3f, 1.0f},
                {-0.80f, -0.75f, 0.0f, 0.2f, 0.3f, 1.0f, 1.0f},
            };
            ComPtr<ID3D12Resource> vb;
            r.create_default_buffer_uploaded(verts, sizeof(verts), D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), sizeof(verts), sizeof(VertexPosColor)};

            r.reset_cmd(pso.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.06f, 0.07f, 0.10f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->DrawInstanced(3, 1, 0, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Graphics PSO + DEFAULT vertex buffer triangle";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 3. d3d12_03_root_constants_cbv
    {
        dm::TestRecord rec;
        rec.name = "d3d12_03_root_constants_cbv";
        const double t0 = dm::now_ms();
        const char* hlsl = R"(
cbuffer RootConsts : register(b0) {
    float4 offset_scale;
};
cbuffer PaletteCB : register(b1) {
    float4 colors[16];
};
struct VSIn {
    float2 pos : POSITION;
    uint quad_id : TEXCOORD0;
};
struct PSIn {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
};
PSIn VSMain(VSIn input) {
    PSIn o;
    o.pos = float4(input.pos * offset_scale.zw + offset_scale.xy, 0.0f, 1.0f);
    o.col = colors[input.quad_id];
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return input.col;
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        D3D12_ROOT_PARAMETER params[2]{};
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[0].Constants = {0, 0, 4};
        params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        params[1].Descriptor = {1, 0};
        params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        D3D12_ROOT_SIGNATURE_DESC rsd{2, params, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3D12RootSignature> rs;
        if (compile_hlsl(hlsl, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(hlsl, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32_UINT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pso_desc{};
            pso_desc.pRootSignature = rs.Get();
            pso_desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pso_desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pso_desc.BlendState = default_blend();
            pso_desc.SampleMask = UINT_MAX;
            pso_desc.RasterizerState = default_rasterizer();
            pso_desc.DepthStencilState = default_depth_off();
            pso_desc.InputLayout = {ied, 2};
            pso_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pso_desc.NumRenderTargets = 1;
            pso_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pso_desc.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pso_desc, IID_PPV_ARGS(&pso));

            std::vector<GridVertex> verts;
            std::vector<uint16_t> indices;
            for (uint32_t gy = 0; gy < 4; ++gy) {
                for (uint32_t gx = 0; gx < 4; ++gx) {
                    const uint32_t qid = gy * 4 + gx;
                    const float x0 = -0.82f + gx * 0.43f;
                    const float y0 = -0.82f + gy * 0.43f;
                    const uint16_t base = static_cast<uint16_t>(verts.size());
                    verts.push_back({x0, y0, qid});
                    verts.push_back({x0, y0 + 0.35f, qid});
                    verts.push_back({x0 + 0.35f, y0 + 0.35f, qid});
                    verts.push_back({x0 + 0.35f, y0, qid});
                    indices.push_back(base + 0);
                    indices.push_back(base + 1);
                    indices.push_back(base + 2);
                    indices.push_back(base + 0);
                    indices.push_back(base + 2);
                    indices.push_back(base + 3);
                }
            }
            GridCB gcb{};
            for (int i = 0; i < 16; ++i) {
                gcb.colors[i][0] = 0.90f - 0.04f * static_cast<float>(i);
                gcb.colors[i][1] = 0.25f + 0.22f * static_cast<float>(i % 4);
                gcb.colors[i][2] = 0.20f + 0.24f * static_cast<float>(i / 4);
                gcb.colors[i][3] = 1.0f;
            }
            ComPtr<ID3D12Resource> vb, ib, cb;
            r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(GridVertex),
                                             D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            r.create_default_buffer_uploaded(indices.data(), indices.size() * sizeof(uint16_t),
                                             D3D12_RESOURCE_STATE_INDEX_BUFFER, ib);
            r.create_upload_buffer(&gcb, sizeof(GridCB), cb);

            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(GridVertex)), sizeof(GridVertex)};
            D3D12_INDEX_BUFFER_VIEW ibv{ib->GetGPUVirtualAddress(), static_cast<UINT>(indices.size() * sizeof(uint16_t)), DXGI_FORMAT_R16_UINT};

            r.reset_cmd(pso.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.05f, 0.05f, 0.08f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            const float rc[4] = {0.0f, 0.0f, 0.95f, 0.95f};
            r.cmd->SetGraphicsRoot32BitConstants(0, 4, rc, 0);
            r.cmd->SetGraphicsRootConstantBufferView(1, cb->GetGPUVirtualAddress());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->IASetIndexBuffer(&ibv);
            r.cmd->DrawIndexedInstanced(static_cast<UINT>(indices.size()), 1, 0, 0, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "32-bit root constants + inline root CBV grid";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 4. d3d12_04_depth_stencil_3d
    {
        dm::TestRecord rec;
        rec.name = "d3d12_04_depth_stencil_3d";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        ComPtr<ID3D12RootSignature> rs;
        D3D12_ROOT_SIGNATURE_DESC rsd{};
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        if (compile_hlsl(kPosColorHLSL, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(kPosColorHLSL, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pso_desc{};
            pso_desc.pRootSignature = rs.Get();
            pso_desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pso_desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pso_desc.BlendState = default_blend();
            pso_desc.SampleMask = UINT_MAX;
            pso_desc.RasterizerState = default_rasterizer();
            pso_desc.DepthStencilState.DepthEnable = TRUE;
            pso_desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
            pso_desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
            pso_desc.InputLayout = {ied, 2};
            pso_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pso_desc.NumRenderTargets = 1;
            pso_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pso_desc.DSVFormat = DXGI_FORMAT_D32_FLOAT;
            pso_desc.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pso_desc, IID_PPV_ARGS(&pso));

            D3D12_DESCRIPTOR_HEAP_DESC dhd{D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
            ComPtr<ID3D12DescriptorHeap> dsv_heap;
            r.dev->CreateDescriptorHeap(&dhd, IID_PPV_ARGS(&dsv_heap));
            auto dsv_h = dsv_heap->GetCPUDescriptorHandleForHeapStart();

            auto hp = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto dtd = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_D32_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
            D3D12_CLEAR_VALUE dcv{};
            dcv.Format = DXGI_FORMAT_D32_FLOAT;
            dcv.DepthStencil.Depth = 1.0f;
            ComPtr<ID3D12Resource> dtex;
            r.dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &dtd,
                                           D3D12_RESOURCE_STATE_DEPTH_WRITE, &dcv, IID_PPV_ARGS(&dtex));
            r.dev->CreateDepthStencilView(dtex.Get(), nullptr, dsv_h);

            const VertexPosColor verts[6] = {
                {-0.85f,  0.75f, 0.2f, 0.95f, 0.25f, 0.15f, 1.0f},
                { 0.85f,  0.00f, 0.8f, 1.00f, 0.65f, 0.15f, 1.0f},
                {-0.85f, -0.75f, 0.2f, 0.85f, 0.20f, 0.15f, 1.0f},
                { 0.85f,  0.75f, 0.2f, 0.15f, 0.85f, 0.95f, 1.0f},
                { 0.85f, -0.75f, 0.2f, 0.15f, 0.55f, 0.95f, 1.0f},
                {-0.85f,  0.00f, 0.8f, 0.25f, 0.95f, 0.65f, 1.0f},
            };
            ComPtr<ID3D12Resource> vb;
            r.create_default_buffer_uploaded(verts, sizeof(verts), D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), sizeof(verts), sizeof(VertexPosColor)};

            r.reset_cmd(pso.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.06f, 0.07f, 0.11f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->ClearDepthStencilView(dsv_h, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, &dsv_h);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->DrawInstanced(6, 1, 0, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "D32_FLOAT depth test intersecting triangles";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 5. d3d12_05_srv_descriptor_table
    {
        dm::TestRecord rec;
        rec.name = "d3d12_05_srv_descriptor_table";
        const double t0 = dm::now_ms();
        const char* hlsl = R"(
Texture2D tex0 : register(t0);
SamplerState samp0 : register(s0);
struct VSIn {
    float2 pos : POSITION;
    float2 uv  : TEXCOORD0;
};
struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};
PSIn VSMain(VSIn input) {
    PSIn o;
    o.pos = float4(input.pos, 0.0f, 1.0f);
    o.uv = input.uv;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return tex0.Sample(samp0, input.uv);
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        D3D12_DESCRIPTOR_RANGE range{};
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        range.NumDescriptors = 1;
        range.BaseShaderRegister = 0;
        range.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;

        D3D12_ROOT_PARAMETER param{};
        param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        param.DescriptorTable = {1, &range};
        param.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_STATIC_SAMPLER_DESC ss{};
        ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        ss.MaxLOD = D3D12_FLOAT32_MAX;
        ss.ShaderRegister = 0;
        ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_ROOT_SIGNATURE_DESC rsd{1, &param, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3D12RootSignature> rs;
        if (compile_hlsl(hlsl, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(hlsl, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pso_desc{};
            pso_desc.pRootSignature = rs.Get();
            pso_desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pso_desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pso_desc.BlendState = default_blend();
            pso_desc.SampleMask = UINT_MAX;
            pso_desc.RasterizerState = default_rasterizer();
            pso_desc.DepthStencilState = default_depth_off();
            pso_desc.InputLayout = {ied, 2};
            pso_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pso_desc.NumRenderTargets = 1;
            pso_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pso_desc.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pso_desc, IID_PPV_ARGS(&pso));

            constexpr UINT TW = 128;
            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto tdesc = make_tex2d_desc(TW, TW, DXGI_FORMAT_R8G8B8A8_UNORM);
            ComPtr<ID3D12Resource> tex;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &tdesc,
                                           D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&tex));

            D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};
            UINT rows = 0;
            UINT64 row_sz = 0, total_sz = 0;
            r.dev->GetCopyableFootprints(&tdesc, 0, 1, 0, &fp, &rows, &row_sz, &total_sz);
            ComPtr<ID3D12Resource> tex_up;
            r.create_upload_buffer(nullptr, total_sz, tex_up);
            void* mapped = nullptr;
            D3D12_RANGE empty{0, 0};
            tex_up->Map(0, &empty, &mapped);
            uint8_t* dst = static_cast<uint8_t*>(mapped) + fp.Offset;
            for (UINT y = 0; y < TW; ++y) {
                uint8_t* row = dst + static_cast<size_t>(y) * fp.Footprint.RowPitch;
                for (UINT x = 0; x < TW; ++x) {
                    const bool chk = ((x / 16) + (y / 16)) % 2 == 0;
                    row[x * 4 + 0] = static_cast<uint8_t>(chk ? 245 : (x * 2));
                    row[x * 4 + 1] = static_cast<uint8_t>(chk ? (y * 2) : 230);
                    row[x * 4 + 2] = static_cast<uint8_t>(chk ? 45 : (255 - x * 2));
                    row[x * 4 + 3] = 255;
                }
            }
            tex_up->Unmap(0, nullptr);

            D3D12_DESCRIPTOR_HEAP_DESC shd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> srv_heap;
            r.dev->CreateDescriptorHeap(&shd, IID_PPV_ARGS(&srv_heap));
            r.dev->CreateShaderResourceView(tex.Get(), nullptr, srv_heap->GetCPUDescriptorHandleForHeapStart());

            const float quad[24] = {
                -0.85f, -0.85f, 0.0f, 2.0f,
                -0.85f,  0.85f, 0.0f, 0.0f,
                 0.85f,  0.85f, 2.0f, 0.0f,
                -0.85f, -0.85f, 0.0f, 2.0f,
                 0.85f,  0.85f, 2.0f, 0.0f,
                 0.85f, -0.85f, 2.0f, 2.0f,
            };
            ComPtr<ID3D12Resource> vb;
            r.create_default_buffer_uploaded(quad, sizeof(quad), D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), sizeof(quad), sizeof(float) * 4};

            r.reset_cmd(pso.Get());
            D3D12_TEXTURE_COPY_LOCATION dloc{};
            dloc.pResource = tex.Get();
            dloc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            dloc.SubresourceIndex = 0;
            D3D12_TEXTURE_COPY_LOCATION sloc{};
            sloc.pResource = tex_up.Get();
            sloc.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            sloc.PlacedFootprint = fp;
            r.cmd->CopyTextureRegion(&dloc, 0, 0, 0, &sloc, nullptr);

            D3D12_RESOURCE_BARRIER bs[2] = {
                make_transition(tex.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET),
            };
            r.cmd->ResourceBarrier(2, bs);

            const float bg[4] = {0.04f, 0.05f, 0.08f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            ID3D12DescriptorHeap* heaps[1] = {srv_heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->SetGraphicsRootDescriptorTable(0, srv_heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->DrawInstanced(6, 1, 0, 0);
            auto b_end = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b_end);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Shader-visible SRV descriptor heap + static sampler";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 6. d3d12_06_multi_pso_blend
    {
        dm::TestRecord rec;
        rec.name = "d3d12_06_multi_pso_blend";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        ComPtr<ID3D12RootSignature> rs;
        D3D12_ROOT_SIGNATURE_DESC rsd{};
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        if (compile_hlsl(kPosColorHLSL, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(kPosColorHLSL, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
            pd.pRootSignature = rs.Get();
            pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pd.BlendState = default_blend();
            pd.SampleMask = UINT_MAX;
            pd.RasterizerState = default_rasterizer();
            pd.DepthStencilState = default_depth_off();
            pd.InputLayout = {ied, 2};
            pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd.NumRenderTargets = 1;
            pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pd.SampleDesc = {1, 0};

            ComPtr<ID3D12PipelineState> pso_opaque, pso_alpha, pso_add;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso_opaque));

            pd.BlendState.RenderTarget[0].BlendEnable = TRUE;
            pd.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_SRC_ALPHA;
            pd.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            pd.BlendState.RenderTarget[0].BlendOp = D3D12_BLEND_OP_ADD;
            pd.BlendState.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE;
            pd.BlendState.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ZERO;
            pd.BlendState.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_ADD;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso_alpha));

            pd.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_ONE;
            pd.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_ONE;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso_add));

            auto push_q = [](std::vector<VertexPosColor>& v, float x0, float y0, float x1, float y1,
                             float r_, float g_, float b_, float a_) {
                v.push_back({x0, y0, 0, r_, g_, b_, a_});
                v.push_back({x0, y1, 0, r_, g_, b_, a_});
                v.push_back({x1, y1, 0, r_, g_, b_, a_});
                v.push_back({x0, y0, 0, r_, g_, b_, a_});
                v.push_back({x1, y1, 0, r_, g_, b_, a_});
                v.push_back({x1, y0, 0, r_, g_, b_, a_});
            };
            std::vector<VertexPosColor> verts;
            push_q(verts, -0.9f, -0.9f, 0.9f, 0.9f, 0.14f, 0.16f, 0.22f, 1.0f);
            push_q(verts, -0.7f, -0.55f, 0.3f, 0.65f, 0.95f, 0.25f, 0.25f, 0.60f);
            push_q(verts, -0.3f, -0.65f, 0.7f, 0.55f, 0.20f, 0.85f, 0.95f, 0.55f);
            push_q(verts, -0.25f, -0.25f, 0.25f, 0.25f, 0.35f, 0.30f, 0.10f, 1.0f);

            ComPtr<ID3D12Resource> vb;
            r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(VertexPosColor),
                                             D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(VertexPosColor)), sizeof(VertexPosColor)};

            r.reset_cmd(pso_opaque.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.05f, 0.06f, 0.08f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->DrawInstanced(6, 1, 0, 0);
            r.cmd->SetPipelineState(pso_alpha.Get());
            r.cmd->DrawInstanced(12, 1, 6, 0);
            r.cmd->SetPipelineState(pso_add.Get());
            r.cmd->DrawInstanced(6, 1, 18, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "3 PSO transitions (opaque, alpha, additive)";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 7. d3d12_07_compute_uav
    {
        dm::TestRecord rec;
        rec.name = "d3d12_07_compute_uav";
        rec.has_compute_checksum = true;
        const double t0 = dm::now_ms();
        std::string err;
        D3D12_SHADER_BYTECODE cs_bc{};
        ComPtr<ID3DBlob> cs_blob;
#ifdef DM_HAS_SIGNED_DXIL
        cs_bc = {kComputeDXIL, sizeof(kComputeDXIL)};
        rec.shader_model = "cs_6_0 (DXIL)";
        bool shader_ok = true;
#else
        bool shader_ok = compile_hlsl(kComputeFallbackHLSL, "CSMain", "cs_5_1", cs_blob, err);
        if (shader_ok) {
            cs_bc = {cs_blob->GetBufferPointer(), cs_blob->GetBufferSize()};
            rec.shader_model = "cs_5_1 (DXBC)";
        }
#endif
        D3D12_DESCRIPTOR_RANGE range{};
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
        range.NumDescriptors = 2;
        range.BaseShaderRegister = 0;
        range.OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
        D3D12_ROOT_PARAMETER param{};
        param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        param.DescriptorTable = {1, &range};
        D3D12_ROOT_SIGNATURE_DESC rsd{1, &param, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};
        ComPtr<ID3D12RootSignature> rs;
        if (shader_ok && create_root_sig(r.dev.Get(), rsd, rs, err)) {
            D3D12_COMPUTE_PIPELINE_STATE_DESC cpd{};
            cpd.pRootSignature = rs.Get();
            cpd.CS = cs_bc;
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateComputePipelineState(&cpd, IID_PPV_ARGS(&pso));

            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto tdesc = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            ComPtr<ID3D12Resource> uav_tex;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &tdesc,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&uav_tex));

            constexpr UINT kGroups = 64u * 64u;
            auto bdesc = make_buffer_desc(kGroups * sizeof(uint32_t), D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            ComPtr<ID3D12Resource> uav_buf;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &bdesc,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&uav_buf));

            auto hp_rb = make_heap_props(D3D12_HEAP_TYPE_READBACK);
            auto rb_desc = make_buffer_desc(kGroups * sizeof(uint32_t));
            ComPtr<ID3D12Resource> rb_buf;
            r.dev->CreateCommittedResource(&hp_rb, D3D12_HEAP_FLAG_NONE, &rb_desc,
                                           D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&rb_buf));

            D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> heap;
            r.dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap));
            const UINT inc = r.dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            auto h0 = heap->GetCPUDescriptorHandleForHeapStart();
            r.dev->CreateUnorderedAccessView(uav_tex.Get(), nullptr, nullptr, h0);
            D3D12_CPU_DESCRIPTOR_HANDLE h1{h0.ptr + inc};
            D3D12_UNORDERED_ACCESS_VIEW_DESC buav{};
            buav.Format = DXGI_FORMAT_UNKNOWN;
            buav.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            buav.Buffer.NumElements = kGroups;
            buav.Buffer.StructureByteStride = sizeof(uint32_t);
            r.dev->CreateUnorderedAccessView(uav_buf.Get(), nullptr, &buav, h1);

            r.reset_cmd(pso.Get());
            ID3D12DescriptorHeap* heaps[1] = {heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetComputeRootSignature(rs.Get());
            r.cmd->SetComputeRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->Dispatch(64, 64, 1);

            auto bb = make_transition(uav_buf.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
            r.cmd->ResourceBarrier(1, &bb);
            r.cmd->CopyBufferRegion(rb_buf.Get(), 0, uav_buf.Get(), 0, kGroups * sizeof(uint32_t));
            r.submit_and_wait();

            void* mapped = nullptr;
            D3D12_RANGE rr{0, kGroups * sizeof(uint32_t)};
            uint64_t gpu_sum = 0;
            if (SUCCEEDED(rb_buf->Map(0, &rr, &mapped))) {
                const uint32_t* p = static_cast<const uint32_t*>(mapped);
                for (UINT i = 0; i < kGroups; ++i) gpu_sum += static_cast<uint64_t>(p[i]);
                D3D12_RANGE empty{0, 0};
                rb_buf->Unmap(0, &empty);
            }

            uint64_t expected_sum = 0;
            for (uint32_t gy = 0; gy < 64; ++gy) {
                for (uint32_t gx = 0; gx < 64; ++gx) {
                    uint32_t acc = 0;
                    for (uint32_t ly = 0; ly < 8; ++ly) {
                        for (uint32_t lx = 0; lx < 8; ++lx) {
                            const uint32_t x = gx * 8u + lx;
                            const uint32_t y = gy * 8u + ly;
                            acc += (x * 2654435761u) ^ (y * 2246822519u) ^ 0x85EBCA6Bu;
                        }
                    }
                    expected_sum += static_cast<uint64_t>(acc);
                }
            }
            rec.compute_checksum = dm::hex64(gpu_sum);
            rec.expected_compute_checksum = dm::hex64(expected_sum);
            if (r.readback_tex_to_png(uav_tex.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, opts.out_dir, rec)) {
                rec.status = (gpu_sum == expected_sum) ? "pass" : "fail";
                rec.detail = rec.status == "pass" ? ("Compute UAV texture + buffer bit-exact (" + rec.shader_model + ")")
                                                  : "Compute checksum mismatch";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 8. d3d12_08_multi_pass_fence
    {
        dm::TestRecord rec;
        rec.name = "d3d12_08_multi_pass_fence";
        const double t0 = dm::now_ms();
        const char* hlsl_p1 = R"(
struct PSIn { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
PSIn VSMain(uint vid : SV_VertexID) {
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    float d = length(input.uv - float2(0.5f, 0.5f));
    float bands = 0.5f + 0.5f * sin(d * 38.0f);
    return float4(input.uv.x, bands, input.uv.y, 1.0f);
}
)";
        const char* hlsl_p2 = R"(
Texture2D srcTex : register(t0);
SamplerState samp0 : register(s0);
struct PSIn { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
PSIn VSMain(uint vid : SV_VertexID) {
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    float4 c = srcTex.Sample(samp0, input.uv);
    float vig = saturate(1.1f - length(input.uv - float2(0.5f, 0.5f)) * 1.2f);
    return float4(c.rgb * vig, 1.0f);
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs1, ps1, vs2, ps2;
        ComPtr<ID3D12RootSignature> rs1, rs2;
        D3D12_ROOT_SIGNATURE_DESC rsd1{};
        D3D12_DESCRIPTOR_RANGE rng{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        D3D12_ROOT_PARAMETER p2{};
        p2.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        p2.DescriptorTable = {1, &rng};
        p2.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC ss{};
        ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        ss.MaxLOD = D3D12_FLOAT32_MAX;
        ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rsd2{1, &p2, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_NONE};

        if (compile_hlsl(hlsl_p1, "VSMain", "vs_5_1", vs1, err) &&
            compile_hlsl(hlsl_p1, "PSMain", "ps_5_1", ps1, err) &&
            compile_hlsl(hlsl_p2, "VSMain", "vs_5_1", vs2, err) &&
            compile_hlsl(hlsl_p2, "PSMain", "ps_5_1", ps2, err) &&
            create_root_sig(r.dev.Get(), rsd1, rs1, err) &&
            create_root_sig(r.dev.Get(), rsd2, rs2, err)) {
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
            pd.pRootSignature = rs1.Get();
            pd.VS = {vs1->GetBufferPointer(), vs1->GetBufferSize()};
            pd.PS = {ps1->GetBufferPointer(), ps1->GetBufferSize()};
            pd.BlendState = default_blend();
            pd.SampleMask = UINT_MAX;
            pd.RasterizerState = default_rasterizer();
            pd.DepthStencilState = default_depth_off();
            pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd.NumRenderTargets = 1;
            pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pd.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso1, pso2;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso1));

            pd.pRootSignature = rs2.Get();
            pd.VS = {vs2->GetBufferPointer(), vs2->GetBufferSize()};
            pd.PS = {ps2->GetBufferPointer(), ps2->GetBufferSize()};
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso2));

            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto tdesc = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
            ComPtr<ID3D12Resource> mid_tex;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &tdesc,
                                           D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr, IID_PPV_ARGS(&mid_tex));
            D3D12_CPU_DESCRIPTOR_HANDLE mid_rtv = r.rtv_handle;
            mid_rtv.ptr += r.dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            r.dev->CreateRenderTargetView(mid_tex.Get(), nullptr, mid_rtv);

            D3D12_DESCRIPTOR_HEAP_DESC shd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> srv_heap;
            r.dev->CreateDescriptorHeap(&shd, IID_PPV_ARGS(&srv_heap));
            r.dev->CreateShaderResourceView(mid_tex.Get(), nullptr, srv_heap->GetCPUDescriptorHandleForHeapStart());

            // Pass 1 command list
            r.reset_cmd(pso1.Get());
            r.cmd->OMSetRenderTargets(1, &mid_rtv, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs1.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->DrawInstanced(3, 1, 0, 0);
            auto bt = make_transition(mid_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            r.cmd->ResourceBarrier(1, &bt);
            r.submit_and_wait();  // Explicit fence wait between submissions

            // Pass 2 command list
            r.reset_cmd(pso2.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            ID3D12DescriptorHeap* heaps[1] = {srv_heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetGraphicsRootSignature(rs2.Get());
            r.cmd->SetGraphicsRootDescriptorTable(0, srv_heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->DrawInstanced(3, 1, 0, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Two-submission RT->SRV fence synchronization";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 9. d3d12_09_execute_indirect
    {
        dm::TestRecord rec;
        rec.name = "d3d12_09_execute_indirect";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        ComPtr<ID3D12RootSignature> rs;
        D3D12_ROOT_SIGNATURE_DESC rsd{};
        rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        if (compile_hlsl(kPosColorHLSL, "VSMain", "vs_5_1", vs, err) &&
            compile_hlsl(kPosColorHLSL, "PSMain", "ps_5_1", ps, err) &&
            create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
            pd.pRootSignature = rs.Get();
            pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            pd.BlendState = default_blend();
            pd.SampleMask = UINT_MAX;
            pd.RasterizerState = default_rasterizer();
            pd.DepthStencilState = default_depth_off();
            pd.InputLayout = {ied, 2};
            pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd.NumRenderTargets = 1;
            pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pd.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));

            std::vector<VertexPosColor> verts;
            std::vector<D3D12_DRAW_ARGUMENTS> args;
            for (int y = 0; y < 8; ++y) {
                for (int x = 0; x < 8; ++x) {
                    const float cx = -0.80f + x * (1.60f / 7.0f);
                    const float cy = -0.80f + y * (1.60f / 7.0f);
                    const float s = 0.085f;
                    const float rr = static_cast<float>(x) / 7.0f;
                    const float gg = static_cast<float>(y) / 7.0f;
                    const float bb = 1.0f - 0.5f * (rr + gg);
                    const UINT start_v = static_cast<UINT>(verts.size());
                    verts.push_back({cx - s, cy - s, 0, rr, gg, bb, 1});
                    verts.push_back({cx - s, cy + s, 0, rr, gg, bb, 1});
                    verts.push_back({cx + s, cy + s, 0, rr, gg, bb, 1});
                    verts.push_back({cx - s, cy - s, 0, rr, gg, bb, 1});
                    verts.push_back({cx + s, cy + s, 0, rr, gg, bb, 1});
                    verts.push_back({cx + s, cy - s, 0, rr, gg, bb, 1});
                    D3D12_DRAW_ARGUMENTS da{6, 1, start_v, 0};
                    args.push_back(da);
                }
            }
            ComPtr<ID3D12Resource> vb, arg_buf;
            r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(VertexPosColor),
                                             D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            r.create_default_buffer_uploaded(args.data(), args.size() * sizeof(D3D12_DRAW_ARGUMENTS),
                                             D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT, arg_buf);

            D3D12_INDIRECT_ARGUMENT_DESC iad{};
            iad.Type = D3D12_INDIRECT_ARGUMENT_TYPE_DRAW;
            D3D12_COMMAND_SIGNATURE_DESC csd{};
            csd.ByteStride = sizeof(D3D12_DRAW_ARGUMENTS);
            csd.NumArgumentDescs = 1;
            csd.pArgumentDescs = &iad;
            ComPtr<ID3D12CommandSignature> cmd_sig;
            r.dev->CreateCommandSignature(&csd, nullptr, IID_PPV_ARGS(&cmd_sig));

            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(VertexPosColor)), sizeof(VertexPosColor)};
            r.reset_cmd(pso.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.04f, 0.04f, 0.07f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->ExecuteIndirect(cmd_sig.Get(), 64, arg_buf.Get(), 0, nullptr, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "64 ExecuteIndirect draws from INDIRECT_ARGUMENT buffer";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 10. d3d12_bench_frame
    dm::BenchStats bench;
    {
        const char* hlsl = R"(
cbuffer BenchCB : register(b0) {
    float4 transform;
    float4 color;
};
struct VSIn { float3 pos : POSITION; float4 col : COLOR0; };
struct PSIn { float4 pos : SV_POSITION; float4 col : COLOR0; };
PSIn VSMain(VSIn input) {
    PSIn o;
    o.pos = float4(input.pos.xy * transform.zw + transform.xy, input.pos.z, 1.0f);
    o.col = input.col * color;
    return o;
}
float4 PSMain(PSIn input) : SV_Target { return input.col; }
)";
        std::string err;
        ComPtr<ID3DBlob> vs, ps;
        D3D12_ROOT_PARAMETER p0{};
        p0.ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        p0.Descriptor = {0, 0};
        p0.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_ROOT_SIGNATURE_DESC rsd{1, &p0, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3D12RootSignature> rs;
        compile_hlsl(hlsl, "VSMain", "vs_5_1", vs, err);
        compile_hlsl(hlsl, "PSMain", "ps_5_1", ps, err);
        create_root_sig(r.dev.Get(), rsd, rs, err);

        const D3D12_INPUT_ELEMENT_DESC ied[] = {
            {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        };
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
        pd.pRootSignature = rs.Get();
        pd.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
        pd.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
        pd.BlendState = default_blend();
        pd.BlendState.RenderTarget[0].BlendEnable = TRUE;
        pd.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_SRC_ALPHA;
        pd.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
        pd.BlendState.RenderTarget[0].BlendOp = D3D12_BLEND_OP_ADD;
        pd.BlendState.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE;
        pd.BlendState.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ZERO;
        pd.BlendState.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_ADD;
        pd.SampleMask = UINT_MAX;
        pd.RasterizerState = default_rasterizer();
        pd.DepthStencilState = default_depth_off();
        pd.InputLayout = {ied, 2};
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets = 1;
        pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        pd.SampleDesc = {1, 0};
        ComPtr<ID3D12PipelineState> pso;
        r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));

        const VertexPosColor verts[6] = {
            {-0.35f, -0.35f, 0, 1.0f, 0.4f, 0.2f, 0.85f},
            {-0.35f,  0.35f, 0, 0.3f, 1.0f, 0.4f, 0.85f},
            { 0.35f,  0.35f, 0, 0.2f, 0.5f, 1.0f, 0.85f},
            {-0.35f, -0.35f, 0, 1.0f, 0.4f, 0.2f, 0.85f},
            { 0.35f,  0.35f, 0, 0.2f, 0.5f, 1.0f, 0.85f},
            { 0.35f, -0.35f, 0, 0.9f, 0.8f, 0.2f, 0.85f},
        };
        ComPtr<ID3D12Resource> vb;
        r.create_default_buffer_uploaded(verts, sizeof(verts), D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
        D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), sizeof(verts), sizeof(VertexPosColor)};

        constexpr UINT kDraws = 16;
        constexpr UINT kCBStride = 256;
        ComPtr<ID3D12Resource> cb_ring;
        r.create_upload_buffer(nullptr, kDraws * 2 * kCBStride, cb_ring);
        uint8_t* cb_mapped = nullptr;
        D3D12_RANGE empty{0, 0};
        cb_ring->Map(0, &empty, reinterpret_cast<void**>(&cb_mapped));

        ComPtr<ID3D12CommandAllocator> ring_allocs[2];
        r.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&ring_allocs[0]));
        r.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&ring_allocs[1]));

        D3D12_QUERY_HEAP_DESC qhd{D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 4, 0};
        ComPtr<ID3D12QueryHeap> qheap;
        r.dev->CreateQueryHeap(&qhd, IID_PPV_ARGS(&qheap));
        auto hp_rb = make_heap_props(D3D12_HEAP_TYPE_READBACK);
        auto rb_d = make_buffer_desc(sizeof(UINT64) * 4);
        ComPtr<ID3D12Resource> ts_rb;
        r.dev->CreateCommittedResource(&hp_rb, D3D12_HEAP_FLAG_NONE, &rb_d, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&ts_rb));
        UINT64 ts_freq = 0;
        r.queue->GetTimestampFrequency(&ts_freq);

        constexpr int kWarmup = 20;
        const int total_frames = kWarmup + opts.frames;
        std::vector<double> frame_times;
        frame_times.reserve(static_cast<size_t>(opts.frames));
        double gpu_ms_sum = 0.0;
        int gpu_ms_count = 0;

        for (int f = 0; f < total_frames; ++f) {
            const int slot = f & 1;
            const double ft0 = dm::now_ms();
            ring_allocs[slot]->Reset();
            r.cmd->Reset(ring_allocs[slot].Get(), pso.Get());

            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            if (f >= kWarmup) {
                r.cmd->EndQuery(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2);
            }

            const float bg[4] = {0.05f, 0.07f, 0.10f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);

            for (UINT d = 0; d < kDraws; ++d) {
                const UINT cb_off = (slot * kDraws + d) * kCBStride;
                auto* p = reinterpret_cast<BenchCB*>(cb_mapped + cb_off);
                p->transform[0] = -0.6f + 0.08f * static_cast<float>(d);
                p->transform[1] = -0.4f + 0.05f * static_cast<float>((d + f) % 16);
                p->transform[2] = 0.7f;
                p->transform[3] = 0.7f;
                p->color[0] = 0.4f + 0.03f * static_cast<float>(d);
                p->color[1] = 0.8f;
                p->color[2] = 1.0f - 0.04f * static_cast<float>(d);
                p->color[3] = 0.75f;
                r.cmd->SetGraphicsRootConstantBufferView(0, cb_ring->GetGPUVirtualAddress() + cb_off);
                r.cmd->DrawInstanced(6, 1, 0, 0);
            }

            if (f >= kWarmup) {
                r.cmd->EndQuery(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2 + 1);
                r.cmd->ResolveQueryData(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2, 2,
                                        ts_rb.Get(), static_cast<UINT64>(slot * 2) * sizeof(UINT64));
            }
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.cmd->Close();
            ID3D12CommandList* lists[1] = {r.cmd.Get()};
            r.queue->ExecuteCommandLists(1, lists);
            r.wait_idle();
            const double ft1 = dm::now_ms();

            if (f >= kWarmup) {
                frame_times.push_back(ft1 - ft0);
                if (ts_freq > 0) {
                    void* ts_ptr = nullptr;
                    D3D12_RANGE rr{static_cast<SIZE_T>(slot * 2) * sizeof(UINT64),
                                   static_cast<SIZE_T>(slot * 2 + 2) * sizeof(UINT64)};
                    if (SUCCEEDED(ts_rb->Map(0, &rr, &ts_ptr))) {
                        const UINT64* ts = static_cast<const UINT64*>(ts_ptr) + slot * 2;
                        if (ts[1] >= ts[0]) {
                            gpu_ms_sum += (static_cast<double>(ts[1] - ts[0]) * 1000.0) / static_cast<double>(ts_freq);
                            ++gpu_ms_count;
                        }
                        ts_rb->Unmap(0, &empty);
                    }
                }
            }
        }
        cb_ring->Unmap(0, nullptr);

        bench = dm::summarize_bench(frame_times, kWarmup);
        bench.gpu_mean_ms = gpu_ms_count > 0 ? (gpu_ms_sum / gpu_ms_count) : 0.0;
        bench.extra_metric_name = "draw_calls_per_sec";
        bench.extra_ops_per_sec = bench.total_ms > 0.0
            ? (static_cast<double>(kDraws) * static_cast<double>(bench.measured_frames)) / (bench.total_ms / 1000.0)
            : 0.0;
    }

    const std::string json_path = dm::join_path(opts.out_dir, "d3d12_results.json");
    if (!dm::write_results_json(json_path, "D3D12", max_fl, selected.meta, records, bench)) {
        std::cerr << "Failed to write " << json_path << "\n";
        return 1;
    }

    int pass_count = 0;
    for (const auto& rrec : records) {
        if (rrec.status == "pass") ++pass_count;
        std::cout << "  " << rrec.name << ": " << rrec.status
                  << " (checksum=" << rrec.pixel_checksum << ", " << rrec.duration_ms << " ms)\n";
    }
    std::cout << "[D3D12] Summary: " << pass_count << "/" << records.size()
              << " | Bench mean=" << bench.mean_ms << " ms (" << bench.fps
              << " FPS, 1%-low=" << bench.one_percent_low_fps << " FPS)\n";
    return pass_count == static_cast<int>(records.size()) ? 0 : 2;
}
