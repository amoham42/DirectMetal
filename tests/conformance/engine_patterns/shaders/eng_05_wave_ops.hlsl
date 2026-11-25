cbuffer WaveConstants : register(b0)
{
    uint cSeed;
    uint cWidth;
    uint cHeight;
    uint cPad;
};

RWTexture2D<float4> gOutTex      : register(u0);
RWStructuredBuffer<uint> gGroupSums : register(u1);

groupshared uint sGroupSum;

[numthreads(32, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint gidx : SV_GroupIndex)
{
    if (gidx == 0u) {
        sGroupSum = 0u;
    }
    GroupMemoryBarrierWithGroupSync();

    uint code = ((dtid.x & 15u) + 1u) * ((dtid.y & 15u) + 1u) + ((cSeed ^ gid.x ^ gid.y) & 31u);
    uint wsum = WaveActiveSum(code);
    uint psum = WavePrefixSum(code);
    uint wxor = WaveActiveBitXor(code);

    if (WaveIsFirstLane()) {
        InterlockedAdd(sGroupSum, wsum);
    }
    GroupMemoryBarrierWithGroupSync();

    if (gidx == 0u) {
        uint groupIndex = gid.y * 16u + gid.x;
        gGroupSums[groupIndex] = sGroupSum;
    }

    if (dtid.x < cWidth && dtid.y < cHeight) {
        float r = saturate((float)(psum & 255u) / 255.0f);
        float g = saturate((float)(wsum & 4095u) / 4095.0f);
        float b = saturate((float)(wxor & 255u) / 255.0f);
        gOutTex[dtid.xy] = float4(r, g, b, 1.0f);
    }
}
