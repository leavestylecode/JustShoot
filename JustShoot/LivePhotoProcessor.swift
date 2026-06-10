import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import Metal
import os

// MARK: - Live Photo 视频处理器
//
// 把 AVCapture 产出的 Live Photo 配对视频（原始画面）逐帧套上当前胶片 LUT，并重写成一段带
// **content identifier** + **still-image-time** 元数据的新 .mov——这两项元数据是 Photos 把
// 「静态图 + 视频」识别为一张 Live Photo 的关键：
//   - content.identifier：与静态图 MakerApple["17"] 相同的 UUID，建立配对关系。
//   - still-image-time：标记视频时间轴上哪一帧对应静态图（长按起播/落帧的锚点），取 AVCapture
//     delegate 回调给的 photoDisplayTime。
//
// 为什么自己 reader/writer 而不用 AVAssetExportSession：export session 能带 top-level metadata，
// 但 still-image-time 是一条**定时元数据轨**，export 不保证透传；用 AVAssetWriter +
// AVAssetWriterInputMetadataAdaptor 才能精确写这条轨。逐帧 LUT 复用 FilmProcessor 已缓存的
// CubeLUT（CIColorCubeWithColorSpace，sRGB），与静态图同一套调色，长按播放与成片观感一致。
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
    let lut: CubeLUT?

    init(reader: AVAssetReader, writer: AVAssetWriter,
         videoOutput: AVAssetReaderTrackOutput, videoInput: AVAssetWriterInput,
         pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor,
         audioOutput: AVAssetReaderTrackOutput?, audioInput: AVAssetWriterInput?,
         lut: CubeLUT?) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.pixelAdaptor = pixelAdaptor
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.lut = lut
    }
}

/// prewarm 的 finishWriting 完成闭包是 @Sendable，无法直接捕获非 Sendable 的 AVAssetWriter
/// 读回 status——与 PipelineBox 同一处理手法。
private final class PrewarmWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}

enum LivePhotoProcessor {

    enum ProcessError: Error {
        case noVideoTrack
        case readerInitFailed
        case writerInitFailed
        case writeFailed(String)
    }

    // 专用 CIContext：与 FilmProcessor 一致地锁 sRGB working/output 空间，走 Metal。视频帧量大，
    // 关 cacheIntermediates 控内存。整个进程共享一个，避免每次拍摄重建。
    private static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let ciContext: CIContext = {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .cacheIntermediates: false
        ]
        if let mtl = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: mtl, options: opts)
        }
        return CIContext(options: opts)
    }()

    // MARK: - 预热
    //
    // 首张 Live Photo 后处理的冷启动成本（设备实测 9728ms，之后 450–1000ms）来自两处一次性初始化，
    // 且都撞在「首拍 GPU 最忙」的时刻（Deep Fusion + 静态图 LUT/HEIF 编码 + 预览渲染同时进行）：
    //   1. 本文件独立 CIContext 的首次 render——编译 CIColorCube 的 Metal 内核、建渲染管线；
    //   2. 首个 AVAssetWriter HEVC 会话——拉起 VideoToolbox 编码器服务。
    // 这里在启动后台把两者都预先走一遍：单帧 64×64 的 CIColorCube 渲染 + 一段 2 帧黑帧的迷你
    // HEVC .mov（写到 tmp 后即删）。与 PreviewMetalResources.warm / prepareForFirstCapture 同一
    // 思路：把一次性成本从「用户第一次按快门」挪到启动后台。幂等，已预热直接返回。
    private static let prewarmed = OSAllocatedUnfairLock(initialState: false)

    static func prewarm() async {
        let alreadyWarmed = prewarmed.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !alreadyWarmed else { return }
        let timer = Log.perf("livephoto_prewarm", logger: Log.lut)

        let width = 64, height = 64
        let bufferAttrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var srcBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, bufferAttrs, &srcBuffer)
        guard let src = srcBuffer else { return }

        // 1) CIContext 首渲染：与真实转码相同的 CIColorCubeWithColorSpace 路径（恒等 2³ 立方）。
        var identity: [Float] = []
        identity.reserveCapacity(2 * 2 * 2 * 4)
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            identity.append(contentsOf: [Float(r), Float(g), Float(b), 1])
        } } }
        let lutData = identity.withUnsafeBufferPointer { Data(buffer: $0) }
        if let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            filter.setValue(CIImage(cvPixelBuffer: src), forKey: kCIInputImageKey)
            filter.setValue(2, forKey: "inputCubeDimension")
            filter.setValue(lutData, forKey: "inputCubeData")
            filter.setValue(srgb, forKey: "inputColorSpace")
            var dstBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, bufferAttrs, &dstBuffer)
            if let out = filter.outputImage, let dst = dstBuffer {
                ciContext.render(out, to: dst, bounds: out.extent, colorSpace: srgb)
            }
        }

        // 2) 迷你 HEVC writer 会话：拉起 VideoToolbox 编码器（帧内容无所谓，直接写源 buffer）。
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("livephoto_prewarm_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        for i: CMTimeValue in 0..<2 {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(src, withPresentationTime: CMTime(value: i, timescale: 30))
        }
        input.markAsFinished()
        let box = PrewarmWriterBox(writer)
        let status: AVAssetWriter.Status = await withCheckedContinuation { cont in
            box.writer.finishWriting { cont.resume(returning: box.writer.status) }
        }
        timer.end("status=\(status.rawValue)")
    }

    /// 把 sourceURL 的视频逐帧套 LUT，写出带配对元数据的 .mov 到 outputURL。
    /// - lutCacheKey: FilmProcessor 缓存键；取不到缓存 LUT 时视频按原始画面透传（不致丢失 Live Photo）。
    /// - photoDisplayTime: AVCapture 回调的「静态帧对应时刻」；无效时落到视频中点兜底。
    /// - 返回：实际写进输出视频的 content identifier。**优先从源视频读 AVCapture 自动写入的 id**
    ///   （配对真相源），读不到才兜底生成 UUID。调用方须把这个返回值写进静态图 MakerApple["17"]，
    ///   两端 id 一致才被 Photos 识别为一张 Live Photo。
    @discardableResult
    static func process(
        sourceURL: URL,
        lutCacheKey: String,
        photoDisplayTime: CMTime,
        outputURL: URL
    ) async throws -> String {
        let timer = Log.perf("livephoto_video", logger: Log.lut)
        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessError.noVideoTrack
        }

        // 读 AVCapture 自动写入的配对 content identifier；读不到兜底生成。
        let contentIdentifier = (try? await readContentIdentifier(from: asset)) ?? UUID().uuidString
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)

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
            if reader.canAdd(out) { reader.add(out); audioReaderOutput = out }
        }

        // MARK: Writer
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov) }
        catch { throw ProcessError.writerInitFailed }

        // top-level content identifier（与静态图配对）。
        writer.metadata = [contentIdentifierMetadataItem(contentIdentifier)]

        // 视频输入：HEVC 优先，旧设备回退 H.264。保留源 preferredTransform（出片朝向）。
        let codec: AVVideoCodecType = writer.availableMediaTypes.contains(.video) ? .hevc : .h264
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
            if writer.canAdd(input) { writer.add(input); audioWriterInput = input }
        }

        // still-image-time 定时元数据轨。
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: stillImageTimeFormatDescription()
        )
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        if writer.canAdd(metadataInput) { writer.add(metadataInput) }

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
        let fps = nominalFrameRate > 1 ? nominalFrameRate : 30
        let stillDuration = CMTime(value: 1, timescale: Int32(fps.rounded()))
        let stillGroup = AVTimedMetadataGroup(
            items: [stillImageTimeMetadataItem()],
            timeRange: CMTimeRange(start: stillTime, duration: stillDuration)
        )
        metadataAdaptor.append(stillGroup)
        metadataInput.markAsFinished()

        let lut = FilmProcessor.shared.getCachedLUT(cacheKey: lutCacheKey)
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
            lut: lut
        )

        // 逐帧驱动：video 与 audio 各用一条串行队列 requestMediaDataWhenReady，两者都结束后 finishWriting。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            // 视频
            group.enter()
            let videoQueue = DispatchQueue(label: "com.leavestylecode.JustShoot.livephoto.video")
            box.videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while box.videoInput.isReadyForMoreMediaData {
                    guard box.reader.status == .reading,
                          let sample = box.videoOutput.copyNextSampleBuffer() else {
                        box.videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard let srcPixel = CMSampleBufferGetImageBuffer(sample) else { continue }

                    let outPixel = renderLUT(srcPixel, lut: box.lut, pool: box.pixelAdaptor.pixelBufferPool)
                    if let outPixel {
                        if !box.pixelAdaptor.append(outPixel, withPresentationTime: pts) {
                            // append 失败（writer 出错）：结束本轨，由 finishWriting 暴露错误。
                            box.videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            // 音频（若有）：直接 passthrough sample buffer。通过 box 访问，避免把非 Sendable 的
            // input/output 局部绑定捕获进 @Sendable 闭包。
            if box.audioInput != nil, box.audioOutput != nil {
                group.enter()
                let audioQueue = DispatchQueue(label: "com.leavestylecode.JustShoot.livephoto.audio")
                box.audioInput!.requestMediaDataWhenReady(on: audioQueue) {
                    guard let audioInput = box.audioInput, let audioOutput = box.audioOutput else {
                        group.leave(); return
                    }
                    while audioInput.isReadyForMoreMediaData {
                        guard box.reader.status == .reading,
                              let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if !audioInput.append(sample) {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                box.writer.finishWriting {
                    if box.writer.status == .completed {
                        cont.resume()
                    } else {
                        let msg = box.writer.error?.localizedDescription ?? "unknown"
                        cont.resume(throwing: ProcessError.writeFailed("finish: \(msg) reader=\(box.reader.status.rawValue)"))
                    }
                }
            }
        }

        timer.end("dims=\(width)x\(height) codec=\(codec.rawValue) audio=\(audioReaderOutput != nil) still_t=\(String(format: "%.2f", stillTime.seconds))s cid=\(contentIdentifier)")
        return contentIdentifier
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

    // MARK: - 逐帧 LUT 渲染
    //
    // srcPixel(BGRA) → CIImage → CIColorCubeWithColorSpace → 渲染进 pool 取的新 pixel buffer。
    // 每帧新建一个 CIFilter（与 FilmProcessor 一致——避免跨帧/跨线程复用同一 filter 实例的竞争）。
    private static func renderLUT(_ srcPixel: CVPixelBuffer, lut: CubeLUT?, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let srcImage = CIImage(cvPixelBuffer: srcPixel)

        let outImage: CIImage
        if let lut, let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            filter.setValue(srcImage, forKey: kCIInputImageKey)
            filter.setValue(lut.dimension, forKey: "inputCubeDimension")
            filter.setValue(lut.data, forKey: "inputCubeData")
            filter.setValue(srgb, forKey: "inputColorSpace")
            outImage = filter.outputImage ?? srcImage
        } else {
            outImage = srcImage
        }

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
