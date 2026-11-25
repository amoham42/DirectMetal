struct MatInfo
{
    uint texIdx;
    uint pad0;
    uint pad1;
    uint pad2;
    float4 tint;
    float4 uvScaleOff; // xy = scale, zw = offset
};

Texture2D<float4> gTextures[16]     : register(t0, space0);
StructuredBuffer<MatInfo> gMaterials : register(t0, space1);
SamplerState gLinearClamp            : register(s0);

struct VSIn
{
    float3 pos : POSITION;
    float2 uv  : TEXCOORD0;
};

struct PSIn
{
    float4 pos    : SV_POSITION;
    float2 uv     : TEXCOORD0;
    nointerpolation uint instId : TEXCOORD1;
};

PSIn VSMain(VSIn input, uint instId : SV_InstanceID)
{
    PSIn o;
    uint col = instId & 7u;
    uint row = instId >> 3;
    float2 center = float2(-0.84f + (float)col * 0.24f, -0.84f + (float)row * 0.24f);
    float2 p = center + input.pos.xy * 0.105f;
    o.pos = float4(p, 0.0f, 1.0f);
    o.uv = input.uv;
    o.instId = instId;
    return o;
}

float4 PSMain(PSIn input) : SV_Target
{
    MatInfo m = gMaterials[input.instId];
    uint texId = NonUniformResourceIndex(m.texIdx & 15u);
    float2 uv = input.uv * m.uvScaleOff.xy + m.uvScaleOff.zw;
    float4 texel = gTextures[texId].SampleLevel(gLinearClamp, uv, 0.0f);
    return float4(saturate(texel.rgb * m.tint.rgb), 1.0f);
}
