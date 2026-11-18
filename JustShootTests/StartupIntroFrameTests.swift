import XCTest
@testable import JustShoot

final class StartupIntroFrameTests: XCTestCase {
    func testRingClosesBeforeItExpands() throws {
        let frames = StartupIntroFrame.sequence
        XCTAssertEqual(frames.first?.trace, 0)
        XCTAssertEqual(frames.first?.expansion, 0)
        let closed = try XCTUnwrap(frames.first { $0.trace == 1 })
        let expanding = try XCTUnwrap(frames.first { $0.expansion > 0 })
        XCTAssertEqual(closed.expansion, 0)
        XCTAssertLessThan(closed.time, expanding.time)
        XCTAssertEqual(expanding.trace, 1)
    }

    func testExpandedIrisCoversEveryWindowShape() throws {
        let last = try XCTUnwrap(StartupIntroFrame.sequence.last)
        XCTAssertEqual(last.time, StartupIntroFrame.duration)
        XCTAssertEqual(last.expansion, 1)
        for size in [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956),
                     CGSize(width: 1366, height: 1024), CGSize(width: 320, height: 1200)] {
            let (outer, inner) = last.radii(in: size)
            XCTAssertEqual(inner, 0)
            XCTAssertGreaterThan(outer, hypot(size.width, size.height) / 2)
        }
    }
}
