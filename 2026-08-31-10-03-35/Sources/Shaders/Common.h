#ifndef COMMON_H
#define COMMON_H
#include <metal_stdlib>
using namespace metal;

// 与 Swift 侧 SceneTypes.swift / FrameUniforms 严格对应的 GPU 布局。
// 注意:跨语言结构体内存对齐必须一致,接入时用 MemoryLayout.stride / offset 校验。

#define MAX_INSTANCES 1048576
#define MAX_MATERIALS 1024

struct Instance {
    float4x4 modelMatrix;
    float4   boundingSphere;   // xyz=中心, w=半径(世界空间)
    uint     materialID;
    uint     lodCount;
    uint     firstLodIndex;    // 指向 MeshLOD 数组起点
    uint     pad;
};

struct MeshLOD {
    uint indexCount;
    uint indexOffset;          // 共享索引缓冲中的字节偏移
    uint vertexOffset;         // 共享顶点缓冲中的顶点偏移
    uint argumentBufferIndex;
};

struct FrameUniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 viewProjectionMatrix;
    float4   cameraPosition;
    float4   frustumPlanes[6];
    float    lodBias;
    uint     instanceCount;
    float4   pad;              // 对齐到 16 字节
};

struct MaterialConstants {
    float4  baseColor;
    float   metallic;
    float   roughness;
    float   pad0;
    float   pad1;
};

// Bindless 顶层参数缓冲:材质以 argument_buffer 数组形式索引。
// 由 ResourceManager 在 CPU 侧用 array<argument_buffer> 编码。
struct MaterialAB {
    texture2d<float> albedo;
    texture2d<float> normalMap;
    texture2d<float> metallicRoughness;
    constant MaterialConstants& constants;
};
struct Materials {
    array<MaterialAB, MAX_MATERIALS> list;
};

struct VertexIn {
    float3 position  [[attribute(0)]];
    float3 normal    [[attribute(1)]];
    float2 texCoord  [[attribute(2)]];
};

struct VertexOut {
    float4  clipPos    [[position]];
    float3  worldNormal;
    float2  texCoord;
    uint    materialID;
};

// 计算核用来向 ICB 写入绘制命令的容器类型(数组大小须为编译期常量)。
struct ICBContainer {
    command_buffer commandBuffer [[count(MAX_INSTANCES)]];
};

#endif
