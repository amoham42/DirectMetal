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
