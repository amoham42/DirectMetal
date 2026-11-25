cbuffer GBufferCB : register(b0)
{
    float4 vpRow0;
    float4 vpRow1;
    float4 vpRow2;
    float4 vpRow3;
    float4 objPosScale;   // xyz = world offset, w = uniform scale
    float4 albedoMetal;   // rgb = base albedo, a = metallic
    float4 roughAOMat;    // x = roughness, y = ao, z = checkerFrequency, w = materialKind
};

struct VSIn
{
    float3 pos    : POSITION;
    float3 normal : NORMAL;
    float2 uv     : TEXCOORD0;
};

struct PSIn
{
    float4 svPos    : SV_POSITION;
    float3 worldPos : TEXCOORD0;
    float3 worldN   : TEXCOORD1;
    float2 uv       : TEXCOORD2;
};

struct PSOut
{
    float4 albedoMetal : SV_Target0;
    float4 normalRough : SV_Target1;
    float4 worldPosAO  : SV_Target2;
};

PSIn VSMain(VSIn input)
{
    PSIn o;
    float3 wp = input.pos * objPosScale.w + objPosScale.xyz;
    float4 p4 = float4(wp, 1.0f);
    o.svPos = float4(dot(vpRow0, p4), dot(vpRow1, p4), dot(vpRow2, p4), dot(vpRow3, p4));
    o.worldPos = wp;
    o.worldN = normalize(input.normal);
    o.uv = input.uv;
    return o;
}

PSOut PSMain(PSIn input)
{
    PSOut o;
    float3 albedo = albedoMetal.rgb;
    float metal = albedoMetal.a;
    float rough = roughAOMat.x;

    // Procedural floor checker pattern on materialKind >= 0.5
    if (roughAOMat.w > 0.5f) {
        float2 cell = floor(input.worldPos.xz * roughAOMat.z);
        float chk = fmod(abs(cell.x + cell.y), 2.0f);
        float3 c0 = albedo;
        float3 c1 = albedo * 0.35f + float3(0.06f, 0.08f, 0.11f);
        albedo = lerp(c0, c1, chk);
        rough = lerp(rough, saturate(rough + 0.30f), chk);
    }

    float3 n = normalize(input.worldN);
    o.albedoMetal = float4(saturate(albedo), saturate(metal));
    o.normalRough = float4(n, clamp(rough, 0.05f, 1.0f));
    o.worldPosAO  = float4(input.worldPos, saturate(roughAOMat.y));
    return o;
}
