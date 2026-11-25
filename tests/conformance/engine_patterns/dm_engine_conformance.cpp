#include "dm_dxgi_select.hpp"
#include "dm_metrics.hpp"
#include "dm_png_writer.hpp"

#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#include "eng_01_gbuffer_vs.h"
#include "eng_01_gbuffer_ps.h"
#include "eng_01_deferred_vs.h"
#include "eng_01_deferred_ps.h"
#include "eng_02_shadow_vs_depth.h"
#include "eng_02_shadow_vs_main.h"
#include "eng_02_shadow_ps_main.h"
#include "eng_03_cull_cs.h"
#include "eng_03_draw_vs.h"
#include "eng_03_draw_ps.h"
#include "eng_04_hdr_vs.h"
#include "eng_04_hdr_ps.h"
#include "eng_04_blur_h_cs.h"
#include "eng_04_blur_v_cs.h"
#include "eng_04_tonemap_vs.h"
#include "eng_04_tonemap_ps.h"
#include "eng_05_wave_ops_cs.h"
#include "eng_06_bindless_vs.h"
#include "eng_06_bindless_ps.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kWidth = 512;
constexpr UINT kHeight = 512;
constexpr UINT kBenchWidth = 1024;
constexpr UINT kBenchHeight = 1024;
constexpr float kPi = 3.14159265358979323846f;

struct Vec3 {
    float x, y, z;
};

inline Vec3 operator+(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 normalize(const Vec3& v) {
    const float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-6f) return {0.0f, 1.0f, 0.0f};
    const float inv = 1.0f / len;
    return {v.x * inv, v.y * inv, v.z * inv};
}
inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return {
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    };
}
inline float dot(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

struct Mat4 {
    float r[4][4]{};
};

inline Mat4 mul_mat(const Mat4& a, const Mat4& b) {
    Mat4 out{};
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            out.r[row][col] =
                a.r[row][0] * b.r[0][col] +
                a.r[row][1] * b.r[1][col] +
                a.r[row][2] * b.r[2][col] +
                a.r[row][3] * b.r[3][col];
        }
    }
    return out;
}

inline Mat4 look_at_lh(const Vec3& eye, const Vec3& target, const Vec3& up) {
    const Vec3 f = normalize(target - eye);
    const Vec3 r = normalize(cross(up, f));
    const Vec3 u = cross(f, r);
    Mat4 m{};
    m.r[0][0] = r.x; m.r[0][1] = r.y; m.r[0][2] = r.z; m.r[0][3] = -dot(r, eye);
    m.r[1][0] = u.x; m.r[1][1] = u.y; m.r[1][2] = u.z; m.r[1][3] = -dot(u, eye);
    m.r[2][0] = f.x; m.r[2][1] = f.y; m.r[2][2] = f.z; m.r[2][3] = -dot(f, eye);
    m.r[3][3] = 1.0f;
    return m;
}

inline Mat4 perspective_lh(float fov_y_rad, float aspect, float zn, float zf) {
    const float ys = 1.0f / std::tan(fov_y_rad * 0.5f);
    const float xs = ys / aspect;
    const float q = zf / (zf - zn);
    Mat4 m{};
    m.r[0][0] = xs;
    m.r[1][1] = ys;
    m.r[2][2] = q;
    m.r[2][3] = -zn * q;
    m.r[3][2] = 1.0f;
    return m;
}

inline Mat4 ortho_lh(float half_w, float half_h, float zn, float zf) {
    Mat4 m{};
    m.r[0][0] = 1.0f / half_w;
    m.r[1][1] = 1.0f / half_h;
    m.r[2][2] = 1.0f / (zf - zn);
    m.r[2][3] = -zn / (zf - zn);
    m.r[3][3] = 1.0f;
    return m;
}

struct MeshVertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
};

struct ColorVertex2D {
    float x, y, z;
    float r, g, b, a;
};

struct UVVertex2D {
    float x, y, z;
    float u, v;
};

struct MeshSlice {
    UINT index_count = 0;
    UINT start_index = 0;
    INT base_vertex = 0;
};

MeshSlice append_box(std::vector<MeshVertex>& verts, std::vector<uint32_t>& indices,
                     float hx, float hy, float hz) {
    MeshSlice slice{};
    slice.base_vertex = static_cast<INT>(verts.size());
    slice.start_index = static_cast<UINT>(indices.size());

    struct Face {
        float nx, ny, nz;
        float vx[4], vy[4], vz[4];
    };
    const Face faces[6] = {
        { 0,  1,  0, {-hx,  hx,  hx, -hx}, { hy,  hy,  hy,  hy}, { hz,  hz, -hz, -hz}},
        { 0, -1,  0, {-hx, -hx,  hx,  hx}, {-hy, -hy, -hy, -hy}, { hz, -hz, -hz,  hz}},
        { 0,  0, -1, {-hx, -hx,  hx,  hx}, {-hy,  hy,  hy, -hy}, {-hz, -hz, -hz, -hz}},
        { 0,  0,  1, { hx,  hx, -hx, -hx}, {-hy,  hy,  hy, -hy}, { hz,  hz,  hz,  hz}},
        {-1,  0,  0, {-hx, -hx, -hx, -hx}, {-hy,  hy,  hy, -hy}, { hz,  hz, -hz, -hz}},
        { 1,  0,  0, { hx,  hx,  hx,  hx}, {-hy,  hy,  hy, -hy}, {-hz, -hz,  hz,  hz}},
    };
    const float uvx[4] = {0.0f, 0.0f, 1.0f, 1.0f};
    const float uvy[4] = {1.0f, 0.0f, 0.0f, 1.0f};

    for (const auto& f : faces) {
        const uint32_t vbase = static_cast<uint32_t>(verts.size()) - static_cast<uint32_t>(slice.base_vertex);
        for (int i = 0; i < 4; ++i) {
            verts.push_back({f.vx[i], f.vy[i], f.vz[i], f.nx, f.ny, f.nz, uvx[i], uvy[i]});
        }
        indices.push_back(vbase + 0); indices.push_back(vbase + 1); indices.push_back(vbase + 2);
        indices.push_back(vbase + 0); indices.push_back(vbase + 2); indices.push_back(vbase + 3);
    }
    slice.index_count = static_cast<UINT>(indices.size()) - slice.start_index;
    return slice;
}

MeshSlice append_sphere(std::vector<MeshVertex>& verts, std::vector<uint32_t>& indices,
                        int slices, int stacks, float radius) {
    MeshSlice slice{};
    slice.base_vertex = static_cast<INT>(verts.size());
    slice.start_index = static_cast<UINT>(indices.size());

    for (int iy = 0; iy <= stacks; ++iy) {
        const float v = static_cast<float>(iy) / static_cast<float>(stacks);
        const float phi = v * kPi;
        const float sp = std::sin(phi);
        const float cp = std::cos(phi);
        for (int ix = 0; ix <= slices; ++ix) {
            const float u = static_cast<float>(ix) / static_cast<float>(slices);
            const float theta = u * 2.0f * kPi;
            const float nx = sp * std::cos(theta);
            const float ny = cp;
            const float nz = sp * std::sin(theta);
            verts.push_back({nx * radius, ny * radius, nz * radius, nx, ny, nz, u, v});
        }
    }
    const int stride = slices + 1;
    for (int iy = 0; iy < stacks; ++iy) {
        for (int ix = 0; ix < slices; ++ix) {
            const uint32_t i0 = static_cast<uint32_t>(iy * stride + ix);
            const uint32_t i1 = i0 + 1;
            const uint32_t i2 = i0 + static_cast<uint32_t>(stride);
            const uint32_t i3 = i2 + 1;
            indices.push_back(i0); indices.push_back(i1); indices.push_back(i2);
            indices.push_back(i1); indices.push_back(i3); indices.push_back(i2);
        }
    }
    slice.index_count = static_cast<UINT>(indices.size()) - slice.start_index;
    return slice;
}

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

inline D3D12_RASTERIZER_DESC make_rasterizer(D3D12_CULL_MODE cull = D3D12_CULL_MODE_NONE,
                                             INT depth_bias = 0,
                                             float slope_bias = 0.0f) {
    D3D12_RASTERIZER_DESC r{};
    r.FillMode = D3D12_FILL_MODE_SOLID;
    r.CullMode = cull;
    r.DepthBias = depth_bias;
    r.SlopeScaledDepthBias = slope_bias;
    r.DepthClipEnable = TRUE;
    return r;
}

inline D3D12_BLEND_DESC default_blend(UINT num_rt = 1) {
    D3D12_BLEND_DESC b{};
    for (UINT i = 0; i < num_rt; ++i) {
        b.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    }
    return b;
}

inline D3D12_DEPTH_STENCIL_DESC make_depth_state(bool enable, bool write = true) {
    D3D12_DEPTH_STENCIL_DESC ds{};
    ds.DepthEnable = enable ? TRUE : FALSE;
    ds.DepthWriteMask = write ? D3D12_DEPTH_WRITE_MASK_ALL : D3D12_DEPTH_WRITE_MASK_ZERO;
    ds.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    return ds;
}

bool create_root_sig(ID3D12Device* dev, const D3D12_ROOT_SIGNATURE_DESC& desc,
                     ComPtr<ID3D12RootSignature>& out_rs, std::string& err) {
    ComPtr<ID3DBlob> sig, e;
    HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &e);
    if (FAILED(hr)) {
        if (e) err.assign(static_cast<const char*>(e->GetBufferPointer()), e->GetBufferSize());
        else err = "D3D12SerializeRootSignature failed";
        return false;
    }
    hr = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&out_rs));
    if (FAILED(hr)) {
        err = "CreateRootSignature failed HR=" + std::to_string(static_cast<long>(hr));
        return false;
    }
    return true;
}

inline UINT64 align256(UINT64 v) {
    return (v + 255ull) & ~255ull;
}

struct EngineRunner {
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> cmd;
    ComPtr<ID3D12Fence> fence;
    HANDLE event_handle = nullptr;
    UINT64 fence_val = 0;

    ComPtr<ID3D12DescriptorHeap> rtv_heap;
    ComPtr<ID3D12DescriptorHeap> dsv_heap;
    UINT rtv_inc = 0;
    UINT dsv_inc = 0;
    UINT srv_inc = 0;

    ComPtr<ID3D12Resource> rt_tex;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_handle{};

    ~EngineRunner() {
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

        D3D12_DESCRIPTOR_HEAP_DESC rhd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 16, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
        if (FAILED(dev->CreateDescriptorHeap(&rhd, IID_PPV_ARGS(&rtv_heap)))) return false;
        D3D12_DESCRIPTOR_HEAP_DESC dhd{D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 8, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
        if (FAILED(dev->CreateDescriptorHeap(&dhd, IID_PPV_ARGS(&dsv_heap)))) return false;

        rtv_inc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        dsv_inc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
        srv_inc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

        auto hp = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
        auto td = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        D3D12_CLEAR_VALUE cv{};
        cv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td,
                                                D3D12_RESOURCE_STATE_COMMON, &cv,
                                                IID_PPV_ARGS(&rt_tex)))) {
            return false;
        }
        rtv_handle = rtv_at(0);
        dev->CreateRenderTargetView(rt_tex.Get(), nullptr, rtv_handle);
        return true;
    }

    D3D12_CPU_DESCRIPTOR_HANDLE rtv_at(UINT idx) const {
        return {rtv_heap->GetCPUDescriptorHandleForHeapStart().ptr + static_cast<SIZE_T>(idx) * rtv_inc};
    }

    D3D12_CPU_DESCRIPTOR_HANDLE dsv_at(UINT idx) const {
        return {dsv_heap->GetCPUDescriptorHandleForHeapStart().ptr + static_cast<SIZE_T>(idx) * dsv_inc};
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

    void set_viewport_scissor(UINT w = kWidth, UINT h = kHeight) {
        D3D12_VIEWPORT vp{0.0f, 0.0f, static_cast<float>(w), static_cast<float>(h), 0.0f, 1.0f};
        D3D12_RECT sc{0, 0, static_cast<LONG>(w), static_cast<LONG>(h)};
        cmd->RSSetViewports(1, &vp);
        cmd->RSSetScissorRects(1, &sc);
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
                                        ComPtr<ID3D12Resource>& def_res,
                                        D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
        ComPtr<ID3D12Resource> up;
        if (!create_upload_buffer(data, size, up)) return false;
        auto hp = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
        auto bd = make_buffer_desc(size, flags);
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd,
                                                D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                IID_PPV_ARGS(&def_res)))) {
            return false;
        }
        reset_cmd();
        cmd->CopyBufferRegion(def_res.Get(), 0, up.Get(), 0, size);
        if (final_state != D3D12_RESOURCE_STATE_COPY_DEST) {
            auto b = make_transition(def_res.Get(), D3D12_RESOURCE_STATE_COPY_DEST, final_state);
            cmd->ResourceBarrier(1, &b);
        }
        submit_and_wait();
        return true;
    }

    bool create_rgba8_texture_uploaded(UINT w, UINT h, const uint8_t* rgba,
                                        D3D12_RESOURCE_STATES final_state,
                                        ComPtr<ID3D12Resource>& out_tex) {
        auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
        auto td = make_tex2d_desc(w, h, DXGI_FORMAT_R8G8B8A8_UNORM);
        if (FAILED(dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td,
                                                D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                IID_PPV_ARGS(&out_tex)))) {
            return false;
        }
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};
        UINT num_rows = 0;
        UINT64 row_size = 0, total_bytes = 0;
        dev->GetCopyableFootprints(&td, 0, 1, 0, &fp, &num_rows, &row_size, &total_bytes);

        ComPtr<ID3D12Resource> up;
        if (!create_upload_buffer(nullptr, total_bytes, up)) return false;
        void* mapped = nullptr;
        D3D12_RANGE rr{0, 0};
        if (FAILED(up->Map(0, &rr, &mapped))) return false;
        uint8_t* dst = static_cast<uint8_t*>(mapped) + fp.Offset;
        for (UINT y = 0; y < h; ++y) {
            std::memcpy(dst + static_cast<size_t>(y) * fp.Footprint.RowPitch,
                        rgba + static_cast<size_t>(y) * w * 4u,
                        static_cast<size_t>(w) * 4u);
        }
        up->Unmap(0, nullptr);

        reset_cmd();
        D3D12_TEXTURE_COPY_LOCATION dst_loc{};
        dst_loc.pResource = out_tex.Get();
        dst_loc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst_loc.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION src_loc{};
        src_loc.pResource = up.Get();
        src_loc.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src_loc.PlacedFootprint = fp;
        cmd->CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, nullptr);
        if (final_state != D3D12_RESOURCE_STATE_COPY_DEST) {
            auto b = make_transition(out_tex.Get(), D3D12_RESOURCE_STATE_COPY_DEST, final_state);
            cmd->ResourceBarrier(1, &b);
        }
        submit_and_wait();
        return true;
    }

    bool readback_tex_to_png(ID3D12Resource* tex, D3D12_RESOURCE_STATES cur_state,
                             const std::string& out_dir, dm::TestRecord& rec) {
        const auto desc = tex->GetDesc();
        const UINT w = static_cast<UINT>(desc.Width);
        const UINT h = desc.Height;
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
        std::vector<uint8_t> tight(static_cast<size_t>(w) * h * 4u);
        const uint8_t* src = static_cast<const uint8_t*>(mapped) + fp.Offset;
        for (UINT y = 0; y < h; ++y) {
            std::memcpy(tight.data() + static_cast<size_t>(y) * w * 4u,
                        src + static_cast<size_t>(y) * fp.Footprint.RowPitch,
                        static_cast<size_t>(w) * 4u);
        }
        D3D12_RANGE empty{0, 0};
        rb->Unmap(0, &empty);

        rec.png_file = rec.name + ".png";
        if (!dm::write_png_rgba8(dm::join_path(out_dir, rec.png_file), w, h,
                                 tight.data(), w * 4u)) {
            rec.detail = "PNG write failed";
            return false;
        }
        rec.pixel_checksum = dm::hex64(dm::fnv1a64(tight.data(), tight.size()));
        return true;
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

struct alignas(16) GBufferCBData {
    float vpRow0[4];
    float vpRow1[4];
    float vpRow2[4];
    float vpRow3[4];
    float objPosScale[4];
    float albedoMetal[4];
    float roughAOMat[4];
};

struct alignas(16) DeferredLightCBData {
    float camPosExposure[4];
    float keyDir[4];
    float keyColor[4];
    float pt0PosRadius[4];
    float pt0Color[4];
    float pt1PosRadius[4];
    float pt1Color[4];
};

struct alignas(16) ShadowCBData {
    float camRow0[4];
    float camRow1[4];
    float camRow2[4];
    float camRow3[4];
    float lightRow0[4];
    float lightRow1[4];
    float lightRow2[4];
    float lightRow3[4];
    float objPosScale[4];
    float baseColor[4];
    float sunDirTexel[4];
};

struct DeferredPipelineResources {
    ComPtr<ID3D12RootSignature> rs_geom;
    ComPtr<ID3D12RootSignature> rs_light;
    ComPtr<ID3D12PipelineState> pso_geom;
    ComPtr<ID3D12PipelineState> pso_light;

    ComPtr<ID3D12Resource> vb;
    ComPtr<ID3D12Resource> ib;
    D3D12_VERTEX_BUFFER_VIEW vbv{};
    D3D12_INDEX_BUFFER_VIEW ibv{};
    MeshSlice floor_slice{};
    MeshSlice sphere_slice{};
    MeshSlice box_slice{};

    ComPtr<ID3D12Resource> gb0_albedo;
    ComPtr<ID3D12Resource> gb1_normal;
    ComPtr<ID3D12Resource> gb2_pos;
    ComPtr<ID3D12Resource> dsv_tex;
    ComPtr<ID3D12Resource> out_rt;

    ComPtr<ID3D12DescriptorHeap> srv_heap;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_gb[3]{};
    D3D12_CPU_DESCRIPTOR_HANDLE dsv_handle{};
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_out{};

    ComPtr<ID3D12Resource> geom_cb_buf;
    uint8_t* geom_cb_ptr = nullptr;
    ComPtr<ID3D12Resource> light_cb_buf;
    uint8_t* light_cb_ptr = nullptr;
};

bool init_deferred_pipeline(EngineRunner& r, UINT width, UINT height, UINT frame_slots,
                            UINT objects_per_frame, DeferredPipelineResources& res, std::string& err) {
    // Geom root sig: single CBV b0
    D3D12_ROOT_PARAMETER rp_geom{};
    rp_geom.ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    rp_geom.Descriptor = {0, 0};
    rp_geom.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC rsd_geom{1, &rp_geom, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
    if (!create_root_sig(r.dev.Get(), rsd_geom, res.rs_geom, err)) return false;

    // Light root sig: param 0 = 3 SRVs (t0..t2), param 1 = CBV (b0), static clamp sampler s0
    D3D12_DESCRIPTOR_RANGE rng{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 3, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
    D3D12_ROOT_PARAMETER rp_light[2]{};
    rp_light[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    rp_light[0].DescriptorTable = {1, &rng};
    rp_light[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    rp_light[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    rp_light[1].Descriptor = {0, 0};
    rp_light[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

    D3D12_STATIC_SAMPLER_DESC ss{};
    ss.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    ss.MaxLOD = D3D12_FLOAT32_MAX;
    ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rsd_light{2, rp_light, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    if (!create_root_sig(r.dev.Get(), rsd_light, res.rs_light, err)) return false;

    const D3D12_INPUT_ELEMENT_DESC ied[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"NORMAL",   0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,    0, 24, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
    };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_geom{};
    pd_geom.pRootSignature = res.rs_geom.Get();
    pd_geom.VS = {kEng01GBufferVS, sizeof(kEng01GBufferVS)};
    pd_geom.PS = {kEng01GBufferPS, sizeof(kEng01GBufferPS)};
    pd_geom.BlendState = default_blend(3);
    pd_geom.SampleMask = UINT_MAX;
    pd_geom.RasterizerState = make_rasterizer(D3D12_CULL_MODE_BACK);
    pd_geom.DepthStencilState = make_depth_state(true, true);
    pd_geom.InputLayout = {ied, 3};
    pd_geom.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd_geom.NumRenderTargets = 3;
    pd_geom.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd_geom.RTVFormats[1] = DXGI_FORMAT_R16G16B16A16_FLOAT;
    pd_geom.RTVFormats[2] = DXGI_FORMAT_R16G16B16A16_FLOAT;
    pd_geom.DSVFormat = DXGI_FORMAT_D32_FLOAT;
    pd_geom.SampleDesc = {1, 0};
    if (FAILED(r.dev->CreateGraphicsPipelineState(&pd_geom, IID_PPV_ARGS(&res.pso_geom)))) {
        err = "CreateGraphicsPipelineState pso_geom failed";
        return false;
    }

    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_light{};
    pd_light.pRootSignature = res.rs_light.Get();
    pd_light.VS = {kEng01DeferredVS, sizeof(kEng01DeferredVS)};
    pd_light.PS = {kEng01DeferredPS, sizeof(kEng01DeferredPS)};
    pd_light.BlendState = default_blend(1);
    pd_light.SampleMask = UINT_MAX;
    pd_light.RasterizerState = make_rasterizer(D3D12_CULL_MODE_NONE);
    pd_light.DepthStencilState = make_depth_state(false, false);
    pd_light.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd_light.NumRenderTargets = 1;
    pd_light.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd_light.SampleDesc = {1, 0};
    if (FAILED(r.dev->CreateGraphicsPipelineState(&pd_light, IID_PPV_ARGS(&res.pso_light)))) {
        err = "CreateGraphicsPipelineState pso_light failed";
        return false;
    }

    // Geometry: floor box + smooth sphere + tall box
    std::vector<MeshVertex> verts;
    std::vector<uint32_t> indices;
    res.floor_slice = append_box(verts, indices, 6.0f, 0.10f, 6.0f);
    res.sphere_slice = append_sphere(verts, indices, 32, 16, 1.0f);
    res.box_slice = append_box(verts, indices, 0.7f, 1.1f, 0.7f);

    if (!r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(MeshVertex),
                                          D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, res.vb) ||
        !r.create_default_buffer_uploaded(indices.data(), indices.size() * sizeof(uint32_t),
                                          D3D12_RESOURCE_STATE_INDEX_BUFFER, res.ib)) {
        err = "Geometry buffer upload failed";
        return false;
    }
    res.vbv = {res.vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(MeshVertex)), sizeof(MeshVertex)};
    res.ibv = {res.ib->GetGPUVirtualAddress(), static_cast<UINT>(indices.size() * sizeof(uint32_t)), DXGI_FORMAT_R32_UINT};

    auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
    auto create_rt = [&](DXGI_FORMAT fmt, UINT rtv_idx, ComPtr<ID3D12Resource>& out_tex) -> bool {
        auto td = make_tex2d_desc(width, height, fmt, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        D3D12_CLEAR_VALUE cv{};
        cv.Format = fmt;
        if (FAILED(r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td,
                                                  D3D12_RESOURCE_STATE_RENDER_TARGET, &cv,
                                                  IID_PPV_ARGS(&out_tex)))) {
            return false;
        }
        r.dev->CreateRenderTargetView(out_tex.Get(), nullptr, r.rtv_at(rtv_idx));
        return true;
    };
    if (!create_rt(DXGI_FORMAT_R8G8B8A8_UNORM, 2, res.gb0_albedo) ||
        !create_rt(DXGI_FORMAT_R16G16B16A16_FLOAT, 3, res.gb1_normal) ||
        !create_rt(DXGI_FORMAT_R16G16B16A16_FLOAT, 4, res.gb2_pos) ||
        !create_rt(DXGI_FORMAT_R8G8B8A8_UNORM, 5, res.out_rt)) {
        err = "GBuffer/RT creation failed";
        return false;
    }
    res.rtv_gb[0] = r.rtv_at(2);
    res.rtv_gb[1] = r.rtv_at(3);
    res.rtv_gb[2] = r.rtv_at(4);
    res.rtv_out = r.rtv_at(5);

    auto dd = make_tex2d_desc(width, height, DXGI_FORMAT_D32_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
    D3D12_CLEAR_VALUE dcv{};
    dcv.Format = DXGI_FORMAT_D32_FLOAT;
    dcv.DepthStencil = {1.0f, 0};
    if (FAILED(r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &dd,
                                              D3D12_RESOURCE_STATE_DEPTH_WRITE, &dcv,
                                              IID_PPV_ARGS(&res.dsv_tex)))) {
        err = "Depth buffer creation failed";
        return false;
    }
    res.dsv_handle = r.dsv_at(0);
    r.dev->CreateDepthStencilView(res.dsv_tex.Get(), nullptr, res.dsv_handle);

    D3D12_DESCRIPTOR_HEAP_DESC shd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 3, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
    if (FAILED(r.dev->CreateDescriptorHeap(&shd, IID_PPV_ARGS(&res.srv_heap)))) return false;
    auto h0 = res.srv_heap->GetCPUDescriptorHandleForHeapStart();
    r.dev->CreateShaderResourceView(res.gb0_albedo.Get(), nullptr, h0);
    r.dev->CreateShaderResourceView(res.gb1_normal.Get(), nullptr, {h0.ptr + r.srv_inc});
    r.dev->CreateShaderResourceView(res.gb2_pos.Get(), nullptr, {h0.ptr + static_cast<SIZE_T>(2) * r.srv_inc});

    const UINT64 geom_bytes = static_cast<UINT64>(frame_slots) * objects_per_frame * 256ull;
    const UINT64 light_bytes = static_cast<UINT64>(frame_slots) * 256ull;
    if (!r.create_upload_buffer(nullptr, geom_bytes, res.geom_cb_buf) ||
        !r.create_upload_buffer(nullptr, light_bytes, res.light_cb_buf)) {
        err = "CB ring creation failed";
        return false;
    }
    D3D12_RANGE empty{0, 0};
    res.geom_cb_buf->Map(0, &empty, reinterpret_cast<void**>(&res.geom_cb_ptr));
    res.light_cb_buf->Map(0, &empty, reinterpret_cast<void**>(&res.light_cb_ptr));
    return true;
}

void write_deferred_scene_cbs(DeferredPipelineResources& res, UINT slot, UINT obj_count, float phase_rad, float aspect) {
    const Vec3 eye = {0.0f, 3.3f, -6.4f};
    const Vec3 target = {0.0f, 0.7f, 0.0f};
    const Mat4 view = look_at_lh(eye, target, {0.0f, 1.0f, 0.0f});
    const Mat4 proj = perspective_lh(50.0f * (kPi / 180.0f), aspect, 0.2f, 40.0f);
    const Mat4 vp = mul_mat(proj, view);

    auto write_obj = [&](UINT obj_idx, const float pos_scale[4], const float albedo_metal[4], const float rough_ao_mat[4]) {
        auto* cb = reinterpret_cast<GBufferCBData*>(res.geom_cb_ptr + (slot * obj_count + obj_idx) * 256ull);
        std::memcpy(cb->vpRow0, vp.r[0], 16);
        std::memcpy(cb->vpRow1, vp.r[1], 16);
        std::memcpy(cb->vpRow2, vp.r[2], 16);
        std::memcpy(cb->vpRow3, vp.r[3], 16);
        std::memcpy(cb->objPosScale, pos_scale, 16);
        std::memcpy(cb->albedoMetal, albedo_metal, 16);
        std::memcpy(cb->roughAOMat, rough_ao_mat, 16);
    };

    // Obj 0: Checkerboard Floor
    {
        const float ps[4] = {0.0f, -0.10f, 0.0f, 1.0f};
        const float am[4] = {0.72f, 0.74f, 0.78f, 0.08f};
        const float rm[4] = {0.35f, 1.0f, 1.25f, 1.0f};
        write_obj(0, ps, am, rm);
    }
    // Obj 1..obj_count-1: Spheres & blocks
    for (UINT i = 1; i < obj_count; ++i) {
        const UINT idx = i - 1;
        if (obj_count <= 5) {
            // Static canonical 4-object hero layout for eng_01 visual comparison
            const float positions[4][4] = {
                {-1.85f, 1.05f, -0.35f, 1.05f},
                { 0.00f, 1.15f,  0.10f, 1.15f},
                { 1.85f, 0.95f, -0.45f, 0.95f},
                {-0.15f, 1.10f,  2.10f, 1.00f},
            };
            const float materials[4][4] = {
                {0.92f, 0.72f, 0.32f, 0.95f},  // Brushed gold metallic sphere
                {0.82f, 0.18f, 0.16f, 0.10f},  // Glossy crimson dielectric sphere
                {0.20f, 0.62f, 0.95f, 0.70f},  // Cyan anodized sphere
                {0.86f, 0.88f, 0.92f, 0.35f},  // Ceramic/steel pillar
            };
            const float roughs[4][4] = {
                {0.18f, 1.0f, 1.0f, 0.0f},
                {0.14f, 1.0f, 1.0f, 0.0f},
                {0.28f, 1.0f, 1.0f, 0.0f},
                {0.42f, 1.0f, 1.0f, 0.0f},
            };
            write_obj(i, positions[idx % 4], materials[idx % 4], roughs[idx % 4]);
        } else {
            // Stress bench grid of varied metallic/roughness PBR spheres & blocks
            const float angle = phase_rad + static_cast<float>(idx) * (2.0f * kPi / static_cast<float>(obj_count - 1));
            const float ring = 1.1f + 0.12f * static_cast<float>(idx % 12);
            const float ps[4] = {std::cos(angle) * ring, 0.55f + 0.18f * static_cast<float>(idx % 4), std::sin(angle) * ring, 0.42f};
            const float t = static_cast<float>(idx) / static_cast<float>(obj_count);
            const float am[4] = {0.25f + 0.7f * t, 0.35f + 0.55f * (1.0f - t), 0.85f - 0.5f * t, (idx & 1u) ? 0.90f : 0.15f};
            const float rm[4] = {0.12f + 0.70f * static_cast<float>(idx % 5) / 4.0f, 1.0f, 1.0f, 0.0f};
            write_obj(i, ps, am, rm);
        }
    }

    auto* lcb = reinterpret_cast<DeferredLightCBData*>(res.light_cb_ptr + slot * 256ull);
    lcb->camPosExposure[0] = eye.x; lcb->camPosExposure[1] = eye.y; lcb->camPosExposure[2] = eye.z; lcb->camPosExposure[3] = 1.15f;
    const Vec3 kd = normalize({0.55f, 0.82f, -0.45f});
    lcb->keyDir[0] = kd.x; lcb->keyDir[1] = kd.y; lcb->keyDir[2] = kd.z; lcb->keyDir[3] = 0.0f;
    lcb->keyColor[0] = 3.2f; lcb->keyColor[1] = 2.95f; lcb->keyColor[2] = 2.6f; lcb->keyColor[3] = 1.0f;

    lcb->pt0PosRadius[0] = -2.6f + 0.4f * std::sin(phase_rad);
    lcb->pt0PosRadius[1] = 2.2f;
    lcb->pt0PosRadius[2] = -2.2f;
    lcb->pt0PosRadius[3] = 8.5f;
    lcb->pt0Color[0] = 4.5f; lcb->pt0Color[1] = 1.7f; lcb->pt0Color[2] = 0.7f; lcb->pt0Color[3] = 1.0f;

    lcb->pt1PosRadius[0] = 2.8f + 0.4f * std::cos(phase_rad);
    lcb->pt1PosRadius[1] = 2.4f;
    lcb->pt1PosRadius[2] = -1.6f;
    lcb->pt1PosRadius[3] = 8.5f;
    lcb->pt1Color[0] = 0.9f; lcb->pt1Color[1] = 2.6f; lcb->pt1Color[2] = 5.0f; lcb->pt1Color[3] = 1.0f;
}

void record_deferred_frame(ID3D12GraphicsCommandList* cmd, DeferredPipelineResources& res,
                           UINT width, UINT height, UINT slot, UINT obj_count, bool first_frame) {
    if (!first_frame) {
        D3D12_RESOURCE_BARRIER b_in[3] = {
            make_transition(res.gb0_albedo.Get(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET),
            make_transition(res.gb1_normal.Get(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET),
            make_transition(res.gb2_pos.Get(),    D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET),
        };
        cmd->ResourceBarrier(3, b_in);
    }

    const float zeros[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    cmd->ClearRenderTargetView(res.rtv_gb[0], zeros, 0, nullptr);
    cmd->ClearRenderTargetView(res.rtv_gb[1], zeros, 0, nullptr);
    cmd->ClearRenderTargetView(res.rtv_gb[2], zeros, 0, nullptr);
    cmd->ClearDepthStencilView(res.dsv_handle, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
    cmd->OMSetRenderTargets(3, res.rtv_gb, FALSE, &res.dsv_handle);

    D3D12_VIEWPORT vp{0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f};
    D3D12_RECT sc{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    cmd->RSSetViewports(1, &vp);
    cmd->RSSetScissorRects(1, &sc);

    cmd->SetGraphicsRootSignature(res.rs_geom.Get());
    cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    cmd->IASetVertexBuffers(0, 1, &res.vbv);
    cmd->IASetIndexBuffer(&res.ibv);

    for (UINT i = 0; i < obj_count; ++i) {
        const D3D12_GPU_VIRTUAL_ADDRESS addr = res.geom_cb_buf->GetGPUVirtualAddress() +
                                             (static_cast<UINT64>(slot) * obj_count + i) * 256ull;
        cmd->SetGraphicsRootConstantBufferView(0, addr);
        const MeshSlice& sl = (i == 0) ? res.floor_slice : ((i == 4 && obj_count <= 5) ? res.box_slice : res.sphere_slice);
        cmd->DrawIndexedInstanced(sl.index_count, 1, sl.start_index, sl.base_vertex, 0);
    }

    D3D12_RESOURCE_BARRIER b_srv[3] = {
        make_transition(res.gb0_albedo.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
        make_transition(res.gb1_normal.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
        make_transition(res.gb2_pos.Get(),    D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
    };
    cmd->ResourceBarrier(3, b_srv);

    cmd->SetPipelineState(res.pso_light.Get());
    cmd->SetGraphicsRootSignature(res.rs_light.Get());
    ID3D12DescriptorHeap* heaps[1] = {res.srv_heap.Get()};
    cmd->SetDescriptorHeaps(1, heaps);
    cmd->SetGraphicsRootDescriptorTable(0, res.srv_heap->GetGPUDescriptorHandleForHeapStart());
    cmd->SetGraphicsRootConstantBufferView(1, res.light_cb_buf->GetGPUVirtualAddress() + static_cast<UINT64>(slot) * 256ull);
    cmd->OMSetRenderTargets(1, &res.rtv_out, FALSE, nullptr);
    cmd->DrawInstanced(3, 1, 0, 0);
}

bool write_engine_results_json(const std::string& path,
                               const std::string& feature_level,
                               const dm::AdapterMetadata& adapter,
                               const std::vector<dm::TestRecord>& tests,
                               const dm::BenchStats& bench) {
    int passed = 0;
    for (const auto& t : tests) {
        if (t.status == "pass") ++passed;
    }
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(4);
    oss << "{\n";
    oss << "  \"api\": \"D3D12-Engine\",\n";
    oss << "  \"feature_level\": \"" << dm::json_escape(feature_level) << "\",\n";
    oss << "  \"adapter\": {\n";
    oss << "    \"description\": \"" << dm::json_escape(adapter.description) << "\",\n";
    oss << "    \"vendor_id\": " << adapter.vendor_id << ",\n";
    oss << "    \"device_id\": " << adapter.device_id << ",\n";
    oss << "    \"dedicated_vram_mb\": " << adapter.dedicated_vram_mb << ",\n";
    oss << "    \"shared_mem_mb\": " << adapter.shared_mem_mb << "\n";
    oss << "  },\n";
    oss << "  \"summary\": {\n";
    oss << "    \"passed\": " << passed << ",\n";
    oss << "    \"total\": " << tests.size() << "\n";
    oss << "  },\n";
    oss << "  \"tests\": [\n";
    for (size_t i = 0; i < tests.size(); ++i) {
        const auto& t = tests[i];
        oss << "    {\n";
        oss << "      \"name\": \"" << dm::json_escape(t.name) << "\",\n";
        oss << "      \"status\": \"" << dm::json_escape(t.status) << "\",\n";
        oss << "      \"png\": \"" << dm::json_escape(t.png_file) << "\",\n";
        oss << "      \"pixel_checksum\": \"" << dm::json_escape(t.pixel_checksum) << "\",\n";
        if (t.has_compute_checksum) {
            oss << "      \"compute_checksum\": \"" << dm::json_escape(t.compute_checksum) << "\",\n";
            oss << "      \"expected_compute_checksum\": \"" << dm::json_escape(t.expected_compute_checksum) << "\",\n";
        }
        if (!t.shader_model.empty()) {
            oss << "      \"shader_model\": \"" << dm::json_escape(t.shader_model) << "\",\n";
        }
        oss << "      \"duration_ms\": " << t.duration_ms << ",\n";
        oss << "      \"detail\": \"" << dm::json_escape(t.detail) << "\"\n";
        oss << "    }" << (i + 1 < tests.size() ? "," : "") << "\n";
    }
    oss << "  ],\n";
    oss << "  \"benchmark\": {\n";
    oss << "    \"name\": \"eng_bench_deferred_pbr\",\n";
    oss << "    \"resolution\": \"1024x1024\",\n";
    oss << "    \"warmup_frames\": " << bench.warmup_frames << ",\n";
    oss << "    \"measured_frames\": " << bench.measured_frames << ",\n";
    oss << "    \"mean_ms\": " << bench.mean_ms << ",\n";
    oss << "    \"p50_ms\": " << bench.p50_ms << ",\n";
    oss << "    \"p95_ms\": " << bench.p95_ms << ",\n";
    oss << "    \"p99_ms\": " << bench.p99_ms << ",\n";
    oss << "    \"min_ms\": " << bench.min_ms << ",\n";
    oss << "    \"max_ms\": " << bench.max_ms << ",\n";
    oss << "    \"fps\": " << bench.fps << ",\n";
    oss << "    \"one_percent_low_fps\": " << bench.one_percent_low_fps << ",\n";
    oss << "    \"gpu_mean_ms\": " << bench.gpu_mean_ms << ",\n";
    oss << "    \"extra_metric_name\": \"" << dm::json_escape(bench.extra_metric_name) << "\",\n";
    oss << "    \"extra_ops_per_sec\": " << bench.extra_ops_per_sec << "\n";
    oss << "  }\n";
    oss << "}\n";

    std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
    if (!ofs.is_open()) return false;
    const std::string data = oss.str();
    ofs.write(data.data(), static_cast<std::streamsize>(data.size()));
    return ofs.good();
}

}  // namespace

int main(int argc, char** argv) {
    const dm::CliOptions opts = dm::parse_cli(argc, argv);
    if (!dm::ensure_directory_recursive(opts.out_dir)) {
        std::cerr << "Failed to create output directory: " << opts.out_dir << "\n";
        return 1;
    }

    dm::SelectedAdapter selected;
    if (!dm::select_hardware_adapter(opts.adapter_filter, selected)) {
        std::cerr << "No suitable DXGI hardware adapter found.\n";
        return 1;
    }
    EngineRunner r;
    if (!r.init(selected.adapter.Get())) {
        std::cerr << "Failed to initialize D3D12 EngineRunner.\n";
        return 1;
    }
    const std::string max_fl = r.max_feature_level_str();

    std::cout << "[D3D12-Engine] Adapter: " << selected.meta.description
              << " | MaxFL: " << max_fl << " | ShaderModel: SM 6.0 Signed DXIL\n";

    std::vector<dm::TestRecord> records;

    // 1. eng_01_deferred_gbuffer
    {
        dm::TestRecord rec;
        rec.name = "eng_01_deferred_gbuffer";
        rec.shader_model = "vs_6_0/ps_6_0 (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;
        DeferredPipelineResources dpr;
        if (init_deferred_pipeline(r, kWidth, kHeight, 1, 5, dpr, err)) {
            write_deferred_scene_cbs(dpr, 0, 5, 0.0f, 1.0f);
            r.reset_cmd(dpr.pso_geom.Get());
            record_deferred_frame(r.cmd.Get(), dpr, kWidth, kHeight, 0, 5, true);
            r.submit_and_wait();
            if (r.readback_tex_to_png(dpr.out_rt.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "3-MRT G-Buffer + D32 depth + Cook-Torrance GGX deferred PBR";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 2. eng_02_shadow_pcf
    {
        dm::TestRecord rec;
        rec.name = "eng_02_shadow_pcf";
        rec.shader_model = "vs_6_0/ps_6_0 (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;

        D3D12_ROOT_PARAMETER rp[2]{};
        rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        rp[0].Descriptor = {0, 0};
        rp[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_DESCRIPTOR_RANGE rng{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        rp[1].DescriptorTable = {1, &rng};
        rp[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_STATIC_SAMPLER_DESC ss{};
        ss.Filter = D3D12_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT;
        ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_BORDER;
        ss.BorderColor = D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE;
        ss.ComparisonFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL;
        ss.MaxLOD = D3D12_FLOAT32_MAX;
        ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_ROOT_SIGNATURE_DESC rsd{2, rp, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3D12RootSignature> rs;
        if (create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"NORMAL",   0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,    0, 24, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_depth{};
            pd_depth.pRootSignature = rs.Get();
            pd_depth.VS = {kEng02ShadowVSDepth, sizeof(kEng02ShadowVSDepth)};
            pd_depth.BlendState = default_blend(0);
            pd_depth.SampleMask = UINT_MAX;
            pd_depth.RasterizerState = make_rasterizer(D3D12_CULL_MODE_BACK, 400, 1.5f);
            pd_depth.DepthStencilState = make_depth_state(true, true);
            pd_depth.InputLayout = {ied, 3};
            pd_depth.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd_depth.NumRenderTargets = 0;
            pd_depth.DSVFormat = DXGI_FORMAT_D32_FLOAT;
            pd_depth.SampleDesc = {1, 0};

            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_main = pd_depth;
            pd_main.VS = {kEng02ShadowVSMain, sizeof(kEng02ShadowVSMain)};
            pd_main.PS = {kEng02ShadowPSMain, sizeof(kEng02ShadowPSMain)};
            pd_main.BlendState = default_blend(1);
            pd_main.RasterizerState = make_rasterizer(D3D12_CULL_MODE_BACK);
            pd_main.NumRenderTargets = 1;
            pd_main.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;

            ComPtr<ID3D12PipelineState> pso_depth, pso_main;
            r.dev->CreateGraphicsPipelineState(&pd_depth, IID_PPV_ARGS(&pso_depth));
            r.dev->CreateGraphicsPipelineState(&pd_main, IID_PPV_ARGS(&pso_main));

            std::vector<MeshVertex> verts;
            std::vector<uint32_t> indices;
            const MeshSlice floor_s = append_box(verts, indices, 5.5f, 0.1f, 5.5f);
            const MeshSlice pillar_s = append_box(verts, indices, 0.45f, 1.2f, 0.45f);
            const MeshSlice cross_s = append_box(verts, indices, 1.6f, 0.25f, 0.35f);
            const MeshSlice orb_s = append_sphere(verts, indices, 24, 12, 0.7f);

            ComPtr<ID3D12Resource> vb, ib;
            r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(MeshVertex),
                                             D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            r.create_default_buffer_uploaded(indices.data(), indices.size() * sizeof(uint32_t),
                                             D3D12_RESOURCE_STATE_INDEX_BUFFER, ib);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(MeshVertex)), sizeof(MeshVertex)};
            D3D12_INDEX_BUFFER_VIEW ibv{ib->GetGPUVirtualAddress(), static_cast<UINT>(indices.size() * sizeof(uint32_t)), DXGI_FORMAT_R32_UINT};

            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            D3D12_CLEAR_VALUE dcv{};
            dcv.Format = DXGI_FORMAT_D32_FLOAT;
            dcv.DepthStencil = {1.0f, 0};

            ComPtr<ID3D12Resource> shadow_tex, cam_depth;
            auto td_shadow = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R32_TYPELESS, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td_shadow,
                                           D3D12_RESOURCE_STATE_DEPTH_WRITE, &dcv, IID_PPV_ARGS(&shadow_tex));
            auto td_depth = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_D32_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td_depth,
                                           D3D12_RESOURCE_STATE_DEPTH_WRITE, &dcv, IID_PPV_ARGS(&cam_depth));

            D3D12_DEPTH_STENCIL_VIEW_DESC dsv_d{};
            dsv_d.Format = DXGI_FORMAT_D32_FLOAT;
            dsv_d.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
            D3D12_CPU_DESCRIPTOR_HANDLE shadow_dsv = r.dsv_at(1);
            D3D12_CPU_DESCRIPTOR_HANDLE cam_dsv = r.dsv_at(2);
            r.dev->CreateDepthStencilView(shadow_tex.Get(), &dsv_d, shadow_dsv);
            r.dev->CreateDepthStencilView(cam_depth.Get(), nullptr, cam_dsv);

            D3D12_DESCRIPTOR_HEAP_DESC shd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> srv_heap;
            r.dev->CreateDescriptorHeap(&shd, IID_PPV_ARGS(&srv_heap));
            D3D12_SHADER_RESOURCE_VIEW_DESC srv_d{};
            srv_d.Format = DXGI_FORMAT_R32_FLOAT;
            srv_d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
            srv_d.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            srv_d.Texture2D.MipLevels = 1;
            r.dev->CreateShaderResourceView(shadow_tex.Get(), &srv_d, srv_heap->GetCPUDescriptorHandleForHeapStart());

            const Mat4 cam_vp = mul_mat(perspective_lh(50.0f * (kPi / 180.0f), 1.0f, 0.2f, 40.0f),
                                        look_at_lh({0.0f, 4.4f, -6.2f}, {0.0f, 0.6f, 0.0f}, {0.0f, 1.0f, 0.0f}));
            const Vec3 light_pos = {5.5f, 7.5f, -3.5f};
            const Vec3 sun_dir = normalize(light_pos);
            const Mat4 light_vp = mul_mat(ortho_lh(5.2f, 5.2f, 0.5f, 22.0f),
                                          look_at_lh(light_pos, {0.0f, 0.2f, 0.0f}, {0.0f, 1.0f, 0.0f}));

            struct ObjSpec { MeshSlice sl; float ps[4]; float col[4]; };
            const ObjSpec objs[4] = {
                {floor_s,  { 0.00f, -0.10f, 0.00f, 1.0f}, {0.72f, 0.74f, 0.78f, 1.0f}},
                {pillar_s, {-1.25f,  1.20f, -0.2f, 1.0f}, {0.88f, 0.45f, 0.22f, 0.0f}},
                {cross_s,  { 0.00f,  2.35f, -0.2f, 1.0f}, {0.35f, 0.76f, 0.90f, 0.0f}},
                {orb_s,    { 1.45f,  1.25f,  0.4f, 1.0f}, {0.92f, 0.80f, 0.26f, 0.0f}},
            };

            ComPtr<ID3D12Resource> cb_buf;
            r.create_upload_buffer(nullptr, 4 * 256ull, cb_buf);
            uint8_t* cb_ptr = nullptr;
            D3D12_RANGE empty{0, 0};
            cb_buf->Map(0, &empty, reinterpret_cast<void**>(&cb_ptr));
            for (UINT i = 0; i < 4; ++i) {
                auto* cb = reinterpret_cast<ShadowCBData*>(cb_ptr + i * 256ull);
                std::memcpy(cb->camRow0, cam_vp.r[0], 16);
                std::memcpy(cb->camRow1, cam_vp.r[1], 16);
                std::memcpy(cb->camRow2, cam_vp.r[2], 16);
                std::memcpy(cb->camRow3, cam_vp.r[3], 16);
                std::memcpy(cb->lightRow0, light_vp.r[0], 16);
                std::memcpy(cb->lightRow1, light_vp.r[1], 16);
                std::memcpy(cb->lightRow2, light_vp.r[2], 16);
                std::memcpy(cb->lightRow3, light_vp.r[3], 16);
                std::memcpy(cb->objPosScale, objs[i].ps, 16);
                std::memcpy(cb->baseColor, objs[i].col, 16);
                cb->sunDirTexel[0] = sun_dir.x;
                cb->sunDirTexel[1] = sun_dir.y;
                cb->sunDirTexel[2] = sun_dir.z;
                cb->sunDirTexel[3] = 1.0f / static_cast<float>(kWidth);
            }
            cb_buf->Unmap(0, nullptr);

            // Depth-only shadow pass -> transition -> main pass
            r.reset_cmd(pso_depth.Get());
            r.set_viewport_scissor();
            r.cmd->ClearDepthStencilView(shadow_dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
            r.cmd->OMSetRenderTargets(0, nullptr, FALSE, &shadow_dsv);
            r.cmd->SetGraphicsRootSignature(rs.Get());
            ID3D12DescriptorHeap* heaps[1] = {srv_heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->IASetIndexBuffer(&ibv);
            for (UINT i = 0; i < 4; ++i) {
                r.cmd->SetGraphicsRootConstantBufferView(0, cb_buf->GetGPUVirtualAddress() + i * 256ull);
                r.cmd->DrawIndexedInstanced(objs[i].sl.index_count, 1, objs[i].sl.start_index, objs[i].sl.base_vertex, 0);
            }

            D3D12_RESOURCE_BARRIER b_mid[2] = {
                make_transition(shadow_tex.Get(), D3D12_RESOURCE_STATE_DEPTH_WRITE, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET),
            };
            r.cmd->ResourceBarrier(2, b_mid);

            r.cmd->SetPipelineState(pso_main.Get());
            const float sky[4] = {0.06f, 0.09f, 0.14f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, sky, 0, nullptr);
            r.cmd->ClearDepthStencilView(cam_dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, &cam_dsv);
            r.cmd->SetGraphicsRootDescriptorTable(1, srv_heap->GetGPUDescriptorHandleForHeapStart());
            for (UINT i = 0; i < 4; ++i) {
                r.cmd->SetGraphicsRootConstantBufferView(0, cb_buf->GetGPUVirtualAddress() + i * 256ull);
                r.cmd->DrawIndexedInstanced(objs[i].sl.index_count, 1, objs[i].sl.start_index, objs[i].sl.base_vertex, 0);
            }

            auto b_end = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b_end);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "D32 depth shadow map + 3x3 SamplerComparisonState PCF";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 3. eng_03_gpu_cull_indirect
    {
        dm::TestRecord rec;
        rec.name = "eng_03_gpu_cull_indirect";
        rec.has_compute_checksum = true;
        rec.shader_model = "cs_6_0+vs_6_0/ps_6_0 (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;

        D3D12_DESCRIPTOR_RANGE crng[2]{};
        crng[0] = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        crng[1] = {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 2, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        D3D12_ROOT_PARAMETER crp[2]{};
        crp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        crp[0].Descriptor = {0, 0};
        crp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        crp[1].DescriptorTable = {2, crng};
        D3D12_ROOT_SIGNATURE_DESC crsd{2, crp, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};

        D3D12_ROOT_SIGNATURE_DESC grsd{0, nullptr, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3D12RootSignature> crs, grs;
        if (create_root_sig(r.dev.Get(), crsd, crs, err) && create_root_sig(r.dev.Get(), grsd, grs, err)) {
            D3D12_COMPUTE_PIPELINE_STATE_DESC cpd{};
            cpd.pRootSignature = crs.Get();
            cpd.CS = {kEng03CullCS, sizeof(kEng03CullCS)};
            ComPtr<ID3D12PipelineState> cpso;
            r.dev->CreateComputePipelineState(&cpd, IID_PPV_ARGS(&cpso));

            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR",    0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC gpd{};
            gpd.pRootSignature = grs.Get();
            gpd.VS = {kEng03DrawVS, sizeof(kEng03DrawVS)};
            gpd.PS = {kEng03DrawPS, sizeof(kEng03DrawPS)};
            gpd.BlendState = default_blend(1);
            gpd.SampleMask = UINT_MAX;
            gpd.RasterizerState = make_rasterizer(D3D12_CULL_MODE_NONE);
            gpd.DepthStencilState = make_depth_state(false, false);
            gpd.InputLayout = {ied, 2};
            gpd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            gpd.NumRenderTargets = 1;
            gpd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            gpd.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> gpso;
            r.dev->CreateGraphicsPipelineState(&gpd, IID_PPV_ARGS(&gpso));

            struct Candidate { float rect[4]; float color[4]; };
            struct CullCB { float frustumParams[4]; uint32_t numCandidates; uint32_t pad[3]; };
            constexpr UINT kN = 64;
            std::vector<Candidate> cands(kN);
            std::vector<ColorVertex2D> verts;
            verts.reserve(kN * 6);

            const float diamond_r = 0.78f;
            const float circle_r = 0.62f;
            uint32_t expected_count = 0;
            uint32_t expected_hash = 0;
            for (int y = 0; y < 8; ++y) {
                for (int x = 0; x < 8; ++x) {
                    const UINT idx = static_cast<UINT>(y * 8 + x);
                    const float cx = -0.82f + static_cast<float>(x) * (1.64f / 7.0f);
                    const float cy = -0.82f + static_cast<float>(y) * (1.64f / 7.0f);
                    const float hs = 0.085f;
                    const float rr = 0.25f + 0.75f * static_cast<float>(x) / 7.0f;
                    const float gg = 0.25f + 0.75f * static_cast<float>(y) / 7.0f;
                    const float bb = 1.0f - 0.5f * (static_cast<float>(x + y) / 14.0f);
                    cands[idx] = {{cx, cy, hs, 1.0f}, {rr, gg, bb, 1.0f}};
                    verts.push_back({cx - hs, cy - hs, 0, rr, gg, bb, 1.0f});
                    verts.push_back({cx - hs, cy + hs, 0, rr, gg, bb, 1.0f});
                    verts.push_back({cx + hs, cy + hs, 0, rr, gg, bb, 1.0f});
                    verts.push_back({cx - hs, cy - hs, 0, rr, gg, bb, 1.0f});
                    verts.push_back({cx + hs, cy + hs, 0, rr, gg, bb, 1.0f});
                    verts.push_back({cx + hs, cy - hs, 0, rr, gg, bb, 1.0f});

                    const bool in_d = (std::fabs(cx) + std::fabs(cy)) <= diamond_r;
                    const bool in_c = std::sqrt(cx * cx + cy * cy) <= circle_r;
                    if (in_d || in_c) {
                        ++expected_count;
                        expected_hash += (idx + 1u) * 2654435761u;
                    }
                }
            }

            CullCB ccb{{diamond_r, circle_r, 0.0f, 0.0f}, kN, {0, 0, 0}};
            ComPtr<ID3D12Resource> vb, cand_buf, cull_cb, args_buf, cnt_buf, cnt_rb;
            r.create_default_buffer_uploaded(verts.data(), verts.size() * sizeof(ColorVertex2D),
                                             D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            r.create_default_buffer_uploaded(cands.data(), cands.size() * sizeof(Candidate),
                                             D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, cand_buf);
            r.create_upload_buffer(&ccb, 256, cull_cb);

            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto adesc = make_buffer_desc(kN * sizeof(D3D12_DRAW_ARGUMENTS), D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &adesc,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&args_buf));

            const uint32_t zero_cnt[2] = {0u, 0u};
            r.create_default_buffer_uploaded(zero_cnt, sizeof(zero_cnt), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                             cnt_buf, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            auto hp_rb = make_heap_props(D3D12_HEAP_TYPE_READBACK);
            auto rb_desc = make_buffer_desc(sizeof(zero_cnt));
            r.dev->CreateCommittedResource(&hp_rb, D3D12_HEAP_FLAG_NONE, &rb_desc,
                                           D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&cnt_rb));

            D3D12_DESCRIPTOR_HEAP_DESC chd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 3, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> heap;
            r.dev->CreateDescriptorHeap(&chd, IID_PPV_ARGS(&heap));
            auto h0 = heap->GetCPUDescriptorHandleForHeapStart();

            D3D12_SHADER_RESOURCE_VIEW_DESC csrv{};
            csrv.Format = DXGI_FORMAT_UNKNOWN;
            csrv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
            csrv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            csrv.Buffer = {0, kN, sizeof(Candidate), D3D12_BUFFER_SRV_FLAG_NONE};
            r.dev->CreateShaderResourceView(cand_buf.Get(), &csrv, h0);

            D3D12_UNORDERED_ACCESS_VIEW_DESC auav{};
            auav.Format = DXGI_FORMAT_UNKNOWN;
            auav.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            auav.Buffer = {0, kN, sizeof(D3D12_DRAW_ARGUMENTS), 0, D3D12_BUFFER_UAV_FLAG_NONE};
            r.dev->CreateUnorderedAccessView(args_buf.Get(), nullptr, &auav, {h0.ptr + r.srv_inc});

            D3D12_UNORDERED_ACCESS_VIEW_DESC cuav{};
            cuav.Format = DXGI_FORMAT_UNKNOWN;
            cuav.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            cuav.Buffer = {0, 2, sizeof(uint32_t), 0, D3D12_BUFFER_UAV_FLAG_NONE};
            r.dev->CreateUnorderedAccessView(cnt_buf.Get(), nullptr, &cuav, {h0.ptr + static_cast<SIZE_T>(2) * r.srv_inc});

            D3D12_INDIRECT_ARGUMENT_DESC iad{};
            iad.Type = D3D12_INDIRECT_ARGUMENT_TYPE_DRAW;
            D3D12_COMMAND_SIGNATURE_DESC csd{sizeof(D3D12_DRAW_ARGUMENTS), 1, &iad, 0};
            ComPtr<ID3D12CommandSignature> cmd_sig;
            r.dev->CreateCommandSignature(&csd, nullptr, IID_PPV_ARGS(&cmd_sig));

            r.reset_cmd(cpso.Get());
            ID3D12DescriptorHeap* heaps[1] = {heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetComputeRootSignature(crs.Get());
            r.cmd->SetComputeRootConstantBufferView(0, cull_cb->GetGPUVirtualAddress());
            r.cmd->SetComputeRootDescriptorTable(1, heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->Dispatch(1, 1, 1);

            D3D12_RESOURCE_BARRIER b_ind[3] = {
                make_transition(args_buf.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT),
                make_transition(cnt_buf.Get(),  D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT),
                make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET),
            };
            r.cmd->ResourceBarrier(3, b_ind);

            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), static_cast<UINT>(verts.size() * sizeof(ColorVertex2D)), sizeof(ColorVertex2D)};
            r.cmd->SetPipelineState(gpso.Get());
            const float bg[4] = {0.03f, 0.04f, 0.07f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(grs.Get());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->ExecuteIndirect(cmd_sig.Get(), kN, args_buf.Get(), 0, cnt_buf.Get(), 0);

            D3D12_RESOURCE_BARRIER b_done[2] = {
                make_transition(cnt_buf.Get(), D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT, D3D12_RESOURCE_STATE_COPY_SOURCE),
                make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON),
            };
            r.cmd->ResourceBarrier(2, b_done);
            r.cmd->CopyBufferRegion(cnt_rb.Get(), 0, cnt_buf.Get(), 0, sizeof(zero_cnt));
            r.submit_and_wait();

            uint32_t got_cnt[2] = {0u, 0u};
            void* mapped = nullptr;
            D3D12_RANGE rr{0, sizeof(got_cnt)};
            if (SUCCEEDED(cnt_rb->Map(0, &rr, &mapped))) {
                std::memcpy(got_cnt, mapped, sizeof(got_cnt));
                D3D12_RANGE empty{0, 0};
                cnt_rb->Unmap(0, &empty);
            }
            const uint64_t gpu_pack = (static_cast<uint64_t>(got_cnt[0]) << 32) | got_cnt[1];
            const uint64_t exp_pack = (static_cast<uint64_t>(expected_count) << 32) | expected_hash;
            rec.compute_checksum = dm::hex64(gpu_pack);
            rec.expected_compute_checksum = dm::hex64(exp_pack);
            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = (gpu_pack == exp_pack) ? "pass" : "fail";
                rec.detail = "Compute cull (" + std::to_string(got_cnt[0]) + "/64 kept) + ExecuteIndirect CountBuffer";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 4. eng_04_hdr_bloom_tonemap
    {
        dm::TestRecord rec;
        rec.name = "eng_04_hdr_bloom_tonemap";
        rec.shader_model = "vs_6_0/cs_6_0/ps_6_0 (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;

        D3D12_ROOT_SIGNATURE_DESC rs_empty_desc{};
        D3D12_DESCRIPTOR_RANGE comp_rng[2] = {
            {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND},
            {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND},
        };
        D3D12_ROOT_PARAMETER comp_rp[2]{};
        comp_rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        comp_rp[0].DescriptorTable = {1, &comp_rng[0]};
        comp_rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        comp_rp[1].DescriptorTable = {1, &comp_rng[1]};
        D3D12_ROOT_SIGNATURE_DESC rs_comp_desc{2, comp_rp, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};

        D3D12_DESCRIPTOR_RANGE tone_rng{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        D3D12_ROOT_PARAMETER tone_rp{};
        tone_rp.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        tone_rp.DescriptorTable = {1, &tone_rng};
        tone_rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC ss{};
        ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        ss.MaxLOD = D3D12_FLOAT32_MAX;
        ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rs_tone_desc{1, &tone_rp, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_NONE};

        ComPtr<ID3D12RootSignature> rs_empty, rs_comp, rs_tone;
        if (create_root_sig(r.dev.Get(), rs_empty_desc, rs_empty, err) &&
            create_root_sig(r.dev.Get(), rs_comp_desc, rs_comp, err) &&
            create_root_sig(r.dev.Get(), rs_tone_desc, rs_tone, err)) {
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_hdr{};
            pd_hdr.pRootSignature = rs_empty.Get();
            pd_hdr.VS = {kEng04HdrVS, sizeof(kEng04HdrVS)};
            pd_hdr.PS = {kEng04HdrPS, sizeof(kEng04HdrPS)};
            pd_hdr.BlendState = default_blend(1);
            pd_hdr.SampleMask = UINT_MAX;
            pd_hdr.RasterizerState = make_rasterizer(D3D12_CULL_MODE_NONE);
            pd_hdr.DepthStencilState = make_depth_state(false, false);
            pd_hdr.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd_hdr.NumRenderTargets = 1;
            pd_hdr.RTVFormats[0] = DXGI_FORMAT_R16G16B16A16_FLOAT;
            pd_hdr.SampleDesc = {1, 0};

            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd_tone = pd_hdr;
            pd_tone.pRootSignature = rs_tone.Get();
            pd_tone.VS = {kEng04TonemapVS, sizeof(kEng04TonemapVS)};
            pd_tone.PS = {kEng04TonemapPS, sizeof(kEng04TonemapPS)};
            pd_tone.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;

            D3D12_COMPUTE_PIPELINE_STATE_DESC cpd_h{rs_comp.Get(), {kEng04BlurHCS, sizeof(kEng04BlurHCS)}};
            D3D12_COMPUTE_PIPELINE_STATE_DESC cpd_v{rs_comp.Get(), {kEng04BlurVCS, sizeof(kEng04BlurVCS)}};

            ComPtr<ID3D12PipelineState> pso_hdr, pso_tone, pso_h, pso_v;
            r.dev->CreateGraphicsPipelineState(&pd_hdr, IID_PPV_ARGS(&pso_hdr));
            r.dev->CreateGraphicsPipelineState(&pd_tone, IID_PPV_ARGS(&pso_tone));
            r.dev->CreateComputePipelineState(&cpd_h, IID_PPV_ARGS(&pso_h));
            r.dev->CreateComputePipelineState(&cpd_v, IID_PPV_ARGS(&pso_v));

            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            D3D12_CLEAR_VALUE hdr_cv{};
            hdr_cv.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
            auto td_hdr = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
            auto td_uav = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            ComPtr<ID3D12Resource> hdr_tex, bloom_a, bloom_b;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td_hdr,
                                           D3D12_RESOURCE_STATE_RENDER_TARGET, &hdr_cv, IID_PPV_ARGS(&hdr_tex));
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td_uav,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&bloom_a));
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &td_uav,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&bloom_b));

            D3D12_CPU_DESCRIPTOR_HANDLE hdr_rtv = r.rtv_at(6);
            r.dev->CreateRenderTargetView(hdr_tex.Get(), nullptr, hdr_rtv);

            // Descriptor heap slots:
            // 0: hdr_tex SRV (also start of [t0,t1] for tonemap if bloom_b SRV is slot 1!)
            // 1: bloom_b SRV
            // 2: bloom_a SRV
            // 3: bloom_a UAV
            // 4: bloom_b UAV
            D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 5, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> heap;
            r.dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap));
            auto c0 = heap->GetCPUDescriptorHandleForHeapStart();
            auto g0 = heap->GetGPUDescriptorHandleForHeapStart();
            r.dev->CreateShaderResourceView(hdr_tex.Get(), nullptr, c0);
            r.dev->CreateShaderResourceView(bloom_b.Get(), nullptr, {c0.ptr + r.srv_inc});
            r.dev->CreateShaderResourceView(bloom_a.Get(), nullptr, {c0.ptr + 2 * r.srv_inc});
            r.dev->CreateUnorderedAccessView(bloom_a.Get(), nullptr, nullptr, {c0.ptr + 3 * r.srv_inc});
            r.dev->CreateUnorderedAccessView(bloom_b.Get(), nullptr, nullptr, {c0.ptr + 4 * r.srv_inc});

            r.reset_cmd(pso_hdr.Get());
            r.set_viewport_scissor();
            r.cmd->SetGraphicsRootSignature(rs_empty.Get());
            r.cmd->OMSetRenderTargets(1, &hdr_rtv, FALSE, nullptr);
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->DrawInstanced(3, 1, 0, 0);

            auto b_hdr = make_transition(hdr_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
                                         D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            r.cmd->ResourceBarrier(1, &b_hdr);

            ID3D12DescriptorHeap* heaps[1] = {heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetComputeRootSignature(rs_comp.Get());

            // Bright-pass + horizontal blur: t0=hdr_tex (0), u0=bloom_a (3)
            r.cmd->SetPipelineState(pso_h.Get());
            r.cmd->SetComputeRootDescriptorTable(0, g0);
            r.cmd->SetComputeRootDescriptorTable(1, {g0.ptr + 3 * r.srv_inc});
            r.cmd->Dispatch(kWidth / 8, kHeight / 8, 1);

            auto b_ba = make_transition(bloom_a.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            r.cmd->ResourceBarrier(1, &b_ba);

            // Vertical blur: t0=bloom_a (2), u0=bloom_b (4)
            r.cmd->SetPipelineState(pso_v.Get());
            r.cmd->SetComputeRootDescriptorTable(0, {g0.ptr + 2 * r.srv_inc});
            r.cmd->SetComputeRootDescriptorTable(1, {g0.ptr + 4 * r.srv_inc});
            r.cmd->Dispatch(kWidth / 8, kHeight / 8, 1);

            D3D12_RESOURCE_BARRIER b_tone[2] = {
                make_transition(bloom_b.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET),
            };
            r.cmd->ResourceBarrier(2, b_tone);

            r.cmd->SetPipelineState(pso_tone.Get());
            r.cmd->SetGraphicsRootSignature(rs_tone.Get());
            r.cmd->SetGraphicsRootDescriptorTable(0, g0); // t0=hdr_tex, t1=bloom_b
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.cmd->DrawInstanced(3, 1, 0, 0);

            auto b_end = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b_end);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "R16G16B16A16_FLOAT HDR -> CS separable bloom -> ACES tonemap";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 5. eng_05_wave_ops
    {
        dm::TestRecord rec;
        rec.name = "eng_05_wave_ops";
        rec.has_compute_checksum = true;
        rec.shader_model = "cs_6_0 WaveOps (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;

        D3D12_DESCRIPTOR_RANGE rng{D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 2, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        D3D12_ROOT_PARAMETER rp[2]{};
        rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        rp[0].Constants = {0, 0, 4};
        rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        rp[1].DescriptorTable = {1, &rng};
        D3D12_ROOT_SIGNATURE_DESC rsd{2, rp, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};

        ComPtr<ID3D12RootSignature> rs;
        if (create_root_sig(r.dev.Get(), rsd, rs, err)) {
            D3D12_COMPUTE_PIPELINE_STATE_DESC cpd{rs.Get(), {kEng05WaveOpsCS, sizeof(kEng05WaveOpsCS)}};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateComputePipelineState(&cpd, IID_PPV_ARGS(&pso));

            constexpr UINT kGroups = 16u * kHeight;
            auto hp_def = make_heap_props(D3D12_HEAP_TYPE_DEFAULT);
            auto tdesc = make_tex2d_desc(kWidth, kHeight, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            auto bdesc = make_buffer_desc(kGroups * sizeof(uint32_t), D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            ComPtr<ID3D12Resource> uav_tex, uav_buf, rb_buf;
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &tdesc,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&uav_tex));
            r.dev->CreateCommittedResource(&hp_def, D3D12_HEAP_FLAG_NONE, &bdesc,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&uav_buf));
            auto hp_rb = make_heap_props(D3D12_HEAP_TYPE_READBACK);
            auto rbd = make_buffer_desc(kGroups * sizeof(uint32_t));
            r.dev->CreateCommittedResource(&hp_rb, D3D12_HEAP_FLAG_NONE, &rbd,
                                           D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&rb_buf));

            D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> heap;
            r.dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap));
            auto h0 = heap->GetCPUDescriptorHandleForHeapStart();
            r.dev->CreateUnorderedAccessView(uav_tex.Get(), nullptr, nullptr, h0);
            D3D12_UNORDERED_ACCESS_VIEW_DESC buav{};
            buav.Format = DXGI_FORMAT_UNKNOWN;
            buav.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
            buav.Buffer = {0, kGroups, sizeof(uint32_t), 0, D3D12_BUFFER_UAV_FLAG_NONE};
            r.dev->CreateUnorderedAccessView(uav_buf.Get(), nullptr, &buav, {h0.ptr + r.srv_inc});

            const uint32_t seed = 1337u;
            const uint32_t root_consts[4] = {seed, kWidth, kHeight, 0u};

            r.reset_cmd(pso.Get());
            ID3D12DescriptorHeap* heaps[1] = {heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetComputeRootSignature(rs.Get());
            r.cmd->SetComputeRoot32BitConstants(0, 4, root_consts, 0);
            r.cmd->SetComputeRootDescriptorTable(1, heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->Dispatch(16, kHeight, 1);

            auto bb = make_transition(uav_buf.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
            r.cmd->ResourceBarrier(1, &bb);
            r.cmd->CopyBufferRegion(rb_buf.Get(), 0, uav_buf.Get(), 0, kGroups * sizeof(uint32_t));
            r.submit_and_wait();

            uint64_t gpu_sum = 0;
            void* mapped = nullptr;
            D3D12_RANGE rr{0, kGroups * sizeof(uint32_t)};
            if (SUCCEEDED(rb_buf->Map(0, &rr, &mapped))) {
                const uint32_t* p = static_cast<const uint32_t*>(mapped);
                for (UINT i = 0; i < kGroups; ++i) gpu_sum += static_cast<uint64_t>(p[i]);
                D3D12_RANGE empty{0, 0};
                rb_buf->Unmap(0, &empty);
            }

            uint64_t expected_sum = 0;
            for (uint32_t gy = 0; gy < kHeight; ++gy) {
                for (uint32_t gx = 0; gx < 16u; ++gx) {
                    uint32_t gsum = 0;
                    for (uint32_t lx = 0; lx < 32u; ++lx) {
                        const uint32_t x = gx * 32u + lx;
                        const uint32_t code = ((x & 15u) + 1u) * ((gy & 15u) + 1u) + ((seed ^ gx ^ gy) & 31u);
                        gsum += code;
                    }
                    expected_sum += static_cast<uint64_t>(gsum);
                }
            }
            rec.compute_checksum = dm::hex64(gpu_sum);
            rec.expected_compute_checksum = dm::hex64(expected_sum);
            if (r.readback_tex_to_png(uav_tex.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, opts.out_dir, rec)) {
                rec.status = (gpu_sum == expected_sum) ? "pass" : "fail";
                rec.detail = rec.status == "pass" ? "WaveActiveSum/PrefixSum/BitXor + RootConstants bit-exact"
                                                  : "Wave reduction checksum mismatch";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 6. eng_06_bindless
    {
        dm::TestRecord rec;
        rec.name = "eng_06_bindless";
        rec.shader_model = "vs_6_0/ps_6_0 Bindless (DXIL)";
        const double t0 = dm::now_ms();
        std::string err;

        D3D12_DESCRIPTOR_RANGE rng{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 16, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND};
        D3D12_ROOT_PARAMETER rp[2]{};
        rp[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        rp[0].DescriptorTable = {1, &rng};
        rp[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        rp[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV;
        rp[1].Descriptor = {0, 1}; // t0, space1
        rp[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_STATIC_SAMPLER_DESC ss{};
        ss.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        ss.AddressU = ss.AddressV = ss.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        ss.MaxLOD = D3D12_FLOAT32_MAX;
        ss.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rsd{2, rp, 1, &ss, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};

        ComPtr<ID3D12RootSignature> rs;
        if (create_root_sig(r.dev.Get(), rsd, rs, err)) {
            const D3D12_INPUT_ELEMENT_DESC ied[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,    0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
            pd.pRootSignature = rs.Get();
            pd.VS = {kEng06BindlessVS, sizeof(kEng06BindlessVS)};
            pd.PS = {kEng06BindlessPS, sizeof(kEng06BindlessPS)};
            pd.BlendState = default_blend(1);
            pd.SampleMask = UINT_MAX;
            pd.RasterizerState = make_rasterizer(D3D12_CULL_MODE_NONE);
            pd.DepthStencilState = make_depth_state(false, false);
            pd.InputLayout = {ied, 2};
            pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            pd.NumRenderTargets = 1;
            pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            pd.SampleDesc = {1, 0};
            ComPtr<ID3D12PipelineState> pso;
            r.dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso));

            // 16 distinct 64x64 procedural textures
            D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 16, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
            ComPtr<ID3D12DescriptorHeap> heap;
            r.dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap));
            std::vector<ComPtr<ID3D12Resource>> textures(16);
            std::vector<uint8_t> rgba(64u * 64u * 4u);

            for (UINT ti = 0; ti < 16; ++ti) {
                for (UINT y = 0; y < 64; ++y) {
                    for (UINT x = 0; x < 64; ++x) {
                        const float fx = static_cast<float>(x) / 64.0f;
                        const float fy = static_cast<float>(y) / 64.0f;
                        float r_c = 0.0f, g_c = 0.0f, b_c = 0.0f;
                        switch (ti & 3u) {
                            case 0: {
                                const bool chk = (((x >> 3) + (y >> 3)) & 1u) == 0u;
                                r_c = chk ? 0.95f : 0.15f; g_c = chk ? 0.85f : 0.25f; b_c = chk ? 0.30f : 0.85f;
                            } break;
                            case 1: {
                                const float dist = std::hypot(fx - 0.5f, fy - 0.5f);
                                const float ring = 0.5f + 0.5f * std::sin(dist * (24.0f + 4.0f * (ti >> 2)));
                                r_c = ring; g_c = 1.0f - ring * 0.6f; b_c = fx;
                            } break;
                            case 2: {
                                const float diag = 0.5f + 0.5f * std::sin((fx * 2.0f + fy * (1.0f + (ti >> 2))) * kPi * 3.0f);
                                r_c = fy; g_c = diag; b_c = 0.2f + 0.7f * diag;
                            } break;
                            default: {
                                const float gx = std::fabs(std::fmod(fx * 4.0f, 1.0f) - 0.5f);
                                const float gy = std::fabs(std::fmod(fy * 4.0f, 1.0f) - 0.5f);
                                const float d = std::hypot(gx, gy);
                                const float dot_m = d < 0.32f ? 1.0f : 0.2f;
                                r_c = dot_m * (0.4f + 0.15f * (ti >> 2));
                                g_c = dot_m * 0.85f;
                                b_c = 0.35f + 0.5f * (1.0f - dot_m);
                            } break;
                        }
                        const size_t p = (static_cast<size_t>(y) * 64u + x) * 4u;
                        rgba[p + 0] = static_cast<uint8_t>(std::clamp(r_c, 0.0f, 1.0f) * 255.0f);
                        rgba[p + 1] = static_cast<uint8_t>(std::clamp(g_c, 0.0f, 1.0f) * 255.0f);
                        rgba[p + 2] = static_cast<uint8_t>(std::clamp(b_c, 0.0f, 1.0f) * 255.0f);
                        rgba[p + 3] = 255u;
                    }
                }
                r.create_rgba8_texture_uploaded(64, 64, rgba.data(), D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, textures[ti]);
                D3D12_CPU_DESCRIPTOR_HANDLE h{heap->GetCPUDescriptorHandleForHeapStart().ptr + static_cast<SIZE_T>(ti) * r.srv_inc};
                r.dev->CreateShaderResourceView(textures[ti].Get(), nullptr, h);
            }

            struct MatInfo {
                uint32_t texIdx, pad0, pad1, pad2;
                float tint[4];
                float uvScaleOff[4];
            };
            std::vector<MatInfo> mats(64);
            for (UINT i = 0; i < 64; ++i) {
                mats[i].texIdx = (i * 5u + (i >> 3)) & 15u;
                mats[i].pad0 = mats[i].pad1 = mats[i].pad2 = 0u;
                mats[i].tint[0] = 0.65f + 0.35f * static_cast<float>(i & 7u) / 7.0f;
                mats[i].tint[1] = 0.65f + 0.35f * static_cast<float>(i >> 3) / 7.0f;
                mats[i].tint[2] = 0.90f - 0.30f * static_cast<float>((i & 7u) == (i >> 3));
                mats[i].tint[3] = 1.0f;
                mats[i].uvScaleOff[0] = 1.0f + 0.5f * static_cast<float>(i % 3u);
                mats[i].uvScaleOff[1] = 1.0f + 0.5f * static_cast<float>((i >> 2) % 3u);
                mats[i].uvScaleOff[2] = 0.0f;
                mats[i].uvScaleOff[3] = 0.0f;
            }
            const UVVertex2D quad[6] = {
                {-1.0f, -1.0f, 0.0f, 0.0f, 1.0f},
                {-1.0f,  1.0f, 0.0f, 0.0f, 0.0f},
                { 1.0f,  1.0f, 0.0f, 1.0f, 0.0f},
                {-1.0f, -1.0f, 0.0f, 0.0f, 1.0f},
                { 1.0f,  1.0f, 0.0f, 1.0f, 0.0f},
                { 1.0f, -1.0f, 0.0f, 1.0f, 1.0f},
            };
            ComPtr<ID3D12Resource> vb, mat_buf;
            r.create_default_buffer_uploaded(quad, sizeof(quad), D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, vb);
            r.create_default_buffer_uploaded(mats.data(), mats.size() * sizeof(MatInfo),
                                             D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, mat_buf);
            D3D12_VERTEX_BUFFER_VIEW vbv{vb->GetGPUVirtualAddress(), sizeof(quad), sizeof(UVVertex2D)};

            r.reset_cmd(pso.Get());
            auto b0 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.cmd->ResourceBarrier(1, &b0);
            const float bg[4] = {0.03f, 0.03f, 0.05f, 1.0f};
            r.cmd->ClearRenderTargetView(r.rtv_handle, bg, 0, nullptr);
            r.cmd->OMSetRenderTargets(1, &r.rtv_handle, FALSE, nullptr);
            r.set_viewport_scissor();
            ID3D12DescriptorHeap* heaps[1] = {heap.Get()};
            r.cmd->SetDescriptorHeaps(1, heaps);
            r.cmd->SetGraphicsRootSignature(rs.Get());
            r.cmd->SetGraphicsRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
            r.cmd->SetGraphicsRootShaderResourceView(1, mat_buf->GetGPUVirtualAddress());
            r.cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            r.cmd->IASetVertexBuffers(0, 1, &vbv);
            r.cmd->DrawInstanced(6, 64, 0, 0);
            auto b1 = make_transition(r.rt_tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON);
            r.cmd->ResourceBarrier(1, &b1);
            r.submit_and_wait();

            if (r.readback_tex_to_png(r.rt_tex.Get(), D3D12_RESOURCE_STATE_COMMON, opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "16-texture SM 6.0 NonUniformResourceIndex table + 64 instanced tiles";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 7. eng_bench_deferred_pbr (1024x1024)
    dm::BenchStats bench;
    {
        std::string err;
        DeferredPipelineResources dpr;
        constexpr UINT kBenchObjs = 25; // floor + 24 animated PBR meshes
        if (init_deferred_pipeline(r, kBenchWidth, kBenchHeight, 2, kBenchObjs, dpr, err)) {
            ComPtr<ID3D12CommandAllocator> ring_allocs[2];
            r.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&ring_allocs[0]));
            r.dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&ring_allocs[1]));

            D3D12_QUERY_HEAP_DESC qhd{D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 4, 0};
            ComPtr<ID3D12QueryHeap> qheap;
            r.dev->CreateQueryHeap(&qhd, IID_PPV_ARGS(&qheap));
            auto hp_rb = make_heap_props(D3D12_HEAP_TYPE_READBACK);
            auto rb_d = make_buffer_desc(sizeof(UINT64) * 4);
            ComPtr<ID3D12Resource> ts_rb;
            r.dev->CreateCommittedResource(&hp_rb, D3D12_HEAP_FLAG_NONE, &rb_d,
                                           D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&ts_rb));
            UINT64 ts_freq = 0;
            r.queue->GetTimestampFrequency(&ts_freq);

            constexpr int kWarmup = 20;
            const int total_frames = kWarmup + opts.frames;
            std::vector<double> frame_times;
            frame_times.reserve(static_cast<size_t>(opts.frames));
            double gpu_ms_sum = 0.0;
            int gpu_ms_count = 0;
            D3D12_RANGE empty{0, 0};

            for (int f = 0; f < total_frames; ++f) {
                const int slot = f & 1;
                const float phase = static_cast<float>(f) * 0.06f;
                write_deferred_scene_cbs(dpr, static_cast<UINT>(slot), kBenchObjs, phase, 1.0f);

                const double ft0 = dm::now_ms();
                ring_allocs[slot]->Reset();
                r.cmd->Reset(ring_allocs[slot].Get(), dpr.pso_geom.Get());
                if (f >= kWarmup) {
                    r.cmd->EndQuery(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2);
                }
                record_deferred_frame(r.cmd.Get(), dpr, kBenchWidth, kBenchHeight,
                                      static_cast<UINT>(slot), kBenchObjs, f == 0);
                if (f >= kWarmup) {
                    r.cmd->EndQuery(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2 + 1);
                    r.cmd->ResolveQueryData(qheap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, slot * 2, 2,
                                            ts_rb.Get(), static_cast<UINT64>(slot * 2) * sizeof(UINT64));
                }
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
            dpr.geom_cb_buf->Unmap(0, nullptr);
            dpr.light_cb_buf->Unmap(0, nullptr);

            bench = dm::summarize_bench(frame_times, kWarmup);
            bench.gpu_mean_ms = gpu_ms_count > 0 ? (gpu_ms_sum / gpu_ms_count) : 0.0;
            bench.extra_metric_name = "megapixels_per_sec";
            const double mp_per_frame = (static_cast<double>(kBenchWidth) * kBenchHeight) / 1e6;
            bench.extra_ops_per_sec = bench.fps * mp_per_frame;
        }
    }

    const std::string json_path = dm::join_path(opts.out_dir, "engine_results.json");
    if (!write_engine_results_json(json_path, max_fl, selected.meta, records, bench)) {
        std::cerr << "Failed to write " << json_path << "\n";
        return 1;
    }

    int pass_count = 0;
    for (const auto& rrec : records) {
        if (rrec.status == "pass") ++pass_count;
        std::cout << "  " << rrec.name << ": " << rrec.status
                  << " (checksum=" << rrec.pixel_checksum << ", " << rrec.duration_ms << " ms)\n";
    }
    std::cout << "[D3D12-Engine] Summary: " << pass_count << "/" << records.size()
              << " | Bench 1024x1024 mean=" << bench.mean_ms << " ms (" << bench.fps
              << " FPS, 1%-low=" << bench.one_percent_low_fps << " FPS)\n";
    return pass_count == static_cast<int>(records.size()) ? 0 : 2;
}
