import XCTest
import CoreImage
@testable import JustShoot

final class FilmImageKernelsTests: XCTestCase {
    func testCaptureWarmUpProvidesEveryEffectAndConcurrentCallersReuseThem() async throws {
        try await FilmProcessor.shared.warmUpForCapture()
        let first = try FilmImageKernels.Name.allCases.map { try XCTUnwrap(FilmImageKernels.shared[$0]) }
        let snapshots = await withTaskGroup(of: [CIColorKernel].self) { group in
            for _ in 0..<24 {
                group.addTask { FilmImageKernels.Name.allCases.compactMap { FilmImageKernels.shared[$0] } }
            }
            var snapshots: [[CIColorKernel]] = []
            for await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }
        XCTAssertEqual(first.count, 5)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.count, first.count)
            for (kernel, original) in zip(snapshot, first) { XCTAssertTrue(kernel === original) }
        }
    }
}
