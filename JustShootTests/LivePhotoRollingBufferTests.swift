import XCTest
import AVFoundation
@testable import JustShoot

final class LivePhotoRollingBufferTests: XCTestCase {
    func testWindowBeginsOnKeyframeBeforePreRoll() {
        let keys = [(index: 0, time: 10.0), (index: 15, time: 10.5), (index: 30, time: 11.0), (index: 45, time: 11.5)]
        XCTAssertEqual(LivePhotoClipWindow.start(keyframes: keys, photoTime: 12.7), 30)
    }

    func testColdStartUsesShorterHistoryContainingThePhotoInstant() {
        let keys = [(index: 0, time: 10.0), (index: 15, time: 10.5)]
        XCTAssertEqual(LivePhotoClipWindow.start(keyframes: keys, photoTime: 10.6), 0)
        XCTAssertNil(LivePhotoClipWindow.start(keyframes: keys, photoTime: 9.9))
        XCTAssertNil(LivePhotoClipWindow.start(keyframes: keys, photoTime: .nan))
    }

    func testUnstartedBufferRejectsMovieRequest() async throws {
        let buffer = LivePhotoRollingBuffer()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).mov")
        do {
            _ = try await buffer.movie(at: .zero, rotation: 90, url: url, audio: false)
            XCTFail("An unavailable buffer must not wait or write a partial movie")
        } catch LivePhotoRollingBuffer.BufferError.unavailable { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancellationBeforeRegistrationDoesNotWaitForTimeout() async throws {
        let buffer = LivePhotoRollingBuffer()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).mov")
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await buffer.movie(at: .zero, rotation: 90, url: url, audio: false)
        }
        do { _ = try await request.value; XCTFail("Cancelled request should fail") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHardwareBufferWritesTimedRotatedMovieWithAudio() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The production buffer requires the device hardware encoder")
        #else
        let buffer = LivePhotoRollingBuffer()
        buffer.setEnabled(true, audio: true)
        defer { buffer.setEnabled(false) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        var movie: Task<LivePhotoRollingBuffer.Movie, any Error>?
        for index in 0..<115 {
            let time = CMTime(value: 3_000 + Int64(index), timescale: 30)
            buffer.appendVideo(try Self.videoSample(at: time))
            buffer.appendAudio(try Self.audioSample(at: time))
            if index == 60 {
                XCTAssertTrue(buffer.isReady)
                movie = Task { try await buffer.movie(at: time, rotation: 90, url: url, audio: true) }
            }
            try await Task.sleep(for: .milliseconds(36))
        }
        let task = try XCTUnwrap(movie)
        let result = try await task.value
        let asset = AVURLAsset(url: result.url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 2.9)
        XCTAssertLessThan(duration, 3.6)
        XCTAssertGreaterThan(result.photoDisplayTime.seconds, 1.3)
        XCTAssertLessThan(result.photoDisplayTime.seconds, 2.1)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
        let transform = try await video.load(.preferredTransform)
        XCTAssertEqual(transform.b, 1, accuracy: 0.001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.001)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audios.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: result.photoDisplayTime).image
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 320)
        XCTAssertLessThanOrEqual(buffer.statistics.maximumPendingFrames, 2)
        #endif
    }

    func testWaitingHardwareRequestCancelsAndDisableInterruptsAnotherRequest() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The production buffer requires the device hardware encoder")
        #else
        let buffer = LivePhotoRollingBuffer()
        buffer.setEnabled(true)
        defer { buffer.setEnabled(false) }
        for index in 0..<10 {
            buffer.appendVideo(try Self.videoSample(at: CMTime(value: 3_000 + Int64(index), timescale: 30)))
            try await Task.sleep(for: .milliseconds(36))
        }
        XCTAssertTrue(buffer.isReady)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).mov")
        let waiting = Task { try await buffer.movie(at: CMTime(seconds: 102, preferredTimescale: 30), rotation: 90, url: url, audio: false) }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled request must complete") }
        catch is CancellationError { }
        let interrupted = Task { try await buffer.movie(at: CMTime(seconds: 102, preferredTimescale: 30), rotation: 90, url: url, audio: false) }
        try await Task.sleep(for: .milliseconds(30))
        buffer.setEnabled(false)
        do { _ = try await interrupted.value; XCTFail("Disable must release waiting requests") }
        catch LivePhotoRollingBuffer.BufferError.interrupted { }
        XCTAssertFalse(buffer.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        #endif
    }

    func testSealFinishesAlreadyRequestedAndLateStillMovies() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The production buffer requires the device hardware encoder")
        #else
        let buffer = LivePhotoRollingBuffer()
        buffer.setEnabled(true)
        defer { buffer.setEnabled(false) }
        for index in 0..<45 {
            buffer.appendVideo(try Self.videoSample(at: CMTime(value: 3_000 + Int64(index), timescale: 30)))
            try await Task.sleep(for: .milliseconds(36))
        }
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-\(UUID()).mov")
        let lateURL = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID()).mov")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: lateURL)
        }
        let time = CMTime(value: 3_040, timescale: 30)
        let pending = Task { try await buffer.movie(at: time, rotation: 0, url: firstURL, audio: false) }
        try await Task.sleep(for: .milliseconds(30))
        buffer.seal()
        XCTAssertFalse(buffer.isReady)
        let first = try await pending.value
        let late = try await buffer.movie(at: time, rotation: 0, url: lateURL, audio: false)
        for movie in [first, late] {
            let duration = try await AVURLAsset(url: movie.url).load(.duration).seconds
            XCTAssertGreaterThan(duration, 1)
            XCTAssertLessThan(duration, 2)
            XCTAssertGreaterThan(movie.photoDisplayTime.seconds, 0)
            XCTAssertLessThan(movie.photoDisplayTime.seconds, duration)
        }
        #endif
    }

    private static func videoSample(at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        FilmVideoColorSpace.tag(buffer)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private static func audioSample(at time: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 3_200, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 3_200, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: 3_200), noErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: data, formatDescription: try XCTUnwrap(format), sampleCount: 1_600,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

}
