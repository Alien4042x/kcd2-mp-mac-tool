#pragma once
constexpr char page_shader_source[] = R"(
struct Output { float4 position : SV_POSITION; float2 uv : TEXCOORD0; };
Output vs_main(uint id : SV_VertexID) {
    Output o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.uv = uv;
    o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}
Texture2D page : register(t0);
SamplerState linear_clamp : register(s0);
float4 ps_main(Output i) : SV_TARGET { return page.Sample(linear_clamp, i.uv); }
)";
