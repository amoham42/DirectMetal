struct Candidate
{
    float4 rect;   // cx, cy, halfSize, activeHint
    float4 color;  // rgba
};

struct DrawArgs
{
    uint VertexCountPerInstance;
    uint InstanceCount;
    uint StartVertexLocation;
    uint StartInstanceLocation;
};

cbuffer CullCB : register(b0)
{
    float4 frustumParams; // x = diamondRadius, y = circleRadius, z = unused, w = unused
    uint numCandidates;
    uint3 pad0;
};

StructuredBuffer<Candidate> gCandidates : register(t0);
RWStructuredBuffer<DrawArgs> gOutArgs   : register(u0);
RWStructuredBuffer<uint> gCounters      : register(u1); // [0]=drawCount, [1]=orderIndependentHash

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID)
{
    uint idx = dtid.x;
    if (idx >= numCandidates) return;

    Candidate c = gCandidates[idx];
    float2 p = c.rect.xy;
    bool inDiamond = (abs(p.x) + abs(p.y)) <= frustumParams.x;
    bool inCircle  = length(p) <= frustumParams.y;
    if (inDiamond || inCircle) {
        uint slot = 0u;
        InterlockedAdd(gCounters[0], 1u, slot);
        DrawArgs da;
        da.VertexCountPerInstance = 6u;
        da.InstanceCount = 1u;
        da.StartVertexLocation = idx * 6u;
        da.StartInstanceLocation = 0u;
        gOutArgs[slot] = da;

        uint contrib = (idx + 1u) * 2654435761u;
        InterlockedAdd(gCounters[1], contrib);
    }
}
