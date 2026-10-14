import XCTest
import CoreImage
@testable import JustShoot

final class CaptureRenderCancellationTests: XCTestCase {
    @MainActor
    func testCancellationSignalIsVisibleToOtherThreads() async {
        let signal = CaptureRenderCancellation()
        signal.cancel()
        let observed = await Task.detached {
            do { try signal.checkCancellation(); return false }
            catch { return error is CancellationError }
        }.value
        XCTAssertTrue(observed, "The detached render worker must observe cancellation")
    }

    func testCancelledRenderDoesNotReadAColdLUTOrProduceAnImage() {
        let signal = CaptureRenderCancellation()
        signal.cancel()
        let processor = FilmProcessor()
        XCTAssertNil(processor.applyLUTPreservingMetadata(imageData: Data(), lutCacheKey: "FujiC200",
            cancellation: signal))
        XCTAssertEqual(processor.cachedLUTCount, 0)
    }

    func testCancelledGraphDoesNotScheduleEffects() {
        let signal = CaptureRenderCancellation()
        signal.cancel()
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertNil(FilmImagePipeline.stages(for: input, lut: nil, chromaticGain: .one,
            optics: FilmPreset.kodakVision5219.filmOptics,
            grain: FilmPreset.kodakVision5219.renderProfile.grain, grainSeed: 1,
            cancellation: signal))
    }
}
