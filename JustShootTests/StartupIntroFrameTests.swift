import XCTest
@testable import JustShoot

final class StartupIntroFrameTests: XCTestCase {
    func testRingClosesBeforeItExpands() {
        let size = CGSize(width: 390, height: 844)
        let start = StartupIntroFrame(elapsed: 0)
        let drawing = StartupIntroFrame(elapsed: 0.30)
        let closed = StartupIntroFrame(elapsed: 0.65)
        let expanding = StartupIntroFrame(elapsed: 0.90)

        XCTAssertEqual(start.trace, 0)
        XCTAssertGreaterThan(drawing.trace, 0)
        XCTAssertLessThan(drawing.trace, 1)
        XCTAssertEqual(closed.trace, 1)
        XCTAssertEqual(closed.expansion, 0)
        XCTAssertGreaterThan(expanding.radii(in: size).outer, closed.radii(in: size).outer)
        XCTAssertLessThan(expanding.radii(in: size).inner, closed.radii(in: size).inner)
    }

    func testFinalWordmarkHasAnUnbrokenBackgroundInEveryWindowShape() {
        let last = StartupIntroFrame(elapsed: StartupIntroFrame.duration)
        XCTAssertEqual(last.expansion, 1)
        for size in [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956),
                     CGSize(width: 1366, height: 1024), CGSize(width: 320, height: 1200)] {
            let (outer, inner) = last.radii(in: size)
            XCTAssertEqual(inner, 0)
            XCTAssertGreaterThan(outer, hypot(size.width, size.height) / 2)
        }
    }

    @MainActor
    func testWordmarkLandsOneLetterPerBeat() async throws {
        var beats: [StartupLetterBeat] = []
        let clock = ContinuousClock()
        let start = clock.now
        try await StartupLetterBeat.play { beats.append($0) }

        XCTAssertEqual(AppBrand.wordmark, "OOO")
        XCTAssertEqual(beats.map(\.lettersShown), Array(1...AppBrand.wordmark.count))
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(545))
        XCTAssertTrue(beats.allSatisfy { (0.8...1).contains($0.intensity) })
        XCTAssertEqual(beats.last?.intensity, 1)
    }

    @MainActor
    func testLeavingTheIntroCancelsRemainingBeats() async {
        var lettersShown: [Int] = []
        let playback = Task {
            try await StartupLetterBeat.play { beat in
                lettersShown.append(beat.lettersShown)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            try await playback.value
            XCTFail("The remaining beats should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(lettersShown, [1])
    }
}
