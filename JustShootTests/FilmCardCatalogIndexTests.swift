import XCTest
import Observation
import os
@testable import JustShoot

final class FilmCardCatalogIndexTests: XCTestCase {
    @MainActor
    func testVaultBodyObservesCatalogCompletion() async {
        let library = FilmCardLibrary { [.kodakPortra400] }
        let page = FilmCardLibraryView(library: library)
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = page.body
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        await library.loadIfNeeded()

        XCTAssertEqual(library.loadState, .ready)
        XCTAssertTrue(invalidated.withLock { $0 }, "Catalog completion must invalidate the page body")
    }

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
