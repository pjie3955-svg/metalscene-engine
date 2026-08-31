#include "Common.h"

// GPU 视锥剔除 + 距离 LOD 选择 + ICB 命令编码,三步合一。
// 每个线程处理一个实例;可见实例通过原子计数器分配到 ICB 的连续 slot,
// 并从该 slot 直接发出 drawIndexedPrimitives —— CPU 不参与任何逐实例绘制决策。

inline bool frustumCull(float4 center, float radius,
                        constant float4* planes) {
    // 用 viewProjection 变换后的中心做 NDC 平面测试。planes 已由 CPU 按行分解好。
    for (uint i = 0; i < 6; i++) {
        float d = dot(planes[i].xyz, center.xyz) + planes[i].w;
        if (d < -radius) return true; // 在平面外,剔除
    }
    return false;
}

inline uint selectLOD(float dist, uint lodCount, float bias) {
    // 简单的距离阶梯:每翻倍距离降一档 LOD(真实项目可用屏幕投影面积更准)。
    float t = dist * bias;
    uint lod = uint(clamp(log2(max(t, 1.0)), 0.0, float(lodCount - 1)));
    return lod;
}

kernel void cullAndEncode(
    device const Instance*     instances   [[buffer(0)]],
    device const MeshLOD*      lods        [[buffer(1)]],
    device ICBContainer*       icbContainer [[buffer(2)]],
    device atomic_uint*        counter     [[buffer(3)]],
    device uint*               visibleList [[buffer(4)]],
    constant FrameUniforms&    fu          [[buffer(5)]],
    device const uint*         indexBuffer [[buffer(6)]], // 继承的索引缓冲(转发给 ICB)
    uint instanceIndex [[thread_position_in_grid]])
{
    if (instanceIndex >= fu.instanceCount) return;

    Instance inst = instances[instanceIndex];

    // 1) 视锥剔除
    if (frustumCull(inst.boundingSphere, inst.boundingSphere.w, fu.frustumPlanes))
        return;

    // 2) 距离选 LOD
    float dist = distance(fu.cameraPosition.xyz, inst.boundingSphere.xyz);
    uint lod = selectLOD(dist, inst.lodCount, fu.lodBias);
    MeshLOD m = lods[inst.firstLodIndex + lod];

    // 3) 分配 ICB slot 并编码绘制命令
    uint slot = atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
    visibleList[slot] = instanceIndex;

    render_command rc = icbContainer->commandBuffer[slot];
    rc.drawIndexedPrimitives(
        MTLPrimitiveTypeTriangle,
        m.indexCount,
        MTLIndexTypeUInt32,
        indexBuffer,
        m.indexOffset,
        1,              // instanceCount
        m.vertexOffset, // baseVertex
        slot);          // baseInstance -> 顶点着色器据此取回实例数据
}
