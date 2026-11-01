import MetalKit
import MetalPerformanceShaders
import CoreVideo
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

    enum PreparationError: Error, Sendable {
        case metalUnavailable
        case shaderUnavailable
        case rendererUnavailable
    }

    private struct Ready: @unchecked Sendable {
        let device: any MTLDevice
        let computePipeline: any MTLComputePipelineState
        let finishPipeline: any MTLComputePipelineState
        let materialFinishPipeline: any MTLComputePipelineState
    }
    /// Created once on the preparation queue. Texture-cache operations and MPS encoding
    /// remain on MainActor; command buffers retain their own frame leases through completion.
    struct RendererResources: @unchecked Sendable {
        let device: any MTLDevice
        let computePipeline: any MTLComputePipelineState
        let finishPipeline: any MTLComputePipelineState
        let materialFinishPipeline: any MTLComputePipelineState
        let commandQueue: any MTLCommandQueue
        let textureCache: CVMetalTextureCache
        let energyDownsampler: MPSImageBilinearScale
    }
    private struct State {
        var ready: Ready?
        var renderer: RendererResources?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let preparationQueue = DispatchQueue(label: "com.justshoot.preview-prepare", qos: .utility)

    /// Accessors only read a completed snapshot; UIKit construction cannot compile a PSO.
    var device: (any MTLDevice)? { state.withLock { $0.ready?.device } }
    var computePipeline: (any MTLComputePipelineState)? { state.withLock { $0.ready?.computePipeline } }
    var finishPipeline: (any MTLComputePipelineState)? { state.withLock { $0.ready?.finishPipeline } }
    @MainActor var rendererResources: RendererResources? { state.withLock { $0.renderer } }

    private init() {}

    /// Await actual pipeline creation without blocking MainActor or Swift's cooperative pool.
    /// Only success is cached. A later call retries a failed driver/library initialization.
    static func warmUp() async throws {
        try await shared.prepare(includeRenderer: false)
    }

    static func warmUpForRenderer() async throws {
        try await shared.prepare(includeRenderer: true)
    }

    private func prepare(includeRenderer: Bool) async throws {
        try Task.checkCancellation()
        if state.withLock({ includeRenderer ? $0.renderer != nil : $0.ready != nil }) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            preparationQueue.async(qos: includeRenderer ? .userInitiated : .utility, flags: [.enforceQoS, .detached]) { [self] in
                do {
                    try initializeIfNeeded()
                    if includeRenderer { try initializeRendererIfNeeded() }
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
    }

    private func initializeRendererIfNeeded() throws {
        if state.withLock({ $0.renderer != nil }) { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard let ready = state.withLock({ $0.ready }),
              let queue = ready.device.makeCommandQueue() else { throw PreparationError.rendererUnavailable }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, ready.device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw PreparationError.rendererUnavailable }
        queue.label = "com.justshoot.preview"
        let renderer = RendererResources(device: ready.device, computePipeline: ready.computePipeline,
            finishPipeline: ready.finishPipeline, materialFinishPipeline: ready.materialFinishPipeline, commandQueue: queue, textureCache: cache,
            energyDownsampler: MPSImageBilinearScale(device: ready.device))
        state.withLock { $0.renderer = renderer }
        Diagnostics.emit("preview_renderer_resources_prepared",
            fields: "main_thread=\(Thread.isMainThread) duration_ms=\(Diagnostics.milliseconds(since: startedAt))")
    }

    private func initializeIfNeeded() throws {
        if state.withLock({ $0.ready != nil }) { return }
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw PreparationError.metalUnavailable }
            guard let library = device.makeDefaultLibrary(),
                  let function = library.makeFunction(name: "previewLUT"),
                  let finishFunction = library.makeFunction(name: "previewFinish"),
                  let materialFunction = library.makeFunction(name: "previewMaterialFinish") else {
                throw PreparationError.shaderUnavailable
            }
            let ready = try Ready(device: device,
                computePipeline: device.makeComputePipelineState(function: function),
                finishPipeline: device.makeComputePipelineState(function: finishFunction),
                materialFinishPipeline: device.makeComputePipelineState(function: materialFunction))
            state.withLock { $0.ready = ready }
        } catch {
            Log.session.error("metal_prepare_failed")
            throw error
        }
    }
}

/// Bound drawable work independently of screen density and iPad window size.
