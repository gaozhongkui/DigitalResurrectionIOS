#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// ─────────────────────────────────────────────────────────────
// Geometry Modifier：根据深度贴图在 Z 轴方向位移顶点
//   params.textures().custom()      → 深度灰度图 (r 通道 = 归一化深度)
//   set_model_position_offset(...)  → 相对偏移，iOS 18 SDK 新 API
// ─────────────────────────────────────────────────────────────
[[visible]]
void depthGeometry(realitykit::geometry_parameters params)
{
    float2 uv = params.geometry().uv0();

    // 采样深度：r 通道返回 half，转 float，0=最远 1=最近
    float depth = float(params.textures().custom().sample(
        sampler(filter::linear, address::clamp_to_edge), uv
    ).r);

    // 施加 Z 轴相对偏移：近处凸起 / 远处凹陷
    float3 offset = float3(0.0, 0.0, (depth - 0.5) * 0.28);
    params.geometry().set_model_position_offset(offset);
}

// ─────────────────────────────────────────────────────────────
// Surface Shader：采样原始照片作为表面颜色，Unlit 不受光照影响
//   base_color().sample() 返回 half4，set_base_color 接受 half3
// ─────────────────────────────────────────────────────────────
[[visible]]
void depthSurface(realitykit::surface_parameters params)
{
    float2 uv = params.geometry().uv0();

    half4 color = params.textures().base_color().sample(
        sampler(filter::linear, address::clamp_to_edge), uv
    );

    params.surface().set_base_color(color.rgb);   // half3 ✓
    params.surface().set_opacity(half(1.0));
}
