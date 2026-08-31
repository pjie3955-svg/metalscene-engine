# Metal 3D 渲染方案设计 · macOS + iOS · 百万级(1M+)场景

> 角色:macOS Spatial/Metal Engineer
> 适用范围:Apple 硅(M1/M2/M3/M4 及 A 系列)· Xcode 15+ · target iOS 15 / macOS 12 起(ICB 与 AB Tier2 所需)

---

## 1. 目标与硬约束

| 维度 | 目标 |
|------|------|
| 渲染对象 | 3D 模型 / 场景(网格 + PBR 材质) |
| 目标平台 | macOS(桌面) + iOS / iPadOS(移动) |
| 数据规模 | 百万级实例 / 三角形,需稳定 60fps(iOS)/ 120fps(macOS ProMotion) |
| GPU 占用 | < 80%,保留散热余量 |
| 内存 | macOS 宽松(< 4GB 常驻);iOS / iPadOS 严格(< 1.5GB,盯 `recommendedMaxWorkingSetSize`) |

**核心矛盾**:1M+ 实例若由 CPU 逐个 `drawIndexedPrimitives`,光是命令编码就会把主线程吃满。
解决方案是 **GPU 驱动渲染(GPU-Driven Rendering)**:CPU 每帧只提交 **1 次计算 + 1 次 ICB 回放**,所有逐实例的可见性判定与绘制决策都交给 GPU。

---

## 2. 总体架构(见架构图)

每帧流程:

1. **CPU 调度**:更新相机/光源,写入当前帧的 `FrameUniforms`(三缓冲之一)。
2. **GPU 计算剔除**(`cullAndEncode`):对 1M 实例做视锥测试 + 距离 LOD 选择,可见实例经原子计数器分配到 `Indirect Command Buffer(ICB)` 的连续 slot,并直接 `drawIndexedPrimitives`。
3. **GPU 主渲染通道**:`executeCommandsInBuffer` 让 GPU 回放自己生成的绘制命令。材质通过 **Argument Buffer Tier2(Bindless)** 按 `materialID` 直接索引。
4. **后处理**:MetalFX 时间超分(动态分辨率救场)+ 色调映射,输出到 drawable。

无论场景 1k 还是 1M 实例,CPU 提交成本几乎恒定 —— 这是撑住百万级的关键。

---

## 3. 关键技术决策

### 3.1 Indirect Command Buffer(ICB)
- 用 `MTLIndirectCommandBuffer`(`commandTypes = .drawIndexed`,`inheritBuffers/ inheritPipelineState = true`)承载全部绘制命令。
- 计算核通过 `command_buffer` 容器类型把命令写进 ICB;渲染端只回放。
- 每帧先用 `commandBuffer.resetCommandsInBuffer(...)` 清空,再让计算核重写。

### 3.2 Argument Buffer Tier 2 —— Bindless
- 所有材质打包为 argument buffer,再以 `array<argument_buffer>` 顶层缓冲暴露,着色器按 `materialID` 直接索引,**彻底消除逐材质绑定爆炸**。
- 特性探测:`device.argumentBuffersSupport == .tier2`,否则拒绝启动。

### 3.3 资源堆(Heap)+ 稀疏分配
- 缓冲堆 / 纹理堆预分配(桌面 2GiB 缓冲 + 3GiB 纹理;iOS 512MiB + 1GiB),几何体与贴图从堆内子分配,避免运行时频繁分配。
- `type = .sparse` 允许别名,进一步省显存。

### 3.4 GPU 视锥剔除 + 距离 LOD
- 视锥 6 平面由 CPU 从 `viewProjection` 分解后传入 `FrameUniforms`。
- LOD 当前按距离阶梯选取(后续可改为屏幕投影面积更稳)。
- 进阶:接入 **Hi-Z 遮挡剔除**(将上一帧深度降采样成层级 Z 缓冲,在计算核内做遮挡测试),可再砍掉大量被遮挡绘制。

### 3.5 三缓冲(Triple Buffering)
- `FrameUniforms` 与剔除输出各维护 3 套缓冲,CPU 写第 N 帧时 GPU 在读第 N-1 帧,消除管线停顿。

### 3.6 MetalFX 时间超分(动态分辨率)
- iOS 升温时(`ProcessInfo.ThermalState`)主动把内部分辨率降到 0.7~0.85×,再用 `MetalFXTemporalUpscaler` 超分回 drawable 尺寸,**保帧率优先于保清晰度**。
- `Platform.dynamicResolutionScale(...)` 给出平台相关的缩放系数。

### 3.7 统一纹理格式 ASTC
- 桌面与移动统一使用 ASTC(Apple 硅均支持),一份资源两平台通用,省去 BC/ASTC 双份管线。

---

## 4. 跨平台策略

- **单代码库**:用 SPM 包 + `#if os(macOS)` / `#if os(iOS)` 隔离平台差异:
  - MTKView 在双平台 API 一致,可共享视图与渲染循环代码;
  - 输入:桌面用鼠标/触控板轨道相机,iOS 用多点触控;
  - 散热:`thermalState` 仅 iOS 有,桌面忽略。
- **特性探测先行**:`Platform.detect(device:)` 在启动时一次性收集能力集,运行中只读,缺失关键特性(ICB / AB Tier2)直接拒绝运行并给出明确原因。
- **内存预算**:以 `recommendedMaxWorkingSetSize` 为上限做堆大小自适应,避免 iOS 后台被杀。

---

## 5. 性能目标与剖测

- 目标:1M+ 可见三角形,**GPU 帧时间 < 16.6ms(iOS)/ < 8.3ms(macOS 120Hz)**。
- 用 **Instruments → Metal System Trace** 看帧时间分布;**GPU Counters** 看 ALU / 带宽 / 纹素比。
- 优化抓手:减少 overdraw(early-Z)、合并绘制(ICB 已天然合并)、动态 LOD、纹理 mip + ASTC、**变量速率着色(VRS)** 用于注视点周边降采样(仅桌面 Apple GPU 支持)。

---

## 6. 工程结构与构建

```
Sources/
  Core/
    CrossPlatform.swift   # 平台/能力探测、ASTC、动态分辨率
    Renderer.swift        # GPU 驱动主渲染器(三缓冲 + 每帧调度)
  Scene/
    SceneTypes.swift      # Instance / MeshLOD / FrameUniforms 结构(与 Metal 对齐)
    ResourceManager.swift # 资源堆 + 材质 Argument Buffer(Tier2)
  Shaders/
    Common.h              # 跨语言共享结构体(Instance/MeshLOD/Materials/ICBContainer)
    Culling.metal         # 计算剔除 + ICB 命令编码
    Shading.metal         # 顶点/片元(Bindless PBR 基础光照)
project.yml               # xcodegen 跨平台工程(见下)
```

构建:安装 `xcodegen` 后执行 `xcodegen generate --spec project.yml`,产物为同时支持 iOS / macOS 的 framework + Demo App。

---

## 7. 风险与后续

1. **材质表绑定**:`ResourceManager.materialTableBuffer` 当前为占位,需构建真正的 `array<argument_buffer>` 顶层 argument buffer(用 `MTLArgumentDescriptor` + `arrayLength`)并正确绑定到片元 `buffer(1)`。
2. **结构体内存对齐**:接入真实数据前,用 `MemoryLayout<FrameUniforms>.stride/offset` 与 Metal 侧 `sizeof` 逐字段校验(已按 16 字节对齐排布,但仍建议验证)。
3. **遮挡剔除**:当前仅有视锥剔除,建议补 Hi-Z 遮挡剔除进一步降负载。
4. **阴影 / IBL**:文档着色器为简化基础光照,生产环境接入方向光阴影贴图 + 基于图像的照明(PBR)。
5. **几何加载器**:`geometryVertexBuffer` / `geometryIndexBuffer` 由 glTF / USD 加载器填充,本方案未含解析逻辑。
6. **真机验证**:本方案为设计稿,需在 Apple 硅真机 + Xcode 编译验证;Windows 环境无法编译运行 Metal。

---

## 8. 部署硬件要求与 Intel Mac 兼容性(重要)

本方案是围绕 **Apple 硅(Apple Silicon)** 能力设计的,GPU 驱动管线的多个核心特性在 Intel Mac 上**不可用**:

| 依赖特性 | Intel Mac(如 2018 Mac mini) | 说明 |
|----------|------------------------------|------|
| **MetalFX 时间/空间超分** | ❌ 不支持 | 仅 Apple 硅 Mac 可用(macOS 13+ 但限 Apple GPU)。Intel 上 `MTLFXTemporalScaler` 不可用,需改用「降低内部分辨率 + MPS 上采样」兜底。 |
| **ASTC 纹理压缩** | ❌ 不支持 | ASTC 仅 Apple GPU / iOS 支持。Intel / AMD Mac GPU 用 **BC(BC1–BC7)** 格式,「单一 ASTC 资源两平台通用」不成立,需按平台出 BC / ASTC 两套,或用 KTX2 / Basis 转码。 |
| **计算核编码 ICB(GPU 驱动核心)** | ⚠️ 视 GPU 而定 | `command_buffer` 容器 / 计算核内 `render_command` 需 **macOS_GPUFamily2_v1**。2018 Mac mini 的 **Intel UHD 630 核显不支持 GPUFamily2**;仅选配的 **AMD Radeon Pro 555X/560X 独显**支持。绝大多数基础机型只有核显 → 此路径不可用。 |
| 基础 ICB(CPU 编码) / 普通 Metal | ✅ 支持 | 可跑简单场景与教学示例,但撑不住 1M+ GPU 驱动管线。 |

**结论**:2018 Intel Mac mini **不能作为本方案的部署目标**,也基本无法运行完整 GPU 驱动百万级管线(尤其核显机型)。其价值仅在于:
- 作为**开发与学习机**:装 Xcode、编译运行简化版 Metal 示例、熟悉 API;
- 跑**降规模 / CPU 辅助剔除**的版本(性能远达不到 1M+/60fps 目标)。

**推荐部署硬件**:Apple 硅 Mac(目标 M2 / M4 Mac mini 或 MacBook),**统一内存 32GB 起**。统一内存的高带宽是 GPU 驱动渲染在 1M+ 规模下的决定性优势;16GB 对 1M+ 场景偏紧,建议 32GB+。磁盘 1TB 无压力。

**自检命令**(确认本机 GPU 与特性集):
```bash
system_profiler SPDisplaysDataType        # 看是否仅有 Intel UHD 630(无 AMD 即缺 GPUFamily2)
# 在 App 内用 device.supportsFeatureSet(.macOS_GPUFamily2_v1) 判定计算核 ICB 是否可用
```
