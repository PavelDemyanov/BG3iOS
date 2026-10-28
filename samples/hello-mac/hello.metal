// Треугольник, вращается по углу из буфера 0.
#include <metal_stdlib>
using namespace metal;

struct Out {
    float4 position [[position]];
    float3 color;
};

vertex Out vs(uint id [[vertex_id]], constant float &angle [[buffer(0)]])
{
    float a = angle + id * 2.0944;
    Out out;
    out.position = float4(0.6 * cos(a), 0.6 * sin(a), 0, 1);
    out.color = float3(id == 0, id == 1, id == 2);
    return out;
}

fragment float4 fs(Out in [[stage_in]]) { return float4(in.color, 1); }
