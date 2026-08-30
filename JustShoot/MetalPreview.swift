import SwiftUI
import MetalKit
@preconcurrency import CoreVideo
import os

// MARK: - 进程级共享 Metal 资源（启动预热，消除首次进入拍摄页的转场掉帧）
//
// MTLDevice 实例化 + default library 加载 + LUT compute PSO 编译，首次都在主线程花几十~上百 ms。
// 旧实现把它们放在 RealtimePreviewView.makeUIView → Coordinator.setup 里同步创建，正好落在
// 「列表 tile → 拍摄页」的 .zoom 转场期间 → 转场掉帧（用户感知的「第一次进入卡顿」），GPU/驱动
// 也要到进入后第一秒才热起来，连带第一次切焦距的预览也掉帧。
//
// 改为进程级共享、app 启动时在后台预热一次、全进程复用：makeUIView 只取现成 device，setup 只取
// 现成 PSO，转场不再被 Metal 初始化阻塞。device/library/PSO 的创建是线程安全的，可在后台线程做。
final class PreviewMetalResources: @unchecked Sendable {
    static let shared = PreviewMetalResources()

    let device: (any MTLDevice)?
    let computePipeline: (any MTLComputePipelineState)?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.computePipeline = nil
            return
        }
        self.device = device
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "previewLUT"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            Log.session.error("metal_shader_load_failed")
            self.computePipeline = nil
            return
        }
        self.computePipeline = pipeline
    }

    /// 由调用方安排在后台阶段执行，避免本类型再私自派生并发任务、与其它冷启动工作争抢资源。
    /// 幂等：shared 是 lazy 单例，多次调用只会命中已构建实例。
    static func prepare() {
        _ = PreviewMetalResources.shared
    }
}

// MARK: - 实时预览视图（全 Metal 管线：CVPixelBuffer → compute shader → drawable）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    let lutCacheKey: String
    let grain: FilmGrainParameters

    func makeUIView(context: Context) -> MTKView {
        // 复用启动时预热好的共享 device，避免在转场期间于主线程实例化 GPU 设备。
        guard let device = PreviewMetalResources.shared.device ?? MTLCreateSystemDefaultDevice() else {
            let fallback = MTKView(frame: .zero)
            fallback.backgroundColor = .black
            return fallback
        }
        let view = MTKView(frame: .zero, device: device)
        // CADisplayLink 驱动渲染：MTKView 内部以屏幕 vsync 节拍调 draw(in:)。
        // draw() 内部按 lastRenderedFrameId 去重，没有新相机帧时立刻 return（~零成本）。
        //
        // 旧实现是 isPaused=true + enableSetNeedsDisplay=true，由 captureOutput 每帧
        // DispatchQueue.main.async { setNeedsDisplay() } 触发。问题：编码繁忙 / 相机切镜头时
        // 主队列堆积，setNeedsDisplay 排队跟其它 UI 工作竞争，预览会丢帧。CADisplayLink 走
        // CoreAnimation 内部线程，不经过应用主队列，跟主线程其它工作解耦。
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false  // 允许 compute shader 写入 drawable
        // 预览降分辨率：2x 而非 3x，减少 55% 像素量
        view.contentScaleFactor = min(context.environment.displayScale, 2.0)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = true
        context.coordinator.setup(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.lutCacheKey = lutCacheKey
        context.coordinator.grain = grain
        context.coordinator.manager = manager
        manager.previewMTKView = uiView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Metal Preview Coordinator
    // @MainActor：MTKViewDelegate.draw 在主线程触发（enableSetNeedsDisplay=true），
    // 同时需要访问 @MainActor 的 CameraManager 属性（previewRotationAngle 等）
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var lutCacheKey: String = ""
        var grain: FilmGrainParameters = .disabled
        weak var manager: CameraManager?

        // Metal 核心对象
        private var metalDevice: (any MTLDevice)?
        private var commandQueue: (any MTLCommandQueue)?
        private var computePipeline: (any MTLComputePipelineState)?

        // CVPixelBuffer → MTLTexture 零拷贝缓存
        private var textureCache: CVMetalTextureCache?

        // 3D LUT 纹理缓存（每个预设一个，首次使用时创建）
        // 一个 64³ LUT 在 rgba32Float 下约 4MB，胶片条划一圈会把所有用过的 LUT 都留在 GPU
        // 内存里——旧实现永不淘汰。加 LRU 上限：只保留最近用过的 N 个，其余在创建新纹理时驱逐。
        private var lutTextures: [String: any MTLTexture] = [:]
        private var lutDimensions: [String: Int] = [:]
        private var lutAccessOrder: [String] = []   // LRU：队首=最久未用
        private static let maxCachedLUTs = 8

        // Triple-buffer 信号量：限制 GPU 最多 3 帧 in-flight，防止命令堆积
        // nonisolated：`DispatchSemaphore` 线程安全，且 GPU completion handler 在后台线程触发
        nonisolated private let inflightSemaphore = DispatchSemaphore(value: 3)

        // 帧去重：避免同一相机帧被渲染两次
        private var lastRenderedFrameId: UInt64 = 0

        // 纹理缓存刷新计数器
        private var frameCount: UInt32 = 0

        // Shader 参数结构（必须与 LUTShader.metal 中的 PreviewParams 一致）
        private struct PreviewParams {
            var scale: Float
            var offsetX: Float
            var offsetY: Float
            var inputWidth: UInt32
            var inputHeight: UInt32
            var rotation: UInt32
            var lutDimension: UInt32
            var grainAmount: Float
            var grainSize: Float
            var grainChroma: Float
            var grainSeed: UInt32
        }

        func setup(view: MTKView) {
            guard let device = view.device else { return }
            metalDevice = device
            commandQueue = device.makeCommandQueue()
            // 设置最大 in-flight command buffers
            commandQueue?.label = "com.justshoot.preview"
            view.delegate = self

            // 创建 CVMetalTextureCache（零拷贝访问相机像素缓冲区）
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache

            // compute PSO 由进程级共享资源在启动时预编译，这里直接复用——makeUIView 不再于
            // 转场期间同步编译 shader。兜底：极端情况下共享资源缺失（如 Metal 不可用回退路径
            // 自建了 device）时本地构建一次，保证功能不退化。
            if let shared = PreviewMetalResources.shared.computePipeline,
               PreviewMetalResources.shared.device === device {
                computePipeline = shared
            } else if let library = device.makeDefaultLibrary(),
                      let function = library.makeFunction(name: "previewLUT") {
                computePipeline = try? device.makeComputePipelineState(function: function)
            } else {
                Log.session.error("metal_shader_load_failed")
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        // MARK: - 每帧渲染（全 Metal，无 CIImage/CIFilter）

        // 一次性诊断用计数器
        private var skipFrameCount: Int = 0
        private var didLogFirstDraw: Bool = false

        func draw(in view: MTKView) {
            // 帧去重：如果相机没有产生新帧，跳过渲染
            guard let (pixelBuffer, frameId) = manager?.getLatestFrame(),
                  frameId != lastRenderedFrameId else {
                return
            }

            // Triple-buffer 背压控制：如果 GPU 有 3 帧在队列中，跳过当前帧
            guard inflightSemaphore.wait(timeout: .now()) == .success else {
                return
            }

            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let pipeline = computePipeline,
                  let cache = textureCache else {
                inflightSemaphore.signal()
                skipFrameCount += 1
                if skipFrameCount % 60 == 1 {
                    Log.session.error("preview_skip n=\(self.skipFrameCount)")
                }
                return
            }

            lastRenderedFrameId = frameId

            if !didLogFirstDraw {
                didLogFirstDraw = true
                Log.session.info("preview_first_draw skipped=\(self.skipFrameCount) lut_key=\(self.lutCacheKey, privacy: .public)")
            }

            // 定期刷新纹理缓存，释放不再使用的 CVMetalTexture（每 300 帧 ≈ 10s）
            frameCount &+= 1
            if frameCount % 300 == 0 {
                CVMetalTextureCacheFlush(cache, 0)
            }

            let inW = CVPixelBufferGetWidth(pixelBuffer)
            let inH = CVPixelBufferGetHeight(pixelBuffer)

            // CVPixelBuffer → MTLTexture（零拷贝，GPU 直接读取相机帧内存）
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil,
                .bgra8Unorm, inW, inH, 0, &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTex = cvTexture,
                  let inputTexture = CVMetalTextureGetTexture(cvTex) else {
                inflightSemaphore.signal()
                return
            }

            // 获取或创建 3D LUT 纹理（纹理与维度一起返回，二者永不可能不同步）
            guard let (lutTexture, lutDim) = getOrCreateLUTTexture(cacheKey: lutCacheKey) else {
                inflightSemaphore.signal()
                return
            }

            let outW = drawable.texture.width
            let outH = drawable.texture.height

            // 计算旋转参数
            let isLandscape = inW > inH
            let isPortraitView = outH > outW
            var rotation: UInt32 = 0
            if isLandscape && isPortraitView {
                rotation = 1  // 90° CW
            } else if let angle = manager?.previewRotationAngle, angle != 0 {
                rotation = rotationFromAngle(angle)
            }

            // 计算 aspect-fill 参数
            let rotatedW: Float
            let rotatedH: Float
            if rotation == 1 || rotation == 3 {
                rotatedW = Float(inH)
                rotatedH = Float(inW)
            } else {
                rotatedW = Float(inW)
                rotatedH = Float(inH)
            }

            let scaleX = Float(outW) / rotatedW
            let scaleY = Float(outH) / rotatedH
            let scale = max(scaleX, scaleY)
            let offsetX = (Float(outW) - rotatedW * scale) / 2.0
            let offsetY = (Float(outH) - rotatedH * scale) / 2.0

            var params = PreviewParams(
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY,
                inputWidth: UInt32(inW),
                inputHeight: UInt32(inH),
                rotation: rotation,
                lutDimension: UInt32(lutDim),
                grainAmount: grain.amount,
                grainSize: grain.pixelSize(forLongEdge: CGFloat(max(outW, outH))),
                grainChroma: grain.chroma,
                grainSeed: FilmGrainRenderer.mixedSeed(
                    base: 0x4A53_4752,
                    counter: UInt32(truncatingIfNeeded: frameId)
                )
            )

            // 编码 compute 命令
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                inflightSemaphore.signal()
                return
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(lutTexture, index: 1)
            encoder.setTexture(drawable.texture, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<PreviewParams>.size, index: 0)

            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: outW, height: outH, depth: 1)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)

            encoder.endEncoding()

            // GPU 完成后释放信号量，允许下一帧排队
            // 捕获 semaphore 本身（值语义 nonisolated），避免把 @MainActor self 带入 Sendable 闭包
            let semaphore = self.inflightSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - 3D LUT 纹理管理

        private func getOrCreateLUTTexture(cacheKey: String) -> (texture: any MTLTexture, dim: Int)? {
            if let cached = lutTextures[cacheKey], let dim = lutDimensions[cacheKey] {
                touchLUT(cacheKey)
                return (cached, dim)
            }

            guard let device = metalDevice else { return nil }

            // 从 FilmProcessor 缓存获取 LUT 数据
            guard let lut = FilmProcessor.shared.getCachedLUT(cacheKey: cacheKey) else { return nil }
            let dim = lut.dimension

            // 创建 3D 纹理（硬件三线性插值采样）
            let desc = MTLTextureDescriptor()
            desc.textureType = .type3D
            desc.pixelFormat = .rgba32Float
            desc.width = dim
            desc.height = dim
            desc.depth = dim
            desc.usage = [.shaderRead]
            desc.storageMode = .shared

            guard let texture = device.makeTexture(descriptor: desc) else { return nil }

            lut.data.withUnsafeBytes { ptr in
                texture.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: 0, y: 0, z: 0),
                        size: MTLSize(width: dim, height: dim, depth: dim)
                    ),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: dim * 4 * MemoryLayout<Float>.size,
                    bytesPerImage: dim * dim * 4 * MemoryLayout<Float>.size
                )
            }

            lutTextures[cacheKey] = texture
            lutDimensions[cacheKey] = dim
            touchLUT(cacheKey)
            evictLUTsIfNeeded()
            return (texture, dim)
        }

        /// 标记 cacheKey 为最近使用：从顺序表移除后追加到队尾。
        private func touchLUT(_ cacheKey: String) {
            if let idx = lutAccessOrder.firstIndex(of: cacheKey) {
                lutAccessOrder.remove(at: idx)
            }
            lutAccessOrder.append(cacheKey)
        }

        /// 超过上限时从队首（最久未用）驱逐，texture/dimension 两表同步删除——二者始终一致。
        private func evictLUTsIfNeeded() {
            while lutAccessOrder.count > Self.maxCachedLUTs {
                let oldest = lutAccessOrder.removeFirst()
                lutTextures[oldest] = nil
                lutDimensions[oldest] = nil
            }
        }

        private func rotationFromAngle(_ angle: CGFloat) -> UInt32 {
            let normalized = Int(angle.truncatingRemainder(dividingBy: 360))
            switch normalized {
            case 90:  return 1  // 90° CW
            case 180: return 2
            case 270: return 3
            default:  return 0
            }
        }
    }
}
