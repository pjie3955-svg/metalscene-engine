import Foundation
import Metal

/// 单个可绘制实例在 GPU 端的紧凑布局,固定 96 字节。
/// 实例总数可达 1M+,因此结构体内存布局与 Shaders/Common.h 的 Instance 严格对应,改动需同步。
/// 字段顺序已按 16 字节对齐排布,与 Metal 侧零填充偏差。
struct Instance {
    var modelMatrix: float4x4   // 64B -> 拆成列存储见下;为对齐此处用 4 个 float4
    var boundingSphere: SIMD4<Float> // xyz = 中心, w = 半径
    var materialID: UInt32
    var lodCount: UInt32
    var firstLodIndex: UInt32   // 指向 MeshLOD 数组的起始下标
    var pad: UInt32
}

/// 一个网格的某一 LOD 级别,描述其索引范围与所属参数缓冲槽位。
/// 所有 LOD 平铺进一个数组,Instance.firstLodIndex 指向其起点。
struct MeshLOD {
    var indexCount: UInt32
    var indexOffset: UInt32     // 在共享索引缓冲中的字节偏移
    var vertexOffset: UInt32    // 在共享顶点缓冲中的顶点偏移
    var argumentBufferIndex: UInt32 // 对应 Bindless 参数缓冲槽
}

/// 全局帧 Uniform。每帧由 CPU 写入,三缓冲轮换避免 GPU 读取时 CPU 改写。
struct FrameUniforms {
    var viewMatrix: float4x4
    var projectionMatrix: float4x4
    var viewProjectionMatrix: float4x4
    var cameraPosition: SIMD4<Float>
    var frustumPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var lodBias: Float
    var instanceCount: UInt32
    var pad: SIMD3<Float>
}

/// 场景:持有全部实例与 LOD 描述,负责向 GPU 缓冲上载。
/// 真实项目中网格几何从 glTF / USD 加载后并入共享缓冲。
final class Scene {

    /// 全部实例(CPU 侧权威数据)。容量按 1M+ 设计。
    private(set) var instances: [Instance] = []
    private(set) var lods: [MeshLOD] = []

    /// 预分配的 GPU 实例缓冲,容量固定以避免逐帧分配。
    let instanceBuffer: MTLBuffer
    let lodBuffer: MTLBuffer

    init(device: MTLDevice, maxInstances: Int = 1_048_576) {
        let instBytes = maxInstances * MemoryLayout<Instance>.stride
        let lodBytes  = maxInstances * 4 * MemoryLayout<MeshLOD>.stride // 每实例最多 4 个 LOD

        guard let ib = device.makeBuffer(length: instBytes, options: .storageModeShared),
              let lb = device.makeBuffer(length: lodBytes, options: .storageModeShared) else {
            fatalError("无法分配场景 GPU 缓冲(检查设备显存工作集)")
        }
        self.instanceBuffer = ib
        self.instanceBuffer.label = "SceneInstances"
        self.lodBuffer = lb
        self.lodBuffer.label = "SceneLODs"
    }

    /// 追加一个实例及其 LOD 链。返回实例下标。
    @discardableResult
    func addInstance(_ inst: Instance, lods: [MeshLOD]) -> Int {
        let idx = instances.count
        instances.append(inst)
        var lodBase = self.lods.count
        // firstLodIndex 指向该实例的 LOD 起点
        var mut = inst
        mut.firstLodIndex = UInt32(lodBase)
        mut.lodCount = UInt32(lods.count)
        instances[idx] = mut
        self.lods.append(contentsOf: lods)
        return idx
    }

    /// 将 CPU 数据上载到 GPU 缓冲(仅脏数据时调用)。
    func uploadIfDirty() {
        guard !instances.isEmpty else { return }
        let instData = instances.withUnsafeBytes { Data($0) }
        instData.withUnsafeBytes {
            instanceBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: instData.count)
        }
        let lodData = lods.withUnsafeBytes { Data($0) }
        lodData.withUnsafeBytes {
            lodBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: lodData.count)
        }
    }
}
