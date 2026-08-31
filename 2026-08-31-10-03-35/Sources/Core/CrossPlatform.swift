import Foundation
import Metal

/// 跨 macOS / iOS 的平台与 GPU 能力检测。
/// 1M+ 规模必须依赖 Argument Buffer Tier2、资源堆、GPU 驱动渲染(ICB)等特性,
/// 这些在 Apple GPU 家族上才完整可用,需在此统一探测并降级。
enum Platform {

    /// 统一的 GPU 能力集合。Renderer 启动时填充一次,运行中只读。
    struct Capabilities {
        /// 是否支持 Argument Buffer Tier 2(指针/数组,实现 Bindless 渲染的基础)
        let argumentBufferTier2: Bool
        /// 是否支持 Indirect Command Buffer(GPU 生成绘制命令)
        let indirectCommandBuffers: Bool
        /// 是否支持 MetalFX 时间超分(动态分辨率救场)
        let metalFXTemporalUpscale: Bool
        /// 设备建议的最大常驻显存工作集(macOS 宽松,iOS 严格)
        let recommendedMaxWorkingSet: Int
        /// 是否为桌面平台(决定输入方式与散热策略)
        let isDesktop: Bool
    }

    static func detect(device: MTLDevice) -> Capabilities {
        let abTier2: Bool
        if #available(macOS 11.0, iOS 14.0, *) {
            abTier2 = device.argumentBuffersSupport == .tier2
        } else {
            abTier2 = false
        }

        let icb: Bool
        if #available(macOS 11.0, iOS 14.0, *) {
            icb = device.supportsFeatureSet(.iOS_GPUFamily5_v1) ||
                  device.supportsFamily(.apple7) ||
                  device.supportsFamily(.mac2)
        } else {
            icb = false
        }

        let metalFX: Bool
        if #available(macOS 13.0, iOS 16.0, *) {
            metalFX = device.supportsFamily(.apple6) || device.supportsFamily(.mac2)
        } else {
            metalFX = false
        }

        let workingSet: Int
        if #available(macOS 11.0, iOS 14.0, *) {
            workingSet = Int(device.recommendedMaxWorkingSetSize)
        } else {
            workingSet = 1_073_741_824 // 1 GiB 保守默认值
        }

        #if os(macOS)
        let isDesktop = true
        #else
        let isDesktop = false
        #endif

        return Capabilities(
            argumentBufferTier2: abTier2,
            indirectCommandBuffers: icb,
            metalFXTemporalUpscale: metalFX,
            recommendedMaxWorkingSet: workingSet,
            isDesktop: isDesktop
        )
    }

    /// 平台相关的颜色像素格式。两平台统一走 Apple 硅的 ASTC 压缩纹理。
    static let albedoTextureFormat: MTLPixelFormat = .astc_4x4_ldr

    /// 针对热状态的动态分辨率系数。iOS 在升温时主动降内部分辨率保帧率。
    static func dynamicResolutionScale(thermalState: ProcessInfo.ThermalState) -> Float {
        switch thermalState {
        case .nominal:      return 1.0
        case .fair:         return 1.0
        case .serious:      return 0.85
        case .critical:     return 0.7
        @unknown default:   return 1.0
        }
    }
}
