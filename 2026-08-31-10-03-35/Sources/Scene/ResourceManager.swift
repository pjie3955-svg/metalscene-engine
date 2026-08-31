import Foundation
import Metal

/// 资源管理层:用资源堆(Heap)做缓冲/纹理的子分配,
/// 并用 Argument Buffer Tier2 把"材质"打包成 Bindless 可索引的槽位。
///
/// 设计要点:
/// 1. 所有几何/纹理进入预分配堆,避免运行时频繁分配导致卡顿。
/// 2. 每种材质编码为一个独立 argument buffer(含 3 张纹理 + 常量)。
/// 3. 渲染端通过 materialID 索引到这些 argument buffer,实现"无绑定"取材质。
final class ResourceManager {

    let device: MTLDevice
    let caps: Platform.Capabilities

    /// 缓冲堆(顶点/索引/uniform 等大块数据)
    private let bufferHeap: MTLHeap
    /// 纹理堆(所有材质贴图)
    private let textureHeap: MTLHeap

    /// 每种材质对应的 Argument Buffer(由 MTLArgumentDescriptor 直接构建,无需 shader 函数反射)
    private(set) var materialArgumentBuffers: [MTLBuffer] = []

    /// 编码一个材质所需的 argument encoder(所有材质共用同一布局)
    private let materialEncoder: MTLArgumentEncoder

    init(device: MTLDevice, caps: Platform.Capabilities) {
        self.device = device
        self.caps = caps

        let bufferHeapDesc = MTLHeapDescriptor()
        bufferHeapDesc.size = caps.isDesktop ? 2_147_483_648 : 536_870_912 // 2GiB / 512MiB
        bufferHeapDesc.storageMode = caps.isDesktop ? .private : .shared
        bufferHeapDesc.type = .sparse // 稀疏堆允许别名,进一步省显存
        guard let bh = device.makeHeap(descriptor: bufferHeapDesc) else {
            fatalError("创建缓冲堆失败")
        }
        self.bufferHeap = bh

        let textureHeapDesc = MTLHeapDescriptor()
        textureHeapDesc.size = caps.isDesktop ? 3_221_225_472 : 1_073_741_824 // 3GiB / 1GiB
        textureHeapDesc.storageMode = caps.isDesktop ? .private : .shared
        textureHeapDesc.type = .sparse
        guard let th = device.makeHeap(descriptor: textureHeapDesc) else {
            fatalError("创建纹理堆失败")
        }
        self.textureHeap = th

        // 材质 argument buffer 布局:3 张纹理 + 1 个常量 buffer
        let albedo = MTLArgumentDescriptor()
        albedo.index = 0; albedo.dataType = .texture
        albedo.textureType = .type2D; albedo.access = .readOnly

        let normal = MTLArgumentDescriptor()
        normal.index = 1; normal.dataType = .texture
        normal.textureType = .type2D; normal.access = .readOnly

        let metallicRough = MTLArgumentDescriptor()
        metallicRough.index = 2; metallicRough.dataType = .texture
        metallicRough.textureType = .type2D; metallicRough.access = .readOnly

        let constants = MTLArgumentDescriptor()
        constants.index = 3; constants.dataType = .buffer
        constants.access = .readOnly
        constants.bufferDataType = .struct

        guard let enc = device.makeArgumentEncoder(arguments: [albedo, normal, metallicRough, constants]) else {
            fatalError("创建材质 argument encoder 失败(需 Argument Buffer Tier2)")
        }
        self.materialEncoder = enc
    }

    /// 在堆上分配一张纹理(贴图统一使用 ASTC 压缩格式,跨平台一致)。
    func makeTexture(width: Int, height: Int, format: MTLPixelFormat = Platform.albedoTextureFormat) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: true)
        desc.storageMode = textureHeap.storageMode
        desc.usage = [.shaderRead]
        return textureHeap.makeTexture(descriptor: desc)
    }

    /// 注册一个材质:在堆上分配 3 张贴图,并把它们编码进一个 argument buffer。
    /// 返回 materialID(= 在 materialArgumentBuffers 中的下标),供实例引用。
    @discardableResult
    func registerMaterial(albedo: MTLTexture, normal: MTLTexture, metallicRoughness: MTLTexture,
                          baseColor: SIMD4<Float> = .init(1,1,1,1),
                          metallic: Float = 0, roughness: Float = 1) -> Int {
        let buf = device.makeBuffer(length: materialEncoder.encodedLength, options: .storageModeShared)!
        buf.label = "Material#\(materialArgumentBuffers.count)"
        materialEncoder.setArgumentBuffer(buf, offset: 0)
        materialEncoder.setTexture(albedo, index: 0)
        materialEncoder.setTexture(normal, index: 1)
        materialEncoder.setTexture(metallicRoughness, index: 2)

        var c = MaterialConstants(baseColor: baseColor, metallic: metallic, roughness: roughness, pad: 0)
        let cbuf = device.makeBuffer(length: MemoryLayout<MaterialConstants>.stride, options: .storageModeShared)!
        cbuf.contents().copyMemory(from: &c, byteCount: MemoryLayout<MaterialConstants>.stride)
        materialEncoder.setBuffer(cbuf, offset: 0, index: 3)

        let id = materialArgumentBuffers.count
        materialArgumentBuffers.append(buf)
        return id
    }

    /// 真实 Bindless 取材质时,渲染端会把整组 materialArgumentBuffers 包进一个
    /// array<argument_buffer> 顶层 argument buffer,由 materialID 直接索引(见 Shading.metal)。
    var materialTableBuffer: MTLBuffer? {
        // 占位:实际实现中此处返回一个持有 materialArgumentBuffers 数组的堆缓冲。
        materialArgumentBuffers.first
    }
}

/// 材质常量,镜像 Shader 侧 MaterialConstants。
struct MaterialConstants {
    var baseColor: SIMD4<Float>
    var metallic: Float
    var roughness: Float
    var pad: Float
}
