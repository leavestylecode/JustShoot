import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import Metal
import os

// MARK: - Live Photo 视频处理器
//
// 把 AVCapture 产出的 Live Photo 配对视频（原始画面）逐帧套上当前胶片 LUT 与颗粒，并重写成一段带
// **content identifier** + **still-image-time** 元数据的新 .mov——这两项元数据是 Photos 把
// 「静态图 + 视频」识别为一张 Live Photo 的关键：
//   - content.identifier：与静态图 MakerApple["17"] 相同的 UUID，建立配对关系。
//   - still-image-time：标记视频时间轴上哪一帧对应静态图（长按起播/落帧的锚点），取 AVCapture
//     delegate 回调给的 photoDisplayTime。
//
// 为什么自己 reader/writer 而不用 AVAssetExportSession：export session 能带 top-level metadata，
// 但 still-image-time 是一条**定时元数据轨**，export 不保证透传；用 AVAssetWriter +
// AVAssetWriterInputMetadataAdaptor 才能精确写这条轨。逐帧 LUT 复用 FilmProcessor 已缓存的
// CubeLUT（CIColorCubeWithColorSpace，sRGB）和 FilmGrainRenderer，与静态图共用参数。
//
// 音频：v1 不加麦克风输入，源视频通常无音轨；若源带音轨则原样 passthrough 拷贝（前向兼容）。
// 把驱动转码所需的非 Sendable AVF 对象一次性带过 @Sendable 闭包边界。每条轨只被自己那条串行
// 队列触碰，无跨队列可变共享（reader.status 只读、AVF 内部线程安全）。
private final class PipelineBox: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderTrackOutput
    let videoInput: AVAssetWriterInput
    let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioOutput: AVAssetReaderTrackOutput?
    let audioInput: AVAssetWriterInput?
    let metadataInput: AVAssetWriterInput
    let metadataAdaptor: AVAssetWriterInputMetadataAdaptor
    let stillGroup: AVTimedMetadataGroup
    let lut: CubeLUT?
    let grain: FilmGrainParameters
    let optics: FilmOpticsParameters
    let grainBaseSeed: UInt32

    init(reader: AVAssetReader, writer: AVAssetWriter,
         videoOutput: AVAssetReaderTrackOutput, videoInput: AVAssetWriterInput,
         pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor,
         audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?,
         metadataInput: AVAssetWriterInput, metadataAdaptor: AVAssetWriterInputMetadataAdaptor, stillGroup: AVTimedMetadataGroup,
         lut: CubeLUT?, grain: FilmGrainParameters, optics: FilmOpticsParameters,
         grainBaseSeed: UInt32) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.pixelAdaptor = pixelAdaptor
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.metadataInput = metadataInput
        self.metadataAdaptor = metadataAdaptor
        self.stillGroup = stillGroup
        self.lut = lut
        self.grain = grain
        self.optics = optics
        self.grainBaseSeed = grainBaseSeed
    }
}

enum LivePhotoProcessor {

    enum ProcessError: Error {
        case noVideoTrack
        case readerInitFailed
        case writerInitFailed
        case writeFailed(String)
    }

    struct ProcessResult: Sendable {
        let contentIdentifier: String
        /// 使用 still-image-time 派生的确定性 seed，供配对静态图复用。
        let stillGrainSeed: UInt32
    }

    // 专用 CIContext：与 FilmProcessor 一致地锁 sRGB working/output 空间，走 Metal。视频帧量大，
    // 关 cacheIntermediates 控内存。整个进程共享一个，避免每次拍摄重建。
    private static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let ciContext: CIContext = {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
            .priorityRequestLow: true
        ]
        if let mtl = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: mtl, options: opts)
        }
        return CIContext(options: opts)
    }()

    // Encoding is demand-driven so opening the camera never competes with a synthetic HEVC job.
    @discardableResult
    static func process(
        sourceURL: URL,
        lutCacheKey: String,
        capturedLUT: CubeLUT? = nil,
        grain: FilmGrainParameters,
        optics: FilmOpticsParameters = .disabled,
        grainBaseSeed: UInt32,
        photoDisplayTime: CMTime,
        outputURL: URL,
        trace: DiagnosticTrace? = nil
    ) async throws -> ProcessResult {
        let trace = trace ?? DiagnosticTrace()
        try Task.checkCancellation()
        do {
            let timer = Log.perf("livephoto_video", logger: Log.lut)
            let loading = trace.span("live_asset_load")
            let asset = AVURLAsset(url: sourceURL)

            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProcessError.noVideoTrack
            }

            // 读 AVCapture 自动写入的配对 content identifier；读不到兜底生成。
            let originalIdentifier = try? await readContentIdentifier(from: asset)
            let contentIdentifier = originalIdentifier.flatMap { value in
                value.count == 36 && UUID(uuidString: value) != nil ? value : nil
            } ?? UUID().uuidString
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration)
            loading.end("ok", "audio=\(audioTrack != nil)")

            // 输出尺寸取整为偶数（HEVC 编码器要求宽高为偶）。
            let width = Int(naturalSize.width.rounded()) & ~1
            let height = Int(naturalSize.height.rounded()) & ~1
            guard width > 0, height > 0 else { throw ProcessError.noVideoTrack }

            // 删除可能存在的旧文件，否则 writer 创建失败。
            try? FileManager.default.removeItem(at: outputURL)

            // MARK: Reader
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) }
            catch { throw ProcessError.readerInitFailed }

            let videoReaderOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            videoReaderOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoReaderOutput) else { throw ProcessError.readerInitFailed }
            reader.add(videoReaderOutput)

            var audioReaderOutput: AVAssetReaderTrackOutput?
            if let audioTrack {
                let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil) // passthrough
                guard reader.canAdd(out) else { throw ProcessError.readerInitFailed }
                reader.add(out); audioReaderOutput = out
            }

            // MARK: Writer
            let writer: AVAssetWriter
            do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov) }
            catch { throw ProcessError.writerInitFailed }

            // top-level content identifier（与静态图配对）。
            writer.metadata = [contentIdentifierMetadataItem(contentIdentifier)]

            // 视频输入：HEVC 优先，旧设备回退 H.264。保留源 preferredTransform（出片朝向）。
            let hevcSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height]
            let codec: AVVideoCodecType = writer.canApply(outputSettings: hevcSettings, forMediaType: .video) ? .hevc : .h264
            let videoWriterInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
            )
            videoWriterInput.expectsMediaDataInRealTime = false
            videoWriterInput.transform = preferredTransform
            guard writer.canAdd(videoWriterInput) else { throw ProcessError.writerInitFailed }
            writer.add(videoWriterInput)

            let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoWriterInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )

            var audioWriterInput: AVAssetWriterInput?
            if audioReaderOutput != nil {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil) // passthrough
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw ProcessError.writerInitFailed }
                writer.add(input); audioWriterInput = input
            }

            // still-image-time 定时元数据轨。
            let metadataInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: stillImageTimeFormatDescription()
            )
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
            guard writer.canAdd(metadataInput) else { throw ProcessError.writerInitFailed }
            writer.add(metadataInput)

            defer {
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
            }
            try Task.checkCancellation()
            guard reader.startReading() else {
                throw ProcessError.writeFailed("reader_start: \(reader.error?.localizedDescription ?? "nil")")
            }
            guard writer.startWriting() else {
                throw ProcessError.writeFailed("writer_start: \(writer.error?.localizedDescription ?? "nil")")
            }
            writer.startSession(atSourceTime: .zero)

            // 写 still-image-time：落在 photoDisplayTime（无效则取中点）。给一帧时长。
            let stillTime: CMTime = {
                if photoDisplayTime.isValid && photoDisplayTime.isNumeric && photoDisplayTime >= .zero {
                    return photoDisplayTime
                }
                return CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
            }()
            let stillGrainSeed = FilmGrainRenderer.temporalSeed(
                base: grainBaseSeed,
                seconds: stillTime.seconds
            )
            let fps = nominalFrameRate > 1 ? nominalFrameRate : 30
            let stillDuration = CMTime(value: 1, timescale: Int32(fps.rounded()))
            let stillGroup = AVTimedMetadataGroup(
                items: [stillImageTimeMetadataItem()],
                timeRange: CMTimeRange(start: stillTime, duration: stillDuration)
            )

            let lut = capturedLUT ?? FilmProcessor.shared.getCachedLUT(cacheKey: lutCacheKey)
            if lut == nil {
                Log.lut.info("livephoto_lut_passthrough key=\(lutCacheKey, privacy: .public) reason=lut_missing")
            }

            // AVFoundation 对象（reader/writer/inputs/adaptor）都非 Sendable，但下面的 requestMediaDataWhenReady
            // / notify / continuation 闭包在 strict concurrency 下是 @Sendable。把它们打进一个 @unchecked
            // Sendable 持有者一次性带过边界——每条轨只被自己那条串行队列触碰，reader.status 是 AVF 内部线程安全的
            // 只读，无真实竞争（与本工程 Box / LensDumpArgs 同一处理手法）。
            let box = PipelineBox(
                reader: reader,
                writer: writer,
                videoOutput: videoReaderOutput,
                videoInput: videoWriterInput,
                pixelAdaptor: pixelAdaptor,
                audioOutput: audioReaderOutput,
                audioInput: audioWriterInput,
                metadataInput: metadataInput, metadataAdaptor: metadataAdaptor, stillGroup: stillGroup,
                lut: lut,
                grain: grain,
                optics: optics,
                grainBaseSeed: grainBaseSeed
            )

            let operation = LivePhotoTranscode(box: box, trace: trace)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.start(continuation)
                }
            } onCancel: {
                operation.cancel()
            }

            timer.end("dims=\(width)x\(height) codec=\(codec.rawValue) audio=\(audioReaderOutput != nil) grain=\(String(format: "%.3f", grain.amount)) still_t=\(String(format: "%.2f", stillTime.seconds))s cid=\(contentIdentifier)")
            return ProcessResult(
                contentIdentifier: contentIdentifier,
                stillGrainSeed: stillGrainSeed
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// 从源 Live Photo 视频读 AVCapture 写入的 QuickTime content.identifier。
    private static func readContentIdentifier(from asset: AVAsset) async throws -> String? {
        let metadata = try await asset.load(.metadata)
        for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
            if let s = try? await item.load(.stringValue) { return s }
            if let v = try? await item.load(.value) as? String { return v }
        }
        return nil
    }

    // MARK: - 逐帧 LUT + 光学 + 颗粒渲染
    //
    // srcPixel(BGRA) → CIImage → CIColorCubeWithColorSpace → FilmOptics → FilmGrain
    // → 输出 pixel buffer。链序与静态图/预览一致（LUT → headroom → halation/bloom → grain）。
    // 每帧新建一个 CIFilter（与 FilmProcessor 一致——避免跨帧/跨线程复用同一 filter 实例的竞争）。
    fileprivate static func renderFrame(
        _ srcPixel: CVPixelBuffer,
        lut: CubeLUT?,
        grain: FilmGrainParameters,
        optics: FilmOpticsParameters,
        grainSeed: UInt32,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let srcImage = CIImage(cvPixelBuffer: srcPixel)

        let gradedImage: CIImage
        if let lut, let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            filter.setValue(srcImage, forKey: kCIInputImageKey)
            filter.setValue(lut.dimension, forKey: "inputCubeDimension")
            filter.setValue(lut.data, forKey: "inputCubeData")
            filter.setValue(srgb, forKey: "inputColorSpace")
            gradedImage = filter.outputImage ?? srcImage
        } else {
            gradedImage = srcImage
        }
        let opticallyGraded = FilmOpticsRenderer.applying(to: gradedImage, parameters: optics)
        let outImage = FilmGrainRenderer.applying(
            to: opticallyGraded,
            parameters: grain,
            seed: grainSeed
        )

        var outPixel: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPixel)
        }
        guard let dst = outPixel else { return nil }
        ciContext.render(outImage, to: dst, bounds: srcImage.extent, colorSpace: srgb)
        return dst
    }

    // MARK: - 元数据构造

    /// QuickTime content.identifier（与静态图 MakerApple["17"] 同值，建立 Live Photo 配对）。
    private static func contentIdentifierMetadataItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// still-image-time 元数据项（值本身无意义，存在即标记；时间由所在 timed group 决定）。
    private static func stillImageTimeMetadataItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = AVMetadataKeySpace.quickTimeMetadata
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    /// still-image-time 定时元数据轨的源格式描述。
    private static func stillImageTimeFormatDescription() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8
        ]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc
        )
        return desc
    }
}


/// Coordinates EOF, errors, cancellation and encoder failure through one completion gate.
/// Track callbacks are serial per input; terminal state is protected by the lock.
private final class LivePhotoTranscode: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var result: Result<Void, any Error>?
        var finishedTracks: Set<Int> = []
        var videoFrames = 0
        var audioBuffers = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let box: PipelineBox
    private let trace: DiagnosticTrace
    private let watchdog: any DispatchSourceTimer
    private let started = ProcessInfo.processInfo.systemUptime

    init(box: PipelineBox, trace: DiagnosticTrace) {
        self.box = box
        self.trace = trace
        watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.setEventHandler { [weak self] in self?.checkProgress() }
        watchdog.schedule(deadline: .now() + 1, repeating: .milliseconds(250))
        watchdog.resume()
    }

    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        trace.event("live_pump_begin", "audio=\(box.audioInput != nil)")
        let result = state.withLock { state -> Result<Void, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            box.videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "camera.transcode.video", qos: .utility)) { [weak self] in
                self?.pumpVideo()
            }
            box.metadataInput.requestMediaDataWhenReady(on: DispatchQueue(label: "camera.transcode.metadata", qos: .utility)) { [weak self] in
                self?.pumpMetadata()
            }
            if let input = box.audioInput {
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "camera.transcode.audio", qos: .utility)) { [weak self] in
                    self?.pumpAudio()
                }
            }
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func cancel() { finish(.failure(CancellationError())) }
    private var isFinished: Bool { state.withLock { $0.result != nil } }

    private func pumpVideo() {
        while !isFinished && box.videoInput.isReadyForMoreMediaData {
            let appended: Bool = autoreleasepool {
                guard let sample = box.videoOutput.copyNextSampleBuffer() else {
                    endTrack(0, input: box.videoInput)
                    return false
                }
                guard let source = CMSampleBufferGetImageBuffer(sample) else {
                    fail("video_sample_missing_image"); return false
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                let seed = FilmGrainRenderer.temporalSeed(base: box.grainBaseSeed, seconds: timestamp.seconds)
                guard let output = LivePhotoProcessor.renderFrame(source, lut: box.lut, grain: box.grain,
                    optics: box.optics, grainSeed: seed, pool: box.pixelAdaptor.pixelBufferPool) else {
                    fail("pixel_buffer_allocation"); return false
                }
                guard !isFinished, box.pixelAdaptor.append(output, withPresentationTime: timestamp) else {
                    fail("video_append"); return false
                }
                state.withLock { $0.videoFrames += 1 }
                return true
            }
            if !appended { return }
        }
    }

    private func pumpAudio() {
        guard let input = box.audioInput, let output = box.audioOutput else { return }
        while !isFinished && input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else { endTrack(1, input: input); return }
            guard input.append(sample) else { fail("audio_append"); return }
            state.withLock { $0.audioBuffers += 1 }
        }
    }

    private func pumpMetadata() {
        guard !isFinished, box.metadataInput.isReadyForMoreMediaData else { return }
        guard box.metadataAdaptor.append(box.stillGroup) else { fail("still_metadata_append"); return }
        endTrack(2, input: box.metadataInput)
    }

    private func endTrack(_ track: Int, input: AVAssetWriterInput) {
        guard !isFinished else { return }
        guard box.reader.status != .failed && box.reader.status != .cancelled else { fail("reader_failed"); return }
        input.markAsFinished()
        let shouldFinish = state.withLock { state in
            guard state.result == nil, state.finishedTracks.insert(track).inserted else { return false }
            return state.finishedTracks.count == (box.audioInput == nil ? 2 : 3)
        }
        if shouldFinish {
            box.writer.finishWriting { [weak self] in
                guard let self else { return }
                if self.box.writer.status == .completed && self.box.reader.status == .completed {
                    self.finish(.success(()))
                } else { self.fail("finish_incomplete") }
            }
        }
    }

    private func checkProgress() {
        if box.writer.status == .failed || box.reader.status == .failed { fail("codec_failed") }
        else if ProcessInfo.processInfo.systemUptime - started > 60 { fail("transcode_timeout") }
    }

    private func fail(_ reason: String) {
        let detail = box.writer.error?.localizedDescription ?? box.reader.error?.localizedDescription ?? reason
        finish(.failure(LivePhotoProcessor.ProcessError.writeFailed("\(reason): \(detail)")), reason: reason)
    }

    private func finish(_ result: Result<Void, any Error>, reason: String? = nil) {
        let completion = state.withLock { state -> (Bool, CheckedContinuation<Void, any Error>?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        guard completion.0 else { return }
        let counts = state.withLock { ($0.videoFrames, $0.audioBuffers) }
        if let reason { trace.event("live_pump_failure", "reason=\(reason) reader=\(box.reader.status.rawValue) writer=\(box.writer.status.rawValue)") }
        let status: String
        switch result {
        case .success: status = "ok"
        case .failure(let error): status = error is CancellationError ? "cancelled" : "error"
        }
        trace.event("live_pump_end", "status=\(status) duration_ms=\(Diagnostics.milliseconds(since: started)) video_frames=\(counts.0) audio_buffers=\(counts.1)")
        watchdog.cancel()
        if case .failure = result {
            box.reader.cancelReading()
            box.writer.cancelWriting()
        }
        completion.1?.resume(with: result)
    }
}
