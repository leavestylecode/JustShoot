import XCTest
@testable import JustShoot

@MainActor
final class PhotoDeletionServiceTests: XCTestCase {
    private enum Failure: Error { case cancelled, index }

    @MainActor
    private final class Transaction {
        let row = UUID()
        let alias = UUID()
        var events: [String] = []
        var busy = false
        var assetError: Failure?
        var indexError: Failure?
        var cachedIDs: Set<UUID> = []

        var service: PhotoDeletionService {
            PhotoDeletionService(operations: .init(
                begin: { rows, assets in
                    XCTAssertEqual(rows, [self.row])
                    self.events.append("begin")
                    return self.busy ? nil : [self.row, self.alias]
                }, deleteAssets: { assets in
                    XCTAssertEqual(assets, ["asset"])
                    self.events.append("photos")
                    if let error = self.assetError { throw error }
                }, deleteIndex: { ids in
                    XCTAssertEqual(Set(ids), [self.row, self.alias])
                    self.events.append("index")
                    if let error = self.indexError { throw error }
                    return Set(ids)
                }, complete: { ids in
                    XCTAssertEqual(ids, [self.row, self.alias])
                    self.events.append("complete")
                }, end: { ids in
                    XCTAssertEqual(Set(ids), [self.row, self.alias])
                    self.events.append("end")
                }, removeCachedImage: { id in
                    self.cachedIDs.insert(id)
                    self.events.append("cache")
                }))
        }
    }

    func testCommitCompletesQueueAndClearsAllAliasesBeforeReleasingGate() async throws {
        let transaction = Transaction()
        let removed = try await transaction.service.delete(rowIDs: [transaction.row], assetIDs: ["asset"])
        XCTAssertEqual(removed, [transaction.row, transaction.alias])
        XCTAssertEqual(transaction.cachedIDs, [transaction.row, transaction.alias])
        XCTAssertEqual(transaction.events, ["begin", "photos", "index", "complete", "cache", "cache", "end"])
    }

    func testBusyCapturePreservesAllData() async throws {
        let transaction = Transaction()
        transaction.busy = true
        let removed = try await transaction.service.delete(rowIDs: [transaction.row], assetIDs: ["asset"])
        XCTAssertNil(removed)
        XCTAssertEqual(transaction.events, ["begin"])
    }

    func testSystemCancellationReleasesGateWithoutChangingIndexOrCache() async {
        let transaction = Transaction()
        transaction.assetError = .cancelled
        do {
            _ = try await transaction.service.delete(rowIDs: [transaction.row], assetIDs: ["asset"])
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertEqual(transaction.events, ["begin", "photos", "end"])
            XCTAssertTrue(transaction.cachedIDs.isEmpty)
        }
    }

    func testIndexFailureDoesNotCompleteRecoveryOrDiscardCaches() async {
        let transaction = Transaction()
        transaction.indexError = .index
        do {
            _ = try await transaction.service.delete(rowIDs: [transaction.row], assetIDs: ["asset"])
            XCTFail("Index failure must propagate")
        } catch {
            XCTAssertEqual(transaction.events, ["begin", "photos", "index", "end"])
            XCTAssertTrue(transaction.cachedIDs.isEmpty)
        }
    }

    func testInternalPhotoDeletionDoesNotRequestPhotosAccess() async throws {
        let transaction = Transaction()
        _ = try await transaction.service.delete(rowIDs: [transaction.row], assetIDs: [])
        XCTAssertEqual(transaction.events, ["begin", "index", "complete", "cache", "cache", "end"])
    }
}
