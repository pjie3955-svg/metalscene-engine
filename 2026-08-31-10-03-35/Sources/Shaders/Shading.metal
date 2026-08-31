#include "Common.h"

// 主顶点着色:从 ICB 的 baseInstance 取回可见实例下标,
// 再索引实例缓冲得到模型矩阵与材质 ID。几何属性由渲染编码器继承的缓冲提供。
vertex VertexOut vertex_main(
    VertexIn in [[stage_in]],
    constant FrameUniforms& fu [[buffer(0)]],
    device const Instance* instances [[buffer(1)]],
    device const uint* visibleList [[buffer(2)]],
    uint instanceID [[instance_id]])
{
    uint instanceIndex = visibleList[instanceID];
    Instance inst = instances[instanceIndex];

    float4 world = inst.modelMatrix * float4(in.position, 1.0);
    VertexOut out;
    out.clipPos     = fu.viewProjectionMatrix * world;
    out.worldNormal = (inst.modelMatrix * float4(in.normal, 0.0)).xyz;
    out.texCoord    = in.texCoord;
    out.materialID  = inst.materialID;
    return out;
}

// 主片元着色:Bindless 取材质。materials 是 argument_buffer 数组,直接按 materialID 索引。
fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    constant Materials& materials [[buffer(1)]])
{
    MaterialAB m = materials.list[in.materialID];

    constexpr sampler s(filter::linear, mip_filter::linear, addressing::repeat);
    float4 albedo = m.albedo.sample(s, in.texCoord);
    float3 n = normalize(m.normalMap.sample(s, in.texCoord).xyz * 2.0 - 1.0);
    float2 mr = m.metallicRoughness.sample(s, in.texCoord).rg;
    float3 base = albedo.rgb * m.constants.baseColor.rgb;

    // 简化基础光照(完整 PBR / IBL 在扩展中接入)。
    float3 L = normalize(float3(0.5, 0.85, 0.35));
    float lambert = max(dot(normalize(n), L), 0.0);
    float ambient = mix(0.25, 0.08, mr.g); // 粗糙度越高环境项越平
    float3 color = base * (ambient + 0.85 * lambert)
                 + base * mr.r * 0.1;       // 金属度提供一点高光感
    return float4(color, 1.0);
}
