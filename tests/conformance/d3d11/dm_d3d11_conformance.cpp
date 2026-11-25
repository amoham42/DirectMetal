#include "dm_dxgi_select.hpp"
#include "dm_metrics.hpp"
#include "dm_png_writer.hpp"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>

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

struct VertexPosUV {
    float x, y;
    float u, v;
};

struct GridVertex {
    float x, y;
    uint32_t quad_id;
};

struct GridCBuffer {
    float offset_scale[4];
    float colors[16][4];
};

struct InstanceData {
    float rect[4];   // cx, cy, half_w, half_h
    float color[4];  // r, g, b, a
};

struct BenchCBuffer {
    float transform[4];
    float color[4];
};

bool compile_hlsl(const char* source, const char* entry, const char* target,
                  ComPtr<ID3DBlob>& out_blob, std::string& err_msg) {
    ComPtr<ID3DBlob> err;
    HRESULT hr = D3DCompile(source, std::strlen(source), entry, nullptr, nullptr,
                            entry, target, D3DCOMPILE_ENABLE_STRICTNESS, 0,
                            &out_blob, &err);
    if (FAILED(hr)) {
        if (err) {
            err_msg.assign(static_cast<const char*>(err->GetBufferPointer()),
                           err->GetBufferSize());
        } else {
            err_msg = "D3DCompile failed with HR=" + std::to_string(static_cast<long>(hr));
        }
        return false;
    }
    return true;
}

bool create_rgba_rtv(ID3D11Device* dev, UINT w, UINT h, UINT bind_extra,
                     ComPtr<ID3D11Texture2D>& tex,
                     ComPtr<ID3D11RenderTargetView>& rtv,
                     ComPtr<ID3D11ShaderResourceView>* srv = nullptr) {
    D3D11_TEXTURE2D_DESC td{};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc = {1, 0};
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | bind_extra;
    if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))) return false;
    if (FAILED(dev->CreateRenderTargetView(tex.Get(), nullptr, &rtv))) return false;
    if (srv) {
        if (FAILED(dev->CreateShaderResourceView(tex.Get(), nullptr, srv->GetAddressOf()))) {
            return false;
        }
    }
    return true;
}

bool readback_rgba8(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* src,
                    UINT w, UINT h, std::vector<uint8_t>& out_tight) {
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = w;
    sd.Height = h;
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc = {1, 0};
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(dev->CreateTexture2D(&sd, nullptr, &staging))) return false;

    ctx->CopyResource(staging.Get(), src);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;

    out_tight.resize(static_cast<size_t>(w) * h * 4u);
    const uint8_t* src_bytes = static_cast<const uint8_t*>(mapped.pData);
    for (UINT y = 0; y < h; ++y) {
        std::memcpy(out_tight.data() + static_cast<size_t>(y) * w * 4u,
                    src_bytes + static_cast<size_t>(y) * mapped.RowPitch,
                    static_cast<size_t>(w) * 4u);
    }
    ctx->Unmap(staging.Get(), 0);
    return true;
}

bool save_and_record(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* tex,
                     const std::string& out_dir, dm::TestRecord& rec,
                     std::vector<uint8_t>* out_pixels = nullptr) {
    std::vector<uint8_t> pixels;
    if (!readback_rgba8(dev, ctx, tex, kWidth, kHeight, pixels)) {
        rec.status = "fail";
        rec.detail = "Readback failed";
        return false;
    }
    rec.png_file = rec.name + ".png";
    const std::string full_png = dm::join_path(out_dir, rec.png_file);
    if (!dm::write_png_rgba8(full_png, kWidth, kHeight, pixels.data(), kWidth * 4u)) {
        rec.status = "fail";
        rec.detail = "PNG write failed";
        return false;
    }
    rec.pixel_checksum = dm::hex64(dm::fnv1a64(pixels.data(), pixels.size()));
    if (out_pixels) {
        *out_pixels = std::move(pixels);
    }
    return true;
}

void set_full_viewport(ID3D11DeviceContext* ctx) {
    D3D11_VIEWPORT vp{0.0f, 0.0f, static_cast<float>(kWidth), static_cast<float>(kHeight), 0.0f, 1.0f};
    ctx->RSSetViewports(1, &vp);
}

std::string fl_to_string(D3D_FEATURE_LEVEL fl) {
    switch (fl) {
        case D3D_FEATURE_LEVEL_12_2: return "12_2";
        case D3D_FEATURE_LEVEL_12_1: return "12_1";
        case D3D_FEATURE_LEVEL_12_0: return "12_0";
        case D3D_FEATURE_LEVEL_11_1: return "11_1";
        case D3D_FEATURE_LEVEL_11_0: return "11_0";
        case D3D_FEATURE_LEVEL_10_1: return "10_1";
        case D3D_FEATURE_LEVEL_10_0: return "10_0";
        default: return "unknown";
    }
}

const char* kCommonVSPS = R"(
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

    const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
    };
    D3D_FEATURE_LEVEL achieved = D3D_FEATURE_LEVEL_11_0;
    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;

    HRESULT hr = D3D11CreateDevice(
        selected.adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
        levels, static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
        &dev, &achieved, &ctx);
    if (FAILED(hr)) {
        std::cerr << "D3D11CreateDevice failed: 0x" << std::hex << hr << "\n";
        return 1;
    }

    std::cout << "[D3D11] Adapter: " << selected.meta.description
              << " | FL: " << fl_to_string(achieved) << "\n";

    ComPtr<ID3D11Texture2D> main_tex;
    ComPtr<ID3D11RenderTargetView> main_rtv;
    if (!create_rgba_rtv(dev.Get(), kWidth, kHeight, 0, main_tex, main_rtv)) {
        std::cerr << "Failed to create main RTV\n";
        return 1;
    }

    std::vector<dm::TestRecord> records;

    // 1. d3d11_01_clear_color
    {
        dm::TestRecord rec;
        rec.name = "d3d11_01_clear_color";
        const double t0 = dm::now_ms();
        const float clear_col[4] = {0.18f, 0.42f, 0.77f, 1.0f};
        ctx->ClearState();
        ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
        ctx->ClearRenderTargetView(main_rtv.Get(), clear_col);
        std::vector<uint8_t> px;
        if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec, &px)) {
            const size_t center = (static_cast<size_t>(kHeight / 2) * kWidth + (kWidth / 2)) * 4u;
            const int dr = std::abs(static_cast<int>(px[center + 0]) - 46);
            const int dg = std::abs(static_cast<int>(px[center + 1]) - 107);
            const int db = std::abs(static_cast<int>(px[center + 2]) - 196);
            if (dr <= 2 && dg <= 2 && db <= 2) {
                rec.status = "pass";
                rec.detail = "Clear RGBA matched target tolerance";
            } else {
                rec.status = "fail";
                rec.detail = "Center pixel mismatch";
            }
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 2. d3d11_02_triangle_interp
    {
        dm::TestRecord rec;
        rec.name = "d3d11_02_triangle_interp";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(kCommonVSPS, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(kCommonVSPS, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            const VertexPosColor verts[3] = {
                {0.0f, 0.78f, 0.0f, 1.0f, 0.1f, 0.1f, 1.0f},
                {0.78f, -0.78f, 0.0f, 0.1f, 1.0f, 0.1f, 1.0f},
                {-0.78f, -0.78f, 0.0f, 0.1f, 0.1f, 1.0f, 1.0f},
            };
            D3D11_BUFFER_DESC bd{sizeof(verts), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA init{verts, 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&bd, &init, &vb);

            ctx->ClearState();
            const float bg[4] = {0.08f, 0.10f, 0.14f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(VertexPosColor), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);
            ctx->Draw(3, 0);

            std::vector<uint8_t> px;
            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec, &px)) {
                const size_t c = (static_cast<size_t>(kHeight / 2) * kWidth + (kWidth / 2)) * 4u;
                rec.status = (px[c] > 40 && px[c + 1] > 40 && px[c + 2] > 40) ? "pass" : "fail";
                rec.detail = rec.status == "pass" ? "Barycentric RGB triangle rendered" : "Triangle missing at center";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 3. d3d11_03_indexed_cbuffer
    {
        dm::TestRecord rec;
        rec.name = "d3d11_03_indexed_cbuffer";
        const double t0 = dm::now_ms();
        const char* hlsl = R"(
cbuffer GridCB : register(b0) {
    float4 offset_scale;
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
    float2 p = input.pos * offset_scale.zw + offset_scale.xy;
    o.pos = float4(p, 0.0f, 1.0f);
    o.col = colors[input.quad_id];
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return input.col;
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(hlsl, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(hlsl, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32_UINT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            std::vector<GridVertex> verts;
            std::vector<uint16_t> indices;
            for (uint32_t gy = 0; gy < 4; ++gy) {
                for (uint32_t gx = 0; gx < 4; ++gx) {
                    const uint32_t qid = gy * 4 + gx;
                    const float x0 = -0.8f + gx * 0.42f;
                    const float y0 = -0.8f + gy * 0.42f;
                    const float x1 = x0 + 0.34f;
                    const float y1 = y0 + 0.34f;
                    const uint16_t base = static_cast<uint16_t>(verts.size());
                    verts.push_back({x0, y0, qid});
                    verts.push_back({x0, y1, qid});
                    verts.push_back({x1, y1, qid});
                    verts.push_back({x1, y0, qid});
                    indices.push_back(base + 0);
                    indices.push_back(base + 1);
                    indices.push_back(base + 2);
                    indices.push_back(base + 0);
                    indices.push_back(base + 2);
                    indices.push_back(base + 3);
                }
            }

            D3D11_BUFFER_DESC vbd{static_cast<UINT>(verts.size() * sizeof(GridVertex)), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA vinit{verts.data(), 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &vinit, &vb);

            D3D11_BUFFER_DESC ibd{static_cast<UINT>(indices.size() * sizeof(uint16_t)), D3D11_USAGE_DEFAULT, D3D11_BIND_INDEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA iinit{indices.data(), 0, 0};
            ComPtr<ID3D11Buffer> ib;
            dev->CreateBuffer(&ibd, &iinit, &ib);

            D3D11_BUFFER_DESC cbd{sizeof(GridCBuffer), D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
            ComPtr<ID3D11Buffer> cb;
            dev->CreateBuffer(&cbd, nullptr, &cb);

            D3D11_MAPPED_SUBRESOURCE m{};
            ctx->Map(cb.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m);
            auto* cb_ptr = static_cast<GridCBuffer*>(m.pData);
            cb_ptr->offset_scale[0] = 0.0f;
            cb_ptr->offset_scale[1] = 0.0f;
            cb_ptr->offset_scale[2] = 0.95f;
            cb_ptr->offset_scale[3] = 0.95f;
            for (int i = 0; i < 16; ++i) {
                cb_ptr->colors[i][0] = 0.15f + 0.25f * static_cast<float>(i % 4);
                cb_ptr->colors[i][1] = 0.20f + 0.22f * static_cast<float>(i / 4);
                cb_ptr->colors[i][2] = 0.85f - 0.04f * static_cast<float>(i);
                cb_ptr->colors[i][3] = 1.0f;
            }
            ctx->Unmap(cb.Get(), 0);

            ctx->ClearState();
            const float bg[4] = {0.06f, 0.07f, 0.09f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(GridVertex), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetIndexBuffer(ib.Get(), DXGI_FORMAT_R16_UINT, 0);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->VSSetConstantBuffers(0, 1, cb.GetAddressOf());
            ctx->PSSetShader(ps.Get(), nullptr, 0);
            ctx->DrawIndexed(static_cast<UINT>(indices.size()), 0, 0);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "4x4 indexed grid with dynamic cbuffer";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 4. d3d11_04_depth_stencil
    {
        dm::TestRecord rec;
        rec.name = "d3d11_04_depth_stencil";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(kCommonVSPS, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(kCommonVSPS, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            D3D11_TEXTURE2D_DESC dtd{};
            dtd.Width = kWidth;
            dtd.Height = kHeight;
            dtd.MipLevels = 1;
            dtd.ArraySize = 1;
            dtd.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
            dtd.SampleDesc = {1, 0};
            dtd.Usage = D3D11_USAGE_DEFAULT;
            dtd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
            ComPtr<ID3D11Texture2D> ds_tex;
            ComPtr<ID3D11DepthStencilView> dsv;
            dev->CreateTexture2D(&dtd, nullptr, &ds_tex);
            dev->CreateDepthStencilView(ds_tex.Get(), nullptr, &dsv);

            // Stencil write state (no color write, write stencil=1)
            D3D11_BLEND_DESC no_color_desc{};
            no_color_desc.RenderTarget[0].RenderTargetWriteMask = 0;
            ComPtr<ID3D11BlendState> no_color_bs;
            dev->CreateBlendState(&no_color_desc, &no_color_bs);

            D3D11_DEPTH_STENCIL_DESC ds_write_mask{};
            ds_write_mask.DepthEnable = FALSE;
            ds_write_mask.StencilEnable = TRUE;
            ds_write_mask.StencilReadMask = 0xFF;
            ds_write_mask.StencilWriteMask = 0xFF;
            ds_write_mask.FrontFace = {D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_REPLACE, D3D11_COMPARISON_ALWAYS};
            ds_write_mask.BackFace = ds_write_mask.FrontFace;
            ComPtr<ID3D11DepthStencilState> dss_mask;
            dev->CreateDepthStencilState(&ds_write_mask, &dss_mask);

            D3D11_DEPTH_STENCIL_DESC ds_test_desc{};
            ds_test_desc.DepthEnable = TRUE;
            ds_test_desc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
            ds_test_desc.DepthFunc = D3D11_COMPARISON_LESS;
            ds_test_desc.StencilEnable = TRUE;
            ds_test_desc.StencilReadMask = 0xFF;
            ds_test_desc.StencilWriteMask = 0x00;
            ds_test_desc.FrontFace = {D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_EQUAL};
            ds_test_desc.BackFace = ds_test_desc.FrontFace;
            ComPtr<ID3D11DepthStencilState> dss_test;
            dev->CreateDepthStencilState(&ds_test_desc, &dss_test);

            const VertexPosColor verts[] = {
                // Stencil mask quad (6 verts)
                {-0.65f, -0.65f, 0.5f, 1, 1, 1, 1},
                {-0.65f,  0.65f, 0.5f, 1, 1, 1, 1},
                { 0.65f,  0.65f, 0.5f, 1, 1, 1, 1},
                {-0.65f, -0.65f, 0.5f, 1, 1, 1, 1},
                { 0.65f,  0.65f, 0.5f, 1, 1, 1, 1},
                { 0.65f, -0.65f, 0.5f, 1, 1, 1, 1},
                // Intersecting triangle A (z: 0.2 left -> 0.8 right, warm orange)
                {-0.85f,  0.75f, 0.2f, 1.0f, 0.35f, 0.12f, 1.0f},
                { 0.85f,  0.00f, 0.8f, 1.0f, 0.55f, 0.15f, 1.0f},
                {-0.85f, -0.75f, 0.2f, 0.9f, 0.20f, 0.10f, 1.0f},
                // Intersecting triangle B (z: 0.8 left -> 0.2 right, cyan)
                { 0.85f,  0.75f, 0.2f, 0.10f, 0.85f, 0.95f, 1.0f},
                { 0.85f, -0.75f, 0.2f, 0.10f, 0.65f, 0.90f, 1.0f},
                {-0.85f,  0.00f, 0.8f, 0.20f, 0.95f, 0.70f, 1.0f},
            };
            D3D11_BUFFER_DESC vbd{sizeof(verts), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA init{verts, 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &init, &vb);

            D3D11_RASTERIZER_DESC rsd{};
            rsd.FillMode = D3D11_FILL_SOLID;
            rsd.CullMode = D3D11_CULL_NONE;
            ComPtr<ID3D11RasterizerState> rs_nocull;
            dev->CreateRasterizerState(&rsd, &rs_nocull);

            ctx->ClearState();
            const float bg[4] = {0.06f, 0.08f, 0.12f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->ClearDepthStencilView(dsv.Get(), D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 1.0f, 0);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), dsv.Get());
            set_full_viewport(ctx.Get());
            ctx->RSSetState(rs_nocull.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(VertexPosColor), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);

            // Stencil write pass
            ctx->OMSetBlendState(no_color_bs.Get(), nullptr, 0xFFFFFFFF);
            ctx->OMSetDepthStencilState(dss_mask.Get(), 1);
            ctx->Draw(6, 0);

            // Depth + stencil test pass
            ctx->OMSetBlendState(nullptr, nullptr, 0xFFFFFFFF);
            ctx->OMSetDepthStencilState(dss_test.Get(), 1);
            ctx->Draw(6, 6);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Depth intersection + stencil window cutout";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 5. d3d11_05_alpha_blend
    {
        dm::TestRecord rec;
        rec.name = "d3d11_05_alpha_blend";
        const double t0 = dm::now_ms();
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(kCommonVSPS, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(kCommonVSPS, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            auto make_quad = [](std::vector<VertexPosColor>& v, float x0, float y0, float x1, float y1,
                                float r, float g, float b, float a) {
                v.push_back({x0, y0, 0, r, g, b, a});
                v.push_back({x0, y1, 0, r, g, b, a});
                v.push_back({x1, y1, 0, r, g, b, a});
                v.push_back({x0, y0, 0, r, g, b, a});
                v.push_back({x1, y1, 0, r, g, b, a});
                v.push_back({x1, y0, 0, r, g, b, a});
            };
            std::vector<VertexPosColor> verts;
            // Background stripe quads (opaque)
            make_quad(verts, -0.9f, -0.9f, 0.9f, 0.9f, 0.16f, 0.18f, 0.24f, 1.0f);
            make_quad(verts, -0.9f, -0.25f, 0.9f, 0.25f, 0.28f, 0.30f, 0.36f, 1.0f);
            // Alpha-blended overlapping panels
            make_quad(verts, -0.7f, -0.5f, 0.25f, 0.65f, 0.95f, 0.20f, 0.20f, 0.60f);
            make_quad(verts, -0.25f, -0.65f, 0.7f, 0.5f, 0.15f, 0.90f, 0.35f, 0.55f);
            make_quad(verts, -0.45f, -0.35f, 0.45f, 0.35f, 0.15f, 0.45f, 0.98f, 0.50f);
            // Additive highlight
            make_quad(verts, -0.2f, -0.2f, 0.2f, 0.2f, 0.40f, 0.32f, 0.08f, 1.0f);

            D3D11_BUFFER_DESC vbd{static_cast<UINT>(verts.size() * sizeof(VertexPosColor)), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA init{verts.data(), 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &init, &vb);

            D3D11_BLEND_DESC alpha_desc{};
            alpha_desc.RenderTarget[0].BlendEnable = TRUE;
            alpha_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
            alpha_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
            alpha_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
            alpha_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
            alpha_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
            alpha_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
            alpha_desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
            ComPtr<ID3D11BlendState> bs_alpha;
            dev->CreateBlendState(&alpha_desc, &bs_alpha);

            D3D11_BLEND_DESC add_desc = alpha_desc;
            add_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
            add_desc.RenderTarget[0].DestBlend = D3D11_BLEND_ONE;
            ComPtr<ID3D11BlendState> bs_add;
            dev->CreateBlendState(&add_desc, &bs_add);

            ctx->ClearState();
            const float bg[4] = {0.07f, 0.09f, 0.12f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(VertexPosColor), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);

            ctx->Draw(12, 0);
            ctx->OMSetBlendState(bs_alpha.Get(), nullptr, 0xFFFFFFFF);
            ctx->Draw(18, 12);
            ctx->OMSetBlendState(bs_add.Get(), nullptr, 0xFFFFFFFF);
            ctx->Draw(6, 30);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Opaque + Porter-Duff alpha + additive blending";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 6. d3d11_06_texture_sampling
    {
        dm::TestRecord rec;
        rec.name = "d3d11_06_texture_sampling";
        const double t0 = dm::now_ms();
        const char* hlsl = R"(
Texture2D tex0 : register(t0);
SamplerState samp0 : register(s0);
SamplerState samp1 : register(s1);
struct VSIn {
    float2 pos : POSITION;
    float2 uv  : TEXCOORD0;
};
struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
    float2 quad_uv : TEXCOORD1;
};
PSIn VSMain(VSIn input) {
    PSIn o;
    o.pos = float4(input.pos, 0.0f, 1.0f);
    o.uv = input.uv;
    o.quad_uv = input.pos * 0.5f + 0.5f;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    if (input.quad_uv.x < 0.5f && input.quad_uv.y >= 0.5f) {
        return tex0.Sample(samp0, input.uv); // Top-left: Point Wrap
    } else if (input.quad_uv.x >= 0.5f && input.quad_uv.y >= 0.5f) {
        return tex0.Sample(samp1, input.uv); // Top-right: Linear Clamp
    } else if (input.quad_uv.x < 0.5f && input.quad_uv.y < 0.5f) {
        return tex0.SampleLevel(samp1, input.uv, 2.0f); // Bottom-left: Mip 2
    } else {
        return tex0.SampleLevel(samp1, input.uv, 4.0f); // Bottom-right: Mip 4
    }
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(hlsl, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(hlsl, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            // 128x128 procedural texture with full mip chain
            constexpr UINT TW = 128;
            std::vector<uint8_t> texels(TW * TW * 4);
            for (UINT y = 0; y < TW; ++y) {
                for (UINT x = 0; x < TW; ++x) {
                    const bool chk = ((x / 16) + (y / 16)) % 2 == 0;
                    const float fx = static_cast<float>(x) / 127.0f;
                    const float fy = static_cast<float>(y) / 127.0f;
                    const size_t i = (y * TW + x) * 4u;
                    texels[i + 0] = static_cast<uint8_t>(chk ? 235 : static_cast<int>(fx * 180));
                    texels[i + 1] = static_cast<uint8_t>(chk ? static_cast<int>(fy * 200) : 220);
                    texels[i + 2] = static_cast<uint8_t>(chk ? 40 : static_cast<int>((1.0f - fx) * 230));
                    texels[i + 3] = 255;
                }
            }
            D3D11_TEXTURE2D_DESC td{};
            td.Width = TW;
            td.Height = TW;
            td.MipLevels = 0;
            td.ArraySize = 1;
            td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            td.SampleDesc = {1, 0};
            td.Usage = D3D11_USAGE_DEFAULT;
            td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
            td.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
            ComPtr<ID3D11Texture2D> tex;
            ComPtr<ID3D11ShaderResourceView> srv;
            dev->CreateTexture2D(&td, nullptr, &tex);
            ctx->UpdateSubresource(tex.Get(), 0, nullptr, texels.data(), TW * 4u, 0);
            dev->CreateShaderResourceView(tex.Get(), nullptr, &srv);
            ctx->GenerateMips(srv.Get());

            D3D11_SAMPLER_DESC s0{};
            s0.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
            s0.AddressU = D3D11_TEXTURE_ADDRESS_WRAP;
            s0.AddressV = D3D11_TEXTURE_ADDRESS_WRAP;
            s0.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
            s0.MaxLOD = D3D11_FLOAT32_MAX;
            ComPtr<ID3D11SamplerState> samp_point;
            dev->CreateSamplerState(&s0, &samp_point);

            D3D11_SAMPLER_DESC s1 = s0;
            s1.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
            s1.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
            s1.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
            s1.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
            ComPtr<ID3D11SamplerState> samp_linear;
            dev->CreateSamplerState(&s1, &samp_linear);

            std::vector<VertexPosUV> verts;
            auto add_quad = [&](float x0, float y0, float x1, float y1, float u0, float v0, float u1, float v1) {
                verts.push_back({x0, y0, u0, v1});
                verts.push_back({x0, y1, u0, v0});
                verts.push_back({x1, y1, u1, v0});
                verts.push_back({x0, y0, u0, v1});
                verts.push_back({x1, y1, u1, v0});
                verts.push_back({x1, y0, u1, v1});
            };
            add_quad(-0.95f,  0.05f, -0.05f,  0.95f, 0.0f, 0.0f, 2.5f, 2.5f);
            add_quad( 0.05f,  0.05f,  0.95f,  0.95f, -0.25f, -0.25f, 1.25f, 1.25f);
            add_quad(-0.95f, -0.95f, -0.05f, -0.05f, 0.0f, 0.0f, 1.0f, 1.0f);
            add_quad( 0.05f, -0.95f,  0.95f, -0.05f, 0.0f, 0.0f, 1.0f, 1.0f);

            D3D11_BUFFER_DESC vbd{static_cast<UINT>(verts.size() * sizeof(VertexPosUV)), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA init{verts.data(), 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &init, &vb);

            ctx->ClearState();
            const float bg[4] = {0.05f, 0.05f, 0.07f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(VertexPosUV), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);
            ctx->PSSetShaderResources(0, 1, srv.GetAddressOf());
            ID3D11SamplerState* samps[2] = {samp_point.Get(), samp_linear.Get()};
            ctx->PSSetSamplers(0, 2, samps);
            ctx->Draw(static_cast<UINT>(verts.size()), 0);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "Point/Wrap, Linear/Clamp, GenerateMips LOD 2 & 4";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 7. d3d11_07_mrt_postprocess
    {
        dm::TestRecord rec;
        rec.name = "d3d11_07_mrt_postprocess";
        const double t0 = dm::now_ms();
        const char* hlsl_pass1 = R"(
struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};
struct PSOut {
    float4 rt0 : SV_Target0;
    float4 rt1 : SV_Target1;
};
PSIn VSMain(uint vid : SV_VertexID) {
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}
PSOut PSMain(PSIn input) {
    PSOut o;
    float2 d = input.uv - float2(0.5f, 0.5f);
    float r = length(d);
    float ring = smoothstep(0.36f, 0.34f, abs(r - 0.25f));
    o.rt0 = float4(input.uv.x, input.uv.y, 0.5f + 0.5f * ring, 1.0f);
    float vig = saturate(1.0f - r * 1.4f);
    o.rt1 = float4(vig, vig * 0.7f, 0.25f + 0.75f * vig, 1.0f);
    return o;
}
)";
        const char* hlsl_pass2 = R"(
Texture2D rt0 : register(t0);
Texture2D rt1 : register(t1);
SamplerState samp0 : register(s0);
struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};
PSIn VSMain(uint vid : SV_VertexID) {
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    float4 c = rt0.Sample(samp0, input.uv);
    float4 m = rt1.Sample(samp0, input.uv);
    return float4(c.rgb * (0.35f + 0.65f * m.rgb), 1.0f);
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs1, ps1, vs2, ps2;
        if (compile_hlsl(hlsl_pass1, "VSMain", "vs_5_0", vs1, err) &&
            compile_hlsl(hlsl_pass1, "PSMain", "ps_5_0", ps1, err) &&
            compile_hlsl(hlsl_pass2, "VSMain", "vs_5_0", vs2, err) &&
            compile_hlsl(hlsl_pass2, "PSMain", "ps_5_0", ps2, err)) {
            ComPtr<ID3D11VertexShader> vsh1, vsh2;
            ComPtr<ID3D11PixelShader> psh1, psh2;
            dev->CreateVertexShader(vs1->GetBufferPointer(), vs1->GetBufferSize(), nullptr, &vsh1);
            dev->CreatePixelShader(ps1->GetBufferPointer(), ps1->GetBufferSize(), nullptr, &psh1);
            dev->CreateVertexShader(vs2->GetBufferPointer(), vs2->GetBufferSize(), nullptr, &vsh2);
            dev->CreatePixelShader(ps2->GetBufferPointer(), ps2->GetBufferSize(), nullptr, &psh2);

            ComPtr<ID3D11Texture2D> t0_tex, t1_tex;
            ComPtr<ID3D11RenderTargetView> rtv0, rtv1;
            ComPtr<ID3D11ShaderResourceView> srv0, srv1;
            create_rgba_rtv(dev.Get(), kWidth, kHeight, D3D11_BIND_SHADER_RESOURCE, t0_tex, rtv0, &srv0);
            create_rgba_rtv(dev.Get(), kWidth, kHeight, D3D11_BIND_SHADER_RESOURCE, t1_tex, rtv1, &srv1);

            D3D11_SAMPLER_DESC sd{};
            sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
            sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.MaxLOD = D3D11_FLOAT32_MAX;
            ComPtr<ID3D11SamplerState> samp;
            dev->CreateSamplerState(&sd, &samp);

            ctx->ClearState();
            set_full_viewport(ctx.Get());
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

            // Pass 1: MRT
            ID3D11RenderTargetView* mrts[2] = {rtv0.Get(), rtv1.Get()};
            ctx->OMSetRenderTargets(2, mrts, nullptr);
            ctx->VSSetShader(vsh1.Get(), nullptr, 0);
            ctx->PSSetShader(psh1.Get(), nullptr, 0);
            ctx->Draw(3, 0);

            // Unbind MRTs before SRV composite
            ID3D11RenderTargetView* nulls[2] = {nullptr, nullptr};
            ctx->OMSetRenderTargets(2, nulls, nullptr);

            // Pass 2: Composite into main_rtv
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            ID3D11ShaderResourceView* srvs[2] = {srv0.Get(), srv1.Get()};
            ctx->PSSetShaderResources(0, 2, srvs);
            ctx->PSSetSamplers(0, 1, samp.GetAddressOf());
            ctx->VSSetShader(vsh2.Get(), nullptr, 0);
            ctx->PSSetShader(psh2.Get(), nullptr, 0);
            ctx->Draw(3, 0);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "2-target MRT + fullscreen SRV composite";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 8. d3d11_08_msaa_resolve
    {
        dm::TestRecord rec;
        rec.name = "d3d11_08_msaa_resolve";
        const double t0 = dm::now_ms();
        UINT qual = 0;
        dev->CheckMultisampleQualityLevels(DXGI_FORMAT_R8G8B8A8_UNORM, 4, &qual);
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (qual > 0 &&
            compile_hlsl(kCommonVSPS, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(kCommonVSPS, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            D3D11_TEXTURE2D_DESC md{};
            md.Width = kWidth;
            md.Height = kHeight;
            md.MipLevels = 1;
            md.ArraySize = 1;
            md.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            md.SampleDesc = {4, 0};
            md.Usage = D3D11_USAGE_DEFAULT;
            md.BindFlags = D3D11_BIND_RENDER_TARGET;
            ComPtr<ID3D11Texture2D> msaa_tex;
            ComPtr<ID3D11RenderTargetView> msaa_rtv;
            dev->CreateTexture2D(&md, nullptr, &msaa_tex);
            dev->CreateRenderTargetView(msaa_tex.Get(), nullptr, &msaa_rtv);

            std::vector<VertexPosColor> verts;
            constexpr int kSpokes = 16;
            for (int i = 0; i < kSpokes; ++i) {
                const float a0 = (2.0f * 3.14159265f * i) / kSpokes;
                const float a1 = a0 + 0.09f;
                const float r = (i % 2 == 0) ? 1.0f : 0.25f;
                const float g = (i % 3 == 0) ? 0.9f : 0.45f;
                const float b = (i % 2 == 1) ? 1.0f : 0.20f;
                verts.push_back({0.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f});
                verts.push_back({0.9f * std::cos(a0), 0.9f * std::sin(a0), 0.0f, r, g, b, 1.0f});
                verts.push_back({0.9f * std::cos(a1), 0.9f * std::sin(a1), 0.0f, r, g, b, 1.0f});
            }
            D3D11_BUFFER_DESC vbd{static_cast<UINT>(verts.size() * sizeof(VertexPosColor)), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA init{verts.data(), 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &init, &vb);

            D3D11_RASTERIZER_DESC rsd{};
            rsd.FillMode = D3D11_FILL_SOLID;
            rsd.CullMode = D3D11_CULL_NONE;
            rsd.MultisampleEnable = TRUE;
            ComPtr<ID3D11RasterizerState> rs_msaa;
            dev->CreateRasterizerState(&rsd, &rs_msaa);

            ctx->ClearState();
            const float bg[4] = {0.04f, 0.04f, 0.06f, 1.0f};
            ctx->ClearRenderTargetView(msaa_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, msaa_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->RSSetState(rs_msaa.Get());
            ctx->IASetInputLayout(layout.Get());
            UINT stride = sizeof(VertexPosColor), offset = 0;
            ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);
            ctx->Draw(static_cast<UINT>(verts.size()), 0);

            ctx->ResolveSubresource(main_tex.Get(), 0, msaa_tex.Get(), 0, DXGI_FORMAT_R8G8B8A8_UNORM);
            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "4x MSAA render + ResolveSubresource";
            }
        } else {
            rec.detail = qual == 0 ? "4x MSAA unsupported" : err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 9. d3d11_09_instancing
    {
        dm::TestRecord rec;
        rec.name = "d3d11_09_instancing";
        const double t0 = dm::now_ms();
        const char* hlsl = R"(
struct VSIn {
    float2 unit_pos : POSITION;
    float4 inst_rect : TEXCOORD0;
    float4 inst_col  : COLOR0;
    uint iid : SV_InstanceID;
};
struct PSIn {
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
};
PSIn VSMain(VSIn input) {
    PSIn o;
    float2 p = input.inst_rect.xy + input.unit_pos * input.inst_rect.zw;
    o.pos = float4(p, 0.0f, 1.0f);
    float boost = ((input.iid & 1u) == 0u) ? 1.0f : 0.78f;
    o.col = float4(input.inst_col.rgb * boost, 1.0f);
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return input.col;
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        if (compile_hlsl(hlsl, "VSMain", "vs_5_0", vs_blob, err) &&
            compile_hlsl(hlsl, "PSMain", "ps_5_0", ps_blob, err)) {
            ComPtr<ID3D11VertexShader> vs;
            ComPtr<ID3D11PixelShader> ps;
            dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
            dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

            const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
                {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
            };
            ComPtr<ID3D11InputLayout> layout;
            dev->CreateInputLayout(layout_desc, 3, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

            const float quad[8] = {-1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f, 1.0f, -1.0f};
            const uint16_t idx[6] = {0, 1, 2, 0, 2, 3};
            std::vector<InstanceData> inst(256);
            for (int y = 0; y < 16; ++y) {
                for (int x = 0; x < 16; ++x) {
                    auto& d = inst[y * 16 + x];
                    d.rect[0] = -0.88f + (x + 0.5f) * (1.76f / 16.0f);
                    d.rect[1] = -0.88f + (y + 0.5f) * (1.76f / 16.0f);
                    d.rect[2] = 0.043f;
                    d.rect[3] = 0.043f;
                    d.color[0] = static_cast<float>(x) / 15.0f;
                    d.color[1] = static_cast<float>(y) / 15.0f;
                    d.color[2] = 0.85f - 0.5f * static_cast<float>(x + y) / 30.0f;
                    d.color[3] = 1.0f;
                }
            }

            D3D11_BUFFER_DESC vbd{sizeof(quad), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA vinit{quad, 0, 0};
            ComPtr<ID3D11Buffer> vb;
            dev->CreateBuffer(&vbd, &vinit, &vb);

            D3D11_BUFFER_DESC ibd{sizeof(idx), D3D11_USAGE_DEFAULT, D3D11_BIND_INDEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA iinit{idx, 0, 0};
            ComPtr<ID3D11Buffer> ib;
            dev->CreateBuffer(&ibd, &iinit, &ib);

            D3D11_BUFFER_DESC sbd{static_cast<UINT>(inst.size() * sizeof(InstanceData)), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
            D3D11_SUBRESOURCE_DATA sinit{inst.data(), 0, 0};
            ComPtr<ID3D11Buffer> ibuf;
            dev->CreateBuffer(&sbd, &sinit, &ibuf);

            ctx->ClearState();
            const float bg[4] = {0.05f, 0.05f, 0.08f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), bg);
            ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), nullptr);
            set_full_viewport(ctx.Get());
            ctx->IASetInputLayout(layout.Get());
            ID3D11Buffer* vbs[2] = {vb.Get(), ibuf.Get()};
            UINT strides[2] = {sizeof(float) * 2, sizeof(InstanceData)};
            UINT offsets[2] = {0, 0};
            ctx->IASetVertexBuffers(0, 2, vbs, strides, offsets);
            ctx->IASetIndexBuffer(ib.Get(), DXGI_FORMAT_R16_UINT, 0);
            ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ctx->VSSetShader(vs.Get(), nullptr, 0);
            ctx->PSSetShader(ps.Get(), nullptr, 0);
            ctx->DrawIndexedInstanced(6, 256, 0, 0, 0);

            if (save_and_record(dev.Get(), ctx.Get(), main_tex.Get(), opts.out_dir, rec)) {
                rec.status = "pass";
                rec.detail = "256 instanced tiles via DrawIndexedInstanced";
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 10. d3d11_10_compute_uav
    {
        dm::TestRecord rec;
        rec.name = "d3d11_10_compute_uav";
        rec.has_compute_checksum = true;
        const double t0 = dm::now_ms();
        const char* hlsl_cs = R"(
RWTexture2D<float4> outTex : register(u0);
RWStructuredBuffer<uint> outHashes : register(u1);
groupshared uint tile_sum[64];

[numthreads(8, 8, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint gidx : SV_GroupIndex) {
    float x = (float)dtid.x / 512.0f;
    float y = (float)dtid.y / 512.0f;
    float wave = 0.5f + 0.5f * sin(x * 25.13274f) * cos(y * 25.13274f);
    float ring = 0.5f + 0.5f * sin(length(float2(x - 0.5f, y - 0.5f)) * 40.0f);
    outTex[dtid.xy] = float4(wave, ring, 0.5f * (x + y), 1.0f);

    uint h = (dtid.x * 73856093u) ^ (dtid.y * 19349663u) ^ 0x9E3779B9u;
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
        std::string err;
        ComPtr<ID3DBlob> cs_blob;
        if (compile_hlsl(hlsl_cs, "CSMain", "cs_5_0", cs_blob, err)) {
            ComPtr<ID3D11ComputeShader> cs;
            dev->CreateComputeShader(cs_blob->GetBufferPointer(), cs_blob->GetBufferSize(), nullptr, &cs);

            D3D11_TEXTURE2D_DESC td{};
            td.Width = kWidth;
            td.Height = kHeight;
            td.MipLevels = 1;
            td.ArraySize = 1;
            td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            td.SampleDesc = {1, 0};
            td.Usage = D3D11_USAGE_DEFAULT;
            td.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
            ComPtr<ID3D11Texture2D> uav_tex;
            ComPtr<ID3D11UnorderedAccessView> tex_uav;
            dev->CreateTexture2D(&td, nullptr, &uav_tex);
            dev->CreateUnorderedAccessView(uav_tex.Get(), nullptr, &tex_uav);

            constexpr UINT kGroups = 64u * 64u;
            D3D11_BUFFER_DESC bd{};
            bd.ByteWidth = kGroups * sizeof(uint32_t);
            bd.Usage = D3D11_USAGE_DEFAULT;
            bd.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
            bd.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
            bd.StructureByteStride = sizeof(uint32_t);
            ComPtr<ID3D11Buffer> uav_buf;
            ComPtr<ID3D11UnorderedAccessView> buf_uav;
            dev->CreateBuffer(&bd, nullptr, &uav_buf);

            D3D11_UNORDERED_ACCESS_VIEW_DESC udesc{};
            udesc.Format = DXGI_FORMAT_UNKNOWN;
            udesc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
            udesc.Buffer.NumElements = kGroups;
            dev->CreateUnorderedAccessView(uav_buf.Get(), &udesc, &buf_uav);

            D3D11_BUFFER_DESC sbd{};
            sbd.ByteWidth = bd.ByteWidth;
            sbd.Usage = D3D11_USAGE_STAGING;
            sbd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            ComPtr<ID3D11Buffer> staging_buf;
            dev->CreateBuffer(&sbd, nullptr, &staging_buf);

            ctx->ClearState();
            ctx->CSSetShader(cs.Get(), nullptr, 0);
            ID3D11UnorderedAccessView* uavs[2] = {tex_uav.Get(), buf_uav.Get()};
            ctx->CSSetUnorderedAccessViews(0, 2, uavs, nullptr);
            ctx->Dispatch(64, 64, 1);

            ID3D11UnorderedAccessView* nulls[2] = {nullptr, nullptr};
            ctx->CSSetUnorderedAccessViews(0, 2, nulls, nullptr);
            ctx->CopyResource(staging_buf.Get(), uav_buf.Get());

            D3D11_MAPPED_SUBRESOURCE mapped{};
            uint64_t gpu_sum = 0;
            if (SUCCEEDED(ctx->Map(staging_buf.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
                const uint32_t* p = static_cast<const uint32_t*>(mapped.pData);
                for (UINT i = 0; i < kGroups; ++i) {
                    gpu_sum += static_cast<uint64_t>(p[i]);
                }
                ctx->Unmap(staging_buf.Get(), 0);
            }

            uint64_t expected_sum = 0;
            for (uint32_t gy = 0; gy < 64; ++gy) {
                for (uint32_t gx = 0; gx < 64; ++gx) {
                    uint32_t acc = 0;
                    for (uint32_t ly = 0; ly < 8; ++ly) {
                        for (uint32_t lx = 0; lx < 8; ++lx) {
                            const uint32_t x = gx * 8u + lx;
                            const uint32_t y = gy * 8u + ly;
                            acc += (x * 73856093u) ^ (y * 19349663u) ^ 0x9E3779B9u;
                        }
                    }
                    expected_sum += static_cast<uint64_t>(acc);
                }
            }

            rec.compute_checksum = dm::hex64(gpu_sum);
            rec.expected_compute_checksum = dm::hex64(expected_sum);
            if (save_and_record(dev.Get(), ctx.Get(), uav_tex.Get(), opts.out_dir, rec)) {
                if (gpu_sum == expected_sum) {
                    rec.status = "pass";
                    rec.detail = "RWTexture2D + groupshared RWStructuredBuffer bit-exact";
                } else {
                    rec.status = "fail";
                    rec.detail = "Compute buffer checksum mismatch";
                }
            }
        } else {
            rec.detail = err;
        }
        rec.duration_ms = dm::now_ms() - t0;
        records.push_back(rec);
    }

    // 11. d3d11_bench_frame
    dm::BenchStats bench;
    {
        const char* hlsl_b = R"(
cbuffer FrameCB : register(b0) {
    float4 transform;
    float4 color;
};
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
    o.pos = float4(input.pos.xy * transform.zw + transform.xy, input.pos.z, 1.0f);
    o.col = input.col * color;
    return o;
}
float4 PSMain(PSIn input) : SV_Target {
    return input.col;
}
)";
        std::string err;
        ComPtr<ID3DBlob> vs_blob, ps_blob;
        compile_hlsl(hlsl_b, "VSMain", "vs_5_0", vs_blob, err);
        compile_hlsl(hlsl_b, "PSMain", "ps_5_0", ps_blob, err);
        ComPtr<ID3D11VertexShader> vs;
        ComPtr<ID3D11PixelShader> ps;
        dev->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &vs);
        dev->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nullptr, &ps);

        const D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
            {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
        };
        ComPtr<ID3D11InputLayout> layout;
        dev->CreateInputLayout(layout_desc, 2, vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &layout);

        const VertexPosColor verts[4] = {
            {-0.35f, -0.35f, 0.5f, 1.0f, 0.4f, 0.2f, 0.85f},
            {-0.35f,  0.35f, 0.4f, 0.3f, 1.0f, 0.4f, 0.85f},
            { 0.35f,  0.35f, 0.6f, 0.2f, 0.5f, 1.0f, 0.85f},
            { 0.35f, -0.35f, 0.3f, 0.9f, 0.8f, 0.2f, 0.85f},
        };
        const uint16_t idx[6] = {0, 1, 2, 0, 2, 3};
        D3D11_BUFFER_DESC vbd{sizeof(verts), D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
        D3D11_SUBRESOURCE_DATA vinit{verts, 0, 0};
        ComPtr<ID3D11Buffer> vb;
        dev->CreateBuffer(&vbd, &vinit, &vb);

        D3D11_BUFFER_DESC ibd{sizeof(idx), D3D11_USAGE_DEFAULT, D3D11_BIND_INDEX_BUFFER, 0, 0, 0};
        D3D11_SUBRESOURCE_DATA iinit{idx, 0, 0};
        ComPtr<ID3D11Buffer> ib;
        dev->CreateBuffer(&ibd, &iinit, &ib);

        D3D11_BUFFER_DESC cbd{sizeof(BenchCBuffer), D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
        ComPtr<ID3D11Buffer> cb;
        dev->CreateBuffer(&cbd, nullptr, &cb);

        D3D11_TEXTURE2D_DESC dtd{kWidth, kHeight, 1, 1, DXGI_FORMAT_D24_UNORM_S8_UINT, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_DEPTH_STENCIL, 0, 0};
        ComPtr<ID3D11Texture2D> ds_tex;
        ComPtr<ID3D11DepthStencilView> dsv;
        dev->CreateTexture2D(&dtd, nullptr, &ds_tex);
        dev->CreateDepthStencilView(ds_tex.Get(), nullptr, &dsv);

        D3D11_BLEND_DESC bdesc{};
        bdesc.RenderTarget[0].BlendEnable = TRUE;
        bdesc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
        bdesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
        bdesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
        bdesc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
        bdesc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
        bdesc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
        bdesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        ComPtr<ID3D11BlendState> bs;
        dev->CreateBlendState(&bdesc, &bs);

        D3D11_QUERY_DESC qd_event{D3D11_QUERY_EVENT, 0};
        ComPtr<ID3D11Query> q_event;
        dev->CreateQuery(&qd_event, &q_event);

        D3D11_QUERY_DESC qd_disjoint{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
        D3D11_QUERY_DESC qd_ts{D3D11_QUERY_TIMESTAMP, 0};
        ComPtr<ID3D11Query> q_disjoint, q_start, q_end;
        dev->CreateQuery(&qd_disjoint, &q_disjoint);
        dev->CreateQuery(&qd_ts, &q_start);
        dev->CreateQuery(&qd_ts, &q_end);

        ctx->ClearState();
        ctx->OMSetRenderTargets(1, main_rtv.GetAddressOf(), dsv.Get());
        ctx->OMSetBlendState(bs.Get(), nullptr, 0xFFFFFFFF);
        set_full_viewport(ctx.Get());
        ctx->IASetInputLayout(layout.Get());
        UINT stride = sizeof(VertexPosColor), offset = 0;
        ctx->IASetVertexBuffers(0, 1, vb.GetAddressOf(), &stride, &offset);
        ctx->IASetIndexBuffer(ib.Get(), DXGI_FORMAT_R16_UINT, 0);
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(vs.Get(), nullptr, 0);
        ctx->VSSetConstantBuffers(0, 1, cb.GetAddressOf());
        ctx->PSSetShader(ps.Get(), nullptr, 0);
        ctx->PSSetConstantBuffers(0, 1, cb.GetAddressOf());

        constexpr int kWarmup = 20;
        const int total_frames = kWarmup + opts.frames;
        std::vector<double> frame_times;
        frame_times.reserve(static_cast<size_t>(opts.frames));
        double gpu_ms_sum = 0.0;
        int gpu_ms_count = 0;

        for (int f = 0; f < total_frames; ++f) {
            const double ft0 = dm::now_ms();
            if (f >= kWarmup) {
                ctx->Begin(q_disjoint.Get());
                ctx->End(q_start.Get());
            }
            const float clear_bg[4] = {0.05f, 0.07f, 0.10f, 1.0f};
            ctx->ClearRenderTargetView(main_rtv.Get(), clear_bg);
            ctx->ClearDepthStencilView(dsv.Get(), D3D11_CLEAR_DEPTH, 1.0f, 0);

            for (int d = 0; d < 16; ++d) {
                D3D11_MAPPED_SUBRESOURCE m{};
                ctx->Map(cb.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &m);
                auto* p = static_cast<BenchCBuffer*>(m.pData);
                p->transform[0] = -0.6f + 0.08f * static_cast<float>(d);
                p->transform[1] = -0.4f + 0.05f * static_cast<float>((d + f) % 16);
                p->transform[2] = 0.7f;
                p->transform[3] = 0.7f;
                p->color[0] = 0.4f + 0.03f * static_cast<float>(d);
                p->color[1] = 0.8f;
                p->color[2] = 1.0f - 0.04f * static_cast<float>(d);
                p->color[3] = 0.75f;
                ctx->Unmap(cb.Get(), 0);
                ctx->DrawIndexed(6, 0, 0);
            }

            if (f >= kWarmup) {
                ctx->End(q_end.Get());
                ctx->End(q_disjoint.Get());
            }
            ctx->End(q_event.Get());
            ctx->Flush();
            BOOL done = FALSE;
            while (ctx->GetData(q_event.Get(), &done, sizeof(done), 0) == S_FALSE || !done) {
                Sleep(0);
            }
            const double ft1 = dm::now_ms();

            if (f >= kWarmup) {
                frame_times.push_back(ft1 - ft0);
                D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj{};
                UINT64 ts0 = 0, ts1 = 0;
                if (ctx->GetData(q_disjoint.Get(), &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                    !dj.Disjoint && dj.Frequency > 0 &&
                    ctx->GetData(q_start.Get(), &ts0, sizeof(ts0), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                    ctx->GetData(q_end.Get(), &ts1, sizeof(ts1), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                    ts1 >= ts0) {
                    gpu_ms_sum += (static_cast<double>(ts1 - ts0) * 1000.0) / static_cast<double>(dj.Frequency);
                    ++gpu_ms_count;
                }
            }
        }

        bench = dm::summarize_bench(frame_times, kWarmup);
        bench.gpu_mean_ms = gpu_ms_count > 0 ? (gpu_ms_sum / gpu_ms_count) : 0.0;
        bench.extra_metric_name = "dynamic_cb_updates_per_sec";
        bench.extra_ops_per_sec = bench.total_ms > 0.0
            ? (16.0 * static_cast<double>(bench.measured_frames)) / (bench.total_ms / 1000.0)
            : 0.0;
    }

    const std::string json_path = dm::join_path(opts.out_dir, "d3d11_results.json");
    if (!dm::write_results_json(json_path, "D3D11", fl_to_string(achieved), selected.meta, records, bench)) {
        std::cerr << "Failed to write " << json_path << "\n";
        return 1;
    }

    int pass_count = 0;
    for (const auto& r : records) {
        if (r.status == "pass") ++pass_count;
        std::cout << "  " << r.name << ": " << r.status
                  << " (checksum=" << r.pixel_checksum << ", " << r.duration_ms << " ms)\n";
    }
    std::cout << "[D3D11] Summary: " << pass_count << "/" << records.size()
              << " | Bench mean=" << bench.mean_ms << " ms (" << bench.fps
              << " FPS, 1%-low=" << bench.one_percent_low_fps << " FPS)\n";
    return pass_count == static_cast<int>(records.size()) ? 0 : 2;
}
