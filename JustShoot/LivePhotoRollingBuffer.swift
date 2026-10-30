@preconcurrency import AVFoundation
import VideoToolbox
import os

/// The viewfinder and Live movie share ordinary video samples, including the camera's zoom.
/// A serial queue owns the encoder and history. The capture delegate only admits bounded work.
final class LivePhotoRollingBuffer: @unchecked Sendable {
    struct Movie: Sendable {
        let url: URL
        let photoDisplayTime: CMTime
    }

    enum BufferError: Error { case unavailable, interrupted, timedOut, writeFailed }

    struct Statistics: Sendable {
        var encodedFrames = 0
        var droppedFrames = 0
        var maximumPendingFrames = 0
        var maximumEncodeMilliseconds: Double = 0
    }

    private struct Gate {
        var enabled = false
        var wantsAudio = false
        var epoch: UInt64 = 0
        var pendingVideo = 0
        var pendingAudio = 0
        var ready = false
        var statistics = Statistics()
    }

    private struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        var time: CMTime { CMSampleBufferGetPresentationTimeStamp(buffer) }
        var bytes: Int { CMSampleBufferGetTotalSampleSize(buffer) }
        var isKeyframe: Bool {
            let values = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]]
            return values?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        }
    }

    private struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: CMTime
        let duration: CMTime
    }

    private final class Cancellation: Sendable {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
    }

    private final class InputCompletion: Sendable {
        private let completed = OSAllocatedUnfairLock(initialState: false)
        func claim() -> Bool { completed.withLock { if $0 { return false }; $0 = true; return true } }
    }

    private struct Request {
        let time: CMTime
        let rotation: CGFloat
        let url: URL
        let audio: Bool
        let continuation: CheckedContinuation<Movie, any Error>
        var export: Task<Void, Never>?
    }

    private struct Clip: @unchecked Sendable {
        let video: [Sample]
        let audio: [Sample]
        let time: CMTime
        let rotation: CGFloat
        let url: URL
    }

    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }

    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    private let queue = DispatchQueue(label: "camera.live.buffer", qos: .userInitiated)
    private let callback = OSAllocatedUnfairLock<(@Sendable () -> Void)>(initialState: {})
    // Only queue accesses the encoder, histories and requests.
    private var encoder: VTCompressionSession?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var lastSubmittedTime = CMTime.invalid
    private var encoderRetryAfter: TimeInterval = 0
    private var encodingGeneration: UInt64 = 0
    private var video: [Sample] = []
    private var audio: [Sample] = []
    private var videoBytes = 0
    private var audioBytes = 0
    private var requests: [UUID: Request] = [:]
    private var sealed = false
    private static let historySeconds = 4.5
    private static let videoByteLimit = 12 * 1_024 * 1_024
    private static let audioByteLimit = 2 * 1_024 * 1_024

    deinit { if let encoder { VTCompressionSessionInvalidate(encoder) } }

    func onStateChanged(_ handler: @escaping @Sendable () -> Void) { callback.withLock { $0 = handler } }
    private func notifyStateChanged() { callback.withLock { $0 }() }
    var isReady: Bool { gate.withLock { $0.enabled && $0.ready } }
    var statistics: Statistics { gate.withLock { $0.statistics } }

    func setEnabled(_ enabled: Bool, audio: Bool = false) {
        let epoch = gate.withLock { state -> UInt64? in
            state.wantsAudio = enabled && audio
            guard state.enabled != enabled else { return nil }
            state.enabled = enabled
            state.epoch &+= 1
            state.pendingVideo = 0
            state.pendingAudio = 0
            state.ready = false
            if enabled { state.statistics = Statistics() }
            return state.epoch
        }
        guard let epoch else { return }
        queue.async { [self] in
            guard gate.withLock({ $0.epoch == epoch }) else { return }
            reset(cancelExports: !enabled)
        }
        notifyStateChanged()
    }

    /// Navigation/backgrounding ends recording immediately. An already exposed still can
    /// finish with the available movie instead of losing the entire dynamic resource.
    func seal() {
        let epoch = gate.withLock { state -> UInt64 in
            state.enabled = false
            state.wantsAudio = false
            state.ready = false
            state.pendingVideo = 0
            state.pendingAudio = 0
            state.epoch &+= 1
            return state.epoch
        }
        queue.async { [self] in
            guard gate.withLock({ $0.epoch == epoch }) else { return }
            encodingGeneration &+= 1
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            sealed = true
            finishReadyRequests()
            queue.asyncAfter(deadline: .now() + 8) { [self] in
                guard gate.withLock({ !$0.enabled && $0.epoch == epoch }) else { return }
                reset()
            }
        }
        notifyStateChanged()
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let epoch = gate.withLock { state -> UInt64? in
            guard state.enabled else { return nil }
            guard state.pendingVideo < 2 else { state.statistics.droppedFrames += 1; return nil }
            state.pendingVideo += 1
            state.statistics.maximumPendingFrames = max(state.statistics.maximumPendingFrames, state.pendingVideo)
            return state.epoch
        }
        guard let epoch else { return }
        let frame = Frame(buffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: CMTime(value: 1, timescale: 30))
        queue.async { [self] in encode(frame, epoch: epoch) }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        let epoch = gate.withLock { state -> UInt64? in
            guard state.enabled, state.wantsAudio, state.pendingAudio < 4 else { return nil }
            state.pendingAudio += 1
            return state.epoch
        }
        guard let epoch else { return }
        var queued = false
        defer { if !queued { finishAudioInput(epoch: epoch) } }
        guard let source = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        var copied: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: source,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 0,
            flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copied) == noErr, let copied else { return }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: copied, formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), packetDescriptions: nil,
            sampleBufferOut: &buffer) == noErr, let buffer else { return }
        let item = Sample(buffer: buffer)
        queued = true
        queue.async { [self] in
            defer { finishAudioInput(epoch: epoch) }
            guard gate.withLock({ $0.enabled && $0.wantsAudio && $0.epoch == epoch }) else { return }
            audio.append(item)
            audioBytes += item.bytes
            while !audio.isEmpty, audio[0].time.seconds < item.time.seconds - Self.historySeconds || audioBytes > Self.audioByteLimit {
                audioBytes -= audio.removeFirst().bytes
            }
        }
    }

    func movie(at time: CMTime, rotation: CGFloat, url: URL, audio: Bool) async throws -> Movie {
        let id = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.cancelled.withLock({ $0 }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard (gate.withLock({ $0.enabled && $0.ready }) || sealed), time.isNumeric, requests.count < 4 else {
                        continuation.resume(throwing: BufferError.unavailable)
                        return
                    }
                    requests[id] = Request(time: time, rotation: rotation, url: url, audio: audio,
                        continuation: continuation)
                    finishReadyRequests()
                    queue.asyncAfter(deadline: .now() + 8) { [self] in finish(id, result: .failure(BufferError.timedOut)) }
                }
            }
        } onCancel: {
            cancellation.cancelled.withLock { $0 = true }
            self.queue.async { [self] in finish(id, result: .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, result: Result<Movie, any Error>) {
        guard let request = requests.removeValue(forKey: id) else {
            if case .success(let movie) = result { try? FileManager.default.removeItem(at: movie.url) }
            return
        }
        if case .failure = result { request.export?.cancel() }
        request.continuation.resume(with: result)
    }

    private func reset(cancelExports: Bool = true) {
        sealed = false
        encodingGeneration &+= 1
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        dimensions = .init(width: 0, height: 0)
        lastSubmittedTime = .invalid
        video.removeAll(keepingCapacity: false)
        audio.removeAll(keepingCapacity: false)
        videoBytes = 0
        audioBytes = 0
        let changed = gate.withLock { state -> Bool in
            let changed = state.ready
            state.ready = false
            return changed
        }
        if changed { notifyStateChanged() }
        for id in Array(requests.keys) where cancelExports || requests[id]?.export == nil {
            finish(id, result: .failure(BufferError.interrupted))
        }
    }

    private func finishAudioInput(epoch: UInt64) {
        gate.withLock { if $0.epoch == epoch { $0.pendingAudio = max(0, $0.pendingAudio - 1) } }
    }

    private func finishInput(epoch: UInt64, started: TimeInterval? = nil) {
        gate.withLock {
            guard $0.epoch == epoch else { return }
            $0.pendingVideo = max(0, $0.pendingVideo - 1)
            if let started {
                $0.statistics.encodedFrames += 1
                $0.statistics.maximumEncodeMilliseconds = max($0.statistics.maximumEncodeMilliseconds,
                    (ProcessInfo.processInfo.systemUptime - started) * 1_000)
            }
        }
    }

    private func encode(_ frame: Frame, epoch: UInt64) {
        guard gate.withLock({ $0.enabled && $0.epoch == epoch }), frame.time.isNumeric,
              !lastSubmittedTime.isNumeric || frame.time.seconds - lastSubmittedTime.seconds >= 1 / 30.0 - 0.001 else {
            finishInput(epoch: epoch)
            return
        }
        let size = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(frame.buffer)), height: Int32(CVPixelBufferGetHeight(frame.buffer)))
        if encoder == nil || size.width != dimensions.width || size.height != dimensions.height {
            guard ProcessInfo.processInfo.systemUptime >= encoderRetryAfter else { finishInput(epoch: epoch); return }
            reset(cancelExports: false)
            dimensions = size
            let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: size.width, height: size.height,
                codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
            guard status == noErr, let encoder else {
                encoderRetryAfter = ProcessInfo.processInfo.systemUptime + 2
                finishInput(epoch: epoch)
                return
            }
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 15,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0.5,
                kVTCompressionPropertyKey_ExpectedFrameRate: 30,
                kVTCompressionPropertyKey_AverageBitRate: 8_000_000,
                kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_sRGB,
                kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ]
            guard VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary) == noErr,
                  VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr else {
                reset(cancelExports: false)
                encoderRetryAfter = ProcessInfo.processInfo.systemUptime + 2
                finishInput(epoch: epoch)
                return
            }
        }
        guard let encoder else { finishInput(epoch: epoch); return }
        lastSubmittedTime = frame.time
        let started = ProcessInfo.processInfo.systemUptime
        let generation = encodingGeneration
        let completion = InputCompletion()
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: frame.buffer, presentationTimeStamp: frame.time,
            duration: frame.duration, frameProperties: nil, infoFlagsOut: nil) { [self] status, _, sample in
                guard completion.claim() else { return }
                finishInput(epoch: epoch, started: started)
                guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
                let item = Sample(buffer: sample)
                queue.async { [self] in
                    guard gate.withLock({ $0.enabled && $0.epoch == epoch }), encodingGeneration == generation,
                          video.last.map({ $0.time < item.time }) ?? true else { return }
                    video.append(item)
                    videoBytes += item.bytes
                    while !video.isEmpty, video[0].time.seconds < item.time.seconds - Self.historySeconds || videoBytes > Self.videoByteLimit {
                        videoBytes -= video.removeFirst().bytes
                    }
                    let becameReady = gate.withLock { state -> Bool in
                        guard !state.ready, video.contains(where: \.isKeyframe) else { return false }
                        state.ready = true
                        return true
                    }
                    if becameReady { notifyStateChanged() }
                    finishReadyRequests()
                }
            }
        if status != noErr, completion.claim() { finishInput(epoch: epoch) }
    }

    private func finishReadyRequests() {
        guard let last = video.last else { return }
        for id in Array(requests.keys) {
            guard var request = requests[id], request.export == nil,
                  sealed || last.time.seconds >= request.time.seconds + LivePhotoClipWindow.postRoll else { continue }
            guard !sealed || request.time.seconds - last.time.seconds <= 0.25 else {
                finish(id, result: .failure(BufferError.unavailable))
                continue
            }
            let keys = video.indices.filter { video[$0].isKeyframe }.map { (index: $0, time: video[$0].time.seconds) }
            guard let start = LivePhotoClipWindow.start(keyframes: keys, photoTime: request.time.seconds) else {
                finish(id, result: .failure(BufferError.unavailable))
                continue
            }
            let frames = Array(video[start...].prefix { $0.time.seconds <= request.time.seconds + LivePhotoClipWindow.postRoll })
            guard let first = frames.first else { finish(id, result: .failure(BufferError.unavailable)); continue }
            let sound = request.audio ? audio.filter { $0.time >= first.time && $0.time.seconds <= request.time.seconds + LivePhotoClipWindow.postRoll } : []
            let clip = Clip(video: frames, audio: sound, time: CMTimeMinimum(request.time, last.time), rotation: request.rotation, url: request.url)
            request.export = Task.detached(priority: .utility) { [self] in
                let result: Result<Movie, any Error>
                do { result = .success(try await Self.write(clip)) }
                catch { result = .failure(error) }
                queue.async { [self] in finish(id, result: result) }
            }
            requests[id] = request
        }
    }

    private static func videoFormat(_ sample: Sample) throws -> CMVideoFormatDescription {
        guard let format = CMSampleBufferGetFormatDescription(sample.buffer) else { throw BufferError.writeFailed }
        return format
    }

    private static func write(_ clip: Clip) async throws -> Movie {
        let first = clip.video[0]
        let writer = try AVAssetWriter(outputURL: clip.url, fileType: .mov)
        let box = WriterBox(writer)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                    sourceFormatHint: CMSampleBufferGetFormatDescription(first.buffer))
                let rotation = CGAffineTransform(rotationAngle: clip.rotation * .pi / 180)
                let size = CMVideoFormatDescriptionGetDimensions(try Self.videoFormat(first))
                let bounds = CGRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)).applying(rotation)
                input.transform = rotation.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                guard writer.canAdd(input) else { throw BufferError.writeFailed }
                writer.add(input)
                var soundInput: AVAssetWriterInput?
                if let sound = clip.audio.first {
                    let value = AVAssetWriterInput(mediaType: .audio,
                        outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000],
                        sourceFormatHint: CMSampleBufferGetFormatDescription(sound.buffer))
                    guard writer.canAdd(value) else { throw BufferError.writeFailed }
                    writer.add(value)
                    soundInput = value
                }
                guard writer.startWriting() else { throw BufferError.writeFailed }
                writer.startSession(atSourceTime: first.time)
                // Feed whichever track is ready; waiting on one track while withholding
                // the other can deadlock the writer's interleaving buffers.
                var v = 0, a = 0
                var videoFinished = false, audioFinished = false
                while v < clip.video.count || a < clip.audio.count {
                    try Task.checkCancellation()
                    guard writer.status == .writing else { throw BufferError.writeFailed }
                    var advanced = false
                    if v < clip.video.count, input.isReadyForMoreMediaData {
                        guard input.append(clip.video[v].buffer) else { throw BufferError.writeFailed }
                        v += 1
                        advanced = true
                    }
                    if a < clip.audio.count, let soundInput, soundInput.isReadyForMoreMediaData {
                        guard soundInput.append(clip.audio[a].buffer) else { throw BufferError.writeFailed }
                        a += 1
                        advanced = true
                    }
                    if v == clip.video.count, !videoFinished { input.markAsFinished(); videoFinished = true }
                    if a == clip.audio.count, let soundInput, !audioFinished { soundInput.markAsFinished(); audioFinished = true }
                    if !advanced { try await Task.sleep(for: .milliseconds(2)) }
                }
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw BufferError.writeFailed }
                return Movie(url: clip.url, photoDisplayTime: CMTimeSubtract(clip.time, first.time))
            } onCancel: { box.writer.cancelWriting() }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: clip.url)
            throw error
        }
    }
}

/// Starting on a preceding keyframe keeps compressed samples independently decodable.
/// A short history at cold start is valid, but it must contain the still-photo instant.
enum LivePhotoClipWindow {
    static let postRoll: Double = 1.5

    static func start(keyframes: [(index: Int, time: Double)], photoTime: Double) -> Int? {
        guard photoTime.isFinite else { return nil }
        let preceding = keyframes.filter { $0.time.isFinite && $0.time <= photoTime }
        return (preceding.last { $0.time <= photoTime - 1.5 } ?? preceding.first)?.index
    }
}
