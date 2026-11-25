Texture2D<float4> gAlbedoMetal : register(t0);
Texture2D<float4> gNormalRough : register(t1);
Texture2D<float4> gWorldPosAO  : register(t2);
SamplerState gClampSamp        : register(s0);

cbuffer DeferredLightCB : register(b0)
{
    float4 camPosExposure;   // xyz = camera world pos, w = exposure
    float4 keyDir;           // xyz = normalized dir TOWARD light
    float4 keyColor;         // rgb * intensity
    float4 pt0PosRadius;     // xyz = pos, w = radius
    float4 pt0Color;         // rgb * intensity
    float4 pt1PosRadius;     // xyz = pos, w = radius
    float4 pt1Color;         // rgb * intensity
};

struct PSIn
{
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

static const float kPi = 3.14159265f;

float DistGGX(float NdotH, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    return a2 / max(kPi * d * d, 1e-5f);
}

float GeomSchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0f;
    float k = (r * r) / 8.0f;
    return NdotV / max(NdotV * (1.0f - k) + k, 1e-5f);
}

float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0f - F0) * pow(saturate(1.0f - cosTheta), 5.0f);
}

float3 EvalBRDF(float3 N, float3 V, float3 L, float3 albedo, float metallic, float roughness, float3 radiance)
{
    float NdotL = max(dot(N, L), 0.0f);
    if (NdotL <= 0.0f) return float3(0.0f, 0.0f, 0.0f);

    float NdotV = max(dot(N, V), 1e-4f);
    float3 H = normalize(V + L);
    float NdotH = max(dot(N, H), 0.0f);
    float HdotV = max(dot(H, V), 0.0f);

    float3 F0 = lerp(float3(0.04f, 0.04f, 0.04f), albedo, metallic);
    float D = DistGGX(NdotH, roughness);
    float G = GeomSchlickGGX(NdotV, roughness) * GeomSchlickGGX(NdotL, roughness);
    float3 F = FresnelSchlick(HdotV, F0);

    float3 spec = (D * G * F) / max(4.0f * NdotV * NdotL, 1e-4f);
    float3 kD = (1.0f - F) * (1.0f - metallic);
    float3 diff = kD * albedo / kPi;
    return (diff + spec) * radiance * NdotL;
}

float3 ACESFilm(float3 x)
{
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

PSIn VSMain(uint vid : SV_VertexID)
{
    PSIn o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    o.uv = p;
    return o;
}

float4 PSMain(PSIn input) : SV_Target
{
    float4 gb0 = gAlbedoMetal.SampleLevel(gClampSamp, input.uv, 0.0f);
    float4 gb1 = gNormalRough.SampleLevel(gClampSamp, input.uv, 0.0f);
    float4 gb2 = gWorldPosAO.SampleLevel(gClampSamp, input.uv, 0.0f);

    if (gb2.a < 0.01f) {
        // Sky gradient background
        float t = saturate(1.0f - input.uv.y);
        float3 sky = lerp(float3(0.08f, 0.11f, 0.17f), float3(0.02f, 0.03f, 0.06f), t);
        return float4(sky, 1.0f);
    }

    float3 albedo = gb0.rgb;
    float metallic = gb0.a;
    float3 N = normalize(gb1.xyz);
    float roughness = clamp(gb1.a, 0.05f, 1.0f);
    float3 worldPos = gb2.xyz;
    float ao = gb2.a;

    float3 V = normalize(camPosExposure.xyz - worldPos);
    float3 Lo = EvalBRDF(N, V, normalize(keyDir.xyz), albedo, metallic, roughness, keyColor.rgb);

    // Point light 0
    {
        float3 d0 = pt0PosRadius.xyz - worldPos;
        float dist = length(d0);
        float att = pow(saturate(1.0f - dist / pt0PosRadius.w), 2.0f);
        Lo += EvalBRDF(N, V, d0 / max(dist, 1e-4f), albedo, metallic, roughness, pt0Color.rgb * att);
    }
    // Point light 1
    {
        float3 d1 = pt1PosRadius.xyz - worldPos;
        float dist = length(d1);
        float att = pow(saturate(1.0f - dist / pt1PosRadius.w), 2.0f);
        Lo += EvalBRDF(N, V, d1 / max(dist, 1e-4f), albedo, metallic, roughness, pt1Color.rgb * att);
    }

    float3 hemi = lerp(float3(0.04f, 0.045f, 0.06f), float3(0.11f, 0.15f, 0.22f), 0.5f * N.y + 0.5f);
    float3 color = (hemi * albedo * ao) + Lo;
    color *= camPosExposure.w;
    color = ACESFilm(color);
    color = pow(color, float3(1.0f / 2.2f, 1.0f / 2.2f, 1.0f / 2.2f));
    return float4(color, 1.0f);
}
