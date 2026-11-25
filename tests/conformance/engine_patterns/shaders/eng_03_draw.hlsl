struct VSIn
{
    float3 pos : POSITION;
    float4 col : COLOR0;
};

struct PSIn
{
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
};

PSIn VSMain(VSIn input)
{
    PSIn o;
    o.pos = float4(input.pos, 1.0f);
    o.col = input.col;
    return o;
}

float4 PSMain(PSIn input) : SV_Target
{
    return input.col;
}
