import Foundation
import MetalPerformanceShaders
import os

/// Creation runs on one worker; published kernels are configured once and encoded only on MainActor.
final class PreviewDiffusionKernelCache: Sendable {
    static let shared = PreviewDiffusionKernelCache()

    struct Recipe: Hashable, Sendable {
        let halationSigma: Float?
        let bloomSigma: Float?

        init?(optics: FilmOpticsParameters, width: Int, height: Int) {
            guard width > 0, height > 0 else { return nil }
            let small = CameraPerformancePolicy.diffusionSize(width: width, height: height)
            let longEdge = max(width, height)
            let scale = Float(max(small.width, small.height)) / Float(longEdge)
            halationSigma = optics.halationAmount > 0.0001
                ? optics.radiusPixels(optics.halationRadius, forLongEdge: CGFloat(longEdge)) * 0.55 * scale : nil
            bloomSigma = optics.bloomAmount > 0.0001
                ? optics.radiusPixels(optics.bloomRadius, forLongEdge: CGFloat(longEdge)) * 0.45 * scale : nil
            guard [halationSigma, bloomSigma].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        }
    }

    struct Kernels: @unchecked Sendable {
        let halation: MPSImageGaussianBlur?
        let bloom: MPSImageGaussianBlur?
    }

    private struct State {
        var cache: ByteBudgetLRU<Recipe, Kernels>
        var pending: Recipe?
        var isPreparing = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "com.justshoot.preview-diffusion", qos: .userInitiated)
    private let prepare: @Sendable (Recipe) -> Kernels?

    init(maximumEntries: Int = 16,
         prepare: @escaping @Sendable (Recipe) -> Kernels? = PreviewDiffusionKernelCache.makeKernels) {
        state = OSAllocatedUnfairLock(initialState: State(cache: ByteBudgetLRU(
            maximumBytes: 0, maximumEntries: max(1, maximumEntries))))
        self.prepare = prepare
    }

    /// Drawing retains the previous complete frame on a miss. One pending slot replaces
    /// superseded film/size requests, so rapid interaction cannot build an allocation backlog.
    @MainActor
    func request(_ recipe: Recipe) -> Kernels? {
        let (value, shouldStart): (Kernels?, Bool) = state.withLock {
            if let value = $0.cache.value(forKey: recipe) {
                $0.pending = nil
                return (value, false)
            }
            $0.pending = recipe
            guard !$0.isPreparing else { return (nil, false) }
            $0.isPreparing = true
            return (nil, true)
        }
        if shouldStart { queue.async { [self] in drain() } }
        return value
    }

    private func drain() {
        while let recipe = state.withLock({ state -> Recipe? in
            guard let recipe = state.pending else {
                state.isPreparing = false
                return nil
            }
            state.pending = nil
            return recipe
        }) {
            if state.withLock({ $0.cache.value(forKey: recipe) != nil }) { continue }
            if let value = autoreleasepool(invoking: { prepare(recipe) }) {
                _ = state.withLock { $0.cache.insert(value, forKey: recipe, cost: 0) }
            }
        }
    }

    static func makeKernels(_ recipe: Recipe) -> Kernels? {
        guard let device = PreviewMetalResources.shared.device else { return nil }
        let startedAt = ProcessInfo.processInfo.systemUptime
        func blur(_ sigma: Float?) -> MPSImageGaussianBlur? {
            guard let sigma else { return nil }
            let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
            kernel.edgeMode = .zero
            return kernel
        }
        let kernels = Kernels(halation: blur(recipe.halationSigma), bloom: blur(recipe.bloomSigma))
        Diagnostics.emit("preview_diffusion_prepared",
            fields: "main_thread=\(Thread.isMainThread) duration_ms=\(Diagnostics.milliseconds(since: startedAt))")
        return kernels
    }
}
