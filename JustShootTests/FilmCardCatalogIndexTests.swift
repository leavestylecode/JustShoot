import XCTest
import os
@testable import JustShoot

final class FilmCardCatalogIndexTests: XCTestCase {
    @MainActor
    func testUnavailableCatalogCanRetryWithoutReloadingAfterSuccess() async {
        let recovered = [FilmPreset.kodakPortra400]
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let library = FilmCardLibrary {
            attempts.withLock { count in
                count += 1
                return count == 1 ? nil : recovered
            }
        }
        await library.loadIfNeeded()
        XCTAssertEqual(library.loadState, .failed)
        await library.loadIfNeeded()
        XCTAssertEqual(library.loadState, .ready)
        XCTAssertEqual(library.presets, recovered)
        await library.loadIfNeeded()
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }
}
