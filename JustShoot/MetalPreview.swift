import SwiftUI
import MetalKit
@preconcurrency import CoreVideo
import os

// MARK: - 实时预览视图（全 Metal 管线：CVPixelBuffer → compute shader → drawable）
struct RealtimePreviewView: UIViewRepresentable {
    let manager: CameraManager
    let lutCacheKey: String

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let fallback = MTKView(frame: .zero)
            fallback.backgroundColor = .black
            return fallback
        }
        let view = MTKView(frame: .zero, device: device)
        // 事件驱动渲染：只在新帧到达时绘制（由相机回调触发 setNeedsDisplay）
        view.isPaused = true
        view.enableSetNeedsDisplay = true
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
        weak var manager: CameraManager?

        // Metal 核心对象
        private var metalDevice: (any MTLDevice)?
        private var commandQueue: (any MTLCommandQueue)?
        private var computePipeline: (any MTLComputePipelineState)?

        // CVPixelBuffer → MTLTexture 零拷贝缓存
        private var textureCache: CVMetalTextureCache?

        // 3D LUT 纹理缓存（每个预设一个，首次使用时创建）
        private var lutTextures: [String: any MTLTexture] = [:]
        private var lutDimensions: [String: Int] = [:]

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

            // 加载 compute shader
            guard let library = device.makeDefaultLibrary(),
                  let function = library.makeFunction(name: "previewLUT") else {
                Log.session.error("metal_shader_load_failed")
                return
            }
            computePipeline = try? device.makeComputePipelineState(function: function)
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

            // 获取或创建 3D LUT 纹理
            guard let lutTexture = getOrCreateLUTTexture(cacheKey: lutCacheKey) else {
                inflightSemaphore.signal()
                return
            }
            let lutDim = lutDimensions[lutCacheKey] ?? 25

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
                lutDimension: UInt32(lutDim)
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

        private func getOrCreateLUTTexture(cacheKey: String) -> (any MTLTexture)? {
            if let cached = lutTextures[cacheKey] { return cached }

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
            return texture
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
