import Foundation
import MetalKit

/// 主渲染器:GPU 驱动管线。
///
/// 每帧只做"轻量 CPU 调度":
///   1. 写入本帧 Uniform(三缓冲之一)
///   2. 1 次计算编码:GPU 视锥/LOD 剔除,并把可见实例直接编码进 Indirect Command Buffer
///   3. 1 次渲染编码:executeCommandsInBuffer 让 GPU 自己回放绘制命令
///   4. (可选)MetalFX 时间超分救场
///
/// 无论场景有 1k 还是 1M 实例,CPU 提交的开销几乎恒定 —— 这是撑住百万级的关键。
final class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let caps: Platform.Capabilities
    let resourceManager: ResourceManager
    let scene: Scene

    // 三缓冲:避免 CPU 写 Uniform 时 GPU 正在读上一帧,消除管线停顿。
    private var frameUniformBuffers: [MTLBuffer] = []
    private let tripleBufferCount = 3
    private var frameIndex = 0

    // 管线与资源
    private var cullPipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var icb: MTLIndirectCommandBuffer!

    // 剔除计算的辅助缓冲
    private var atomicCounter: MTLBuffer!      // 可见实例计数(原子累加)
    private var visibleInstanceBuffer: MTLBuffer! // 紧凑的可见实例下标列表
    private var drawCountBuffer: MTLBuffer!    // 回传给 CPU 的可见数(readback,非阻塞)

    private let maxInstances: Int
    private var metalFX: AnyObject? // MetalFXTemporalUpscaler(特性可选)

    /// 共享几何顶点缓冲(由 glTF/USD 加载器填充;属性布局:pos(12)+normal(12)+uv(8)=32B/顶点)
    var geometryVertexBuffer: MTLBuffer?
    /// 共享索引缓冲(所有网格的索引平铺于此,LOD 通过偏移切分)
    var geometryIndexBuffer: MTLBuffer?

    init?(view: MTKView, device: MTLDevice, maxInstances: Int = 1_048_576) {
        self.device = device
        self.maxInstances = maxInstances
        guard let q = device.makeCommandQueue() else { return nil }
        self.commandQueue = q
        self.caps = Platform.detect(device: device)

        guard caps.argumentBufferTier2, caps.indirectCommandBuffers else {
            fatalError("当前 GPU 不支持 Bindless/ICB,无法运行百万级 GPU 驱动管线")
        }

        self.resourceManager = ResourceManager(device: device, caps: caps)
        self.scene = Scene(device: device, maxInstances: maxInstances)
        super.init()

        setupUniforms()
        setupPipelines(view: view)
        setupICB()
        setupCullBuffers()

        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.framebufferOnly = true
    }

    // MARK: - 初始化

    private func setupUniforms() {
        for _ in 0..<tripleBufferCount {
            let buf = device.makeBuffer(length: MemoryLayout<FrameUniforms>.stride,
                                        options: .storageModeShared)!
            buf.label = "FrameUniforms"
            frameUniformBuffers.append(buf)
        }
    }

    private func setupPipelines(view: MTKView) {
        guard let lib = device.makeDefaultLibrary() else { fatalError("缺少 .metal 库") }

        // 计算剔除管线
        guard let cullFn = lib.makeFunction(name: "cullAndEncode"),
              let cullPS = try? device.makeComputePipelineState(function: cullFn) else {
            fatalError("编译 cullAndEncode 失败")
        }
        self.cullPipeline = cullPS

        // 主渲染管线(Bindless,间接绘制)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vertex_main")
        desc.fragmentFunction = lib.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        // 间接绘制:顶点数据全部来自缓冲,无需逐实例顶点缓冲绑定
        desc.supportIndirectCommandBuffers = true
        // 顶点描述符:把属性 0/1/2 映射到"几何缓冲"(渲染编码器 index 3,ICB 继承)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].bufferIndex = 3; vd.attributes[0].offset = 0
        vd.attributes[1].format = .float3; vd.attributes[1].bufferIndex = 3; vd.attributes[1].offset = 12
        vd.attributes[2].format = .float2; vd.attributes[2].bufferIndex = 3; vd.attributes[2].offset = 24
        vd.layouts[3].stride = 32; vd.layouts[3].stepFunction = .perVertex
        desc.vertexDescriptor = vd
        guard let ps = try? device.makeRenderPipelineState(descriptor: desc) else {
            fatalError("编译主渲染管线失败")
        }
        self.renderPipeline = ps

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: ds)!

        if caps.metalFXTemporalUpscale {
            // 真实项目在此初始化 MetalFXTemporalUpscaler,内部分辨率随热状态缩放。
            metalFX = nil // 占位:见设计文档"动态分辨率"一节
        }
    }

    private func setupICB() {
        let icbDesc = MTLIndirectCommandBufferDescriptor()
        icbDesc.commandTypes = .drawIndexed
        icbDesc.inheritBuffers = true        // 顶点/索引缓冲由渲染编码器统一提供
        icbDesc.inheritPipelineState = true  // 渲染管线由渲染编码器统一提供
        icbDesc.maxVertexBufferBindCount = 8
        icbDesc.maxFragmentBufferBindCount = 8
        guard let icb = device.makeIndirectCommandBuffer(
            with: icbDesc, maxCommandCount: maxInstances, options: .managed) else {
            fatalError("创建 Indirect Command Buffer 失败")
        }
        icb.label = "SceneICB"
        self.icb = icb
    }

    private func setupCullBuffers() {
        atomicCounter = device.makeBuffer(length: 16, options: .storageModeShared)
        visibleInstanceBuffer = device.makeBuffer(
            length: maxInstances * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        drawCountBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }

    // MARK: - 每帧

    func draw(in view: MTKView) {
        frameIndex = (frameIndex + 1) % tripleBufferCount

        // 1. 本帧 Uniform:由相机/输入更新(此处用占位矩阵)
        var fu = FrameUniforms(/* ... 由相机计算 view/proj/frustum ... */)
        frameUniformBuffers[frameIndex].contents()
            .copyMemory(from: &fu, byteCount: MemoryLayout<FrameUniforms>.stride)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        // 2. 计算剔除:GPU 写可见实例 + 直接编码 ICB 命令
        cmd.resetCommandsInBuffer(icb, range: 0..<maxInstances) // 先清空上一帧命令
        let enc = cmd.computeCommandEncoder()!
        enc.setComputePipelineState(cullPipeline)
        enc.setBuffer(scene.instanceBuffer, offset: 0, index: 0)
        enc.setBuffer(scene.lodBuffer, offset: 0, index: 1)
        enc.setBuffer(icb, offset: 0, index: 2)            // ICB 作为参数缓冲传入 compute
        enc.setBuffer(atomicCounter, offset: 0, index: 3)
        enc.setBuffer(visibleInstanceBuffer, offset: 0, index: 4)
        enc.setBuffer(frameUniformBuffers[frameIndex], offset: 0, index: 5)
        if let ib = geometryIndexBuffer { enc.setBuffer(ib, offset: 0, index: 6) }
        let tg = min(cullPipeline.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: maxInstances, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()

        // 3. 主渲染通道:回放 ICB(GPU 自己发出的绘制命令)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let ren = cmd.renderCommandEncoder(descriptor: pass)!
        ren.setRenderPipelineState(renderPipeline)
        ren.setDepthStencilState(depthState)
        // ICB 继承的缓冲:在编码器统一绑定,所有回放命令共享
        ren.setVertexBuffer(frameUniformBuffers[frameIndex], offset: 0, index: 0)
        ren.setVertexBuffer(scene.instanceBuffer, offset: 0, index: 1)
        ren.setVertexBuffer(visibleInstanceBuffer, offset: 0, index: 2)
        if let gb = geometryVertexBuffer { ren.setVertexBuffer(gb, offset: 0, index: 3) }
        ren.setFragmentBuffer(resourceManager.materialTableBuffer, offset: 0, index: 1)
        ren.executeCommandsInBuffer(icb, range: 0..<maxInstances)
        ren.endEncoding()

        // 4. MetalFX 后处理(可选):在内部分辨率缩放后超分到 drawable 尺寸
        if let _ = metalFX {
            // 真实项目:将上一步结果作为输入,调 MetalFXTemporalUpscaler.process()
        }

        cmd.present(drawable)
        cmd.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 视口变化:触发深度纹理重建(此处省略,真实项目需同步重建 depthTexture)
    }
}
