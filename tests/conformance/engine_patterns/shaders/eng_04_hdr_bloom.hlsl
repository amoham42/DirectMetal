Texture2D<float4> gSrcTex   : register(t0);
Texture2D<float4> gBloomTex : register(t1);
SamplerState gLinearClamp   : register(s0);
RWTexture2D<float4> gOutUAV : register(u0);

struct PSIn
{
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

PSIn VSHDR(uint vid : SV_VertexID)
{
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}

float4 PSHDR(PSIn input) : SV_Target
{
    float2 p = input.uv * 2.0f - 1.0f;
    float d0 = length(p - float2(-0.38f, -0.15f));
    float d1 = length(p - float2( 0.40f,  0.18f));
    float d2 = abs(p.y + 0.55f - 0.10f * sin(p.x * 7.0f));

    // HDR values strictly above 1.0 to drive real bloom separation
    float3 hdr = float3(0.03f, 0.04f, 0.07f);
    hdr += float3(7.5f, 2.2f, 0.4f) * smoothstep(0.22f, 0.05f, d0);
    hdr += float3(0.4f, 3.8f, 8.2f) * smoothstep(0.18f, 0.04f, d1);
    hdr += float3(1.8f, 6.0f, 3.2f) * smoothstep(0.035f, 0.008f, d2);

    // Subtle dark metallic floor stripes
    float2 tile = floor((input.uv + 0.01f) * 16.0f);
    float chk = fmod(tile.x + tile.y, 2.0f);
    hdr += float3(0.05f, 0.07f, 0.11f) * (0.3f + 0.7f * chk);
    return float4(hdr, 1.0f);
}

static const float kGauss[5] = { 0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f };

[numthreads(8, 8, 1)]
void CSBrightBlurH(uint3 dtid : SV_DispatchThreadID)
{
    if (dtid.x >= 512u || dtid.y >= 512u) return;
    int2 coord = int2(dtid.xy);
    float3 acc = float3(0.0f, 0.0f, 0.0f);
    [unroll]
    for (int i = -4; i <= 4; ++i) {
        int sx = clamp(coord.x + i * 3, 0, 511);
        float3 c = gSrcTex.Load(int3(sx, coord.y, 0)).rgb;
        float lum = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        float3 bright = max(c - float3(1.1f, 1.1f, 1.1f), float3(0.0f, 0.0f, 0.0f)) * saturate(lum - 0.8f);
        acc += bright * kGauss[abs(i)];
    }
    gOutUAV[coord] = float4(acc, 1.0f);
}

[numthreads(8, 8, 1)]
void CSBlurV(uint3 dtid : SV_DispatchThreadID)
{
    if (dtid.x >= 512u || dtid.y >= 512u) return;
    int2 coord = int2(dtid.xy);
    float3 acc = float3(0.0f, 0.0f, 0.0f);
    [unroll]
    for (int i = -4; i <= 4; ++i) {
        int sy = clamp(coord.y + i * 3, 0, 511);
        float3 c = gSrcTex.Load(int3(coord.x, sy, 0)).rgb;
        acc += c * kGauss[abs(i)];
    }
    gOutUAV[coord] = float4(acc, 1.0f);
}

PSIn VSTonemap(uint vid : SV_VertexID)
{
    return VSHDR(vid);
}

float4 PSTonemap(PSIn input) : SV_Target
{
    float3 hdr = gSrcTex.SampleLevel(gLinearClamp, input.uv, 0.0f).rgb;
    float3 bloom = gBloomTex.SampleLevel(gLinearClamp, input.uv, 0.0f).rgb;
    float3 combined = hdr + bloom * 0.55f;
    float3 aces = saturate((combined * (2.51f * combined + 0.03f)) / (combined * (2.43f * combined + 0.59f) + 0.14f));
    float3 ldr = pow(aces, float3(1.0f / 2.2f, 1.0f / 2.2f, 1.0f / 2.2f));
    return float4(ldr, 1.0f);
}
