Texture2D<float> gShadowMap    : register(t0);
SamplerComparisonState gShadowCmp : register(s0);

cbuffer ShadowCB : register(b0)
{
    float4 camRow0;
    float4 camRow1;
    float4 camRow2;
    float4 camRow3;
    float4 lightRow0;
    float4 lightRow1;
    float4 lightRow2;
    float4 lightRow3;
    float4 objPosScale;   // xyz offset, w scale
    float4 baseColor;     // rgb color, a checkerEnable
    float4 sunDirTexel;   // xyz normalized sun dir, w = 1.0 / shadowMapSize
};

struct VSIn
{
    float3 pos    : POSITION;
    float3 normal : NORMAL;
    float2 uv     : TEXCOORD0;
};

struct PSIn
{
    float4 svPos     : SV_POSITION;
    float4 lightClip : TEXCOORD0;
    float3 worldPos  : TEXCOORD1;
    float3 worldN    : TEXCOORD2;
};

float4 VSDepth(VSIn input) : SV_POSITION
{
    float3 wp = input.pos * objPosScale.w + objPosScale.xyz;
    float4 p4 = float4(wp, 1.0f);
    return float4(dot(lightRow0, p4), dot(lightRow1, p4), dot(lightRow2, p4), dot(lightRow3, p4));
}

PSIn VSMain(VSIn input)
{
    PSIn o;
    float3 wp = input.pos * objPosScale.w + objPosScale.xyz;
    float4 p4 = float4(wp, 1.0f);
    o.svPos     = float4(dot(camRow0, p4),   dot(camRow1, p4),   dot(camRow2, p4),   dot(camRow3, p4));
    o.lightClip = float4(dot(lightRow0, p4), dot(lightRow1, p4), dot(lightRow2, p4), dot(lightRow3, p4));
    o.worldPos = wp;
    o.worldN = normalize(input.normal);
    return o;
}

float4 PSMain(PSIn input) : SV_Target
{
    float3 N = normalize(input.worldN);
    float3 L = normalize(sunDirTexel.xyz);
    float NdotL = max(dot(N, L), 0.0f);

    float3 proj = input.lightClip.xyz / max(input.lightClip.w, 1e-5f);
    float2 suv = float2(proj.x * 0.5f + 0.5f, -proj.y * 0.5f + 0.5f);
    float bias = 0.0025f + 0.0040f * (1.0f - NdotL);
    float cmpDepth = proj.z - bias;

    float shadow = 1.0f;
    if (suv.x > 0.01f && suv.x < 0.99f && suv.y > 0.01f && suv.y < 0.99f && proj.z > 0.0f && proj.z < 1.0f) {
        float acc = 0.0f;
        float texel = sunDirTexel.w;
        [unroll]
        for (int dy = -1; dy <= 1; ++dy) {
            [unroll]
            for (int dx = -1; dx <= 1; ++dx) {
                acc += gShadowMap.SampleCmpLevelZero(gShadowCmp, suv + float2((float)dx, (float)dy) * texel, cmpDepth);
            }
        }
        shadow = acc / 9.0f;
    }

    float3 col = baseColor.rgb;
    if (baseColor.a > 0.5f) {
        float2 grid = floor(input.worldPos.xz * 2.0f);
        float chk = fmod(abs(grid.x + grid.y), 2.0f);
        col = lerp(col, col * 0.72f, chk);
    }

    float3 ambient = float3(0.11f, 0.14f, 0.21f) * col;
    float3 direct = float3(1.05f, 0.96f, 0.84f) * col * NdotL * shadow;
    float3 outRgb = pow(saturate(ambient + direct), float3(1.0f / 2.2f, 1.0f / 2.2f, 1.0f / 2.2f));
    return float4(outRgb, 1.0f);
}
