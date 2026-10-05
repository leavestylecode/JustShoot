import XCTest
import SwiftData
import UIKit
import SwiftUI
@testable import JustShoot

@MainActor
final class LibraryFlowTests: XCTestCase {
    func testDeletionCannotOverlapAnActiveCaptureOrAnotherDeletion() {
        let gate = CaptureDeletionGate()
        let id = UUID(), other = UUID()
        XCTAssertFalse(gate.begin([id], active: [id]))
        XCTAssertFalse(gate.contains(id))
        XCTAssertTrue(gate.begin([id], active: []))
        XCTAssertFalse(gate.begin([id, other], active: []))
        XCTAssertFalse(gate.contains(other))
        gate.end([id])
        XCTAssertTrue(gate.begin([id], active: []))
    }

    func testRecoveryIsBlockedUntilDeletionConfirmationEnds() {
        let gate = CaptureDeletionGate()
        let id = UUID(), unrelated = UUID()
        XCTAssertTrue(gate.begin([id], active: []))
        XCTAssertTrue(gate.contains(id))
        XCTAssertFalse(gate.contains(unrelated))
        // On cancellation/failure, recovery may process the retained journal again.
        gate.end([id])
        XCTAssertFalse(gate.contains(id))
    }

    func testFailedDeletionCanRestoreARecoveryMarkerWithoutTouchingOriginalData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CaptureJournal(root: root)
        let id = UUID()
        try FileManager.default.createDirectory(at: journal.directory(for: id), withIntermediateDirectories: true)
        let original = Data([1, 2, 3])
        try original.write(to: journal.file("original.image", for: id))
        try journal.markDiscarded(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.file("discarded", for: id).path))
        try journal.undoDiscard(id)
        try journal.undoDiscard(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.file("discarded", for: id).path))
        XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: id)), original)
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testFailedLUTDeletionKeepsTheFileAndRollsBackTheIndex() throws {
        let store = try container()
        let context = store.mainContext
        let lut = CustomLUT(displayName: "Test", fileName: "test-\(UUID()).cube", iso: 200, dimension: 2)
        context.insert(lut)
        try context.save()
        let id = lut.id
        let url = lut.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("kept LUT".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CustomLUTPersistence.delete(lut, in: context, save: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CustomLUT>()).map(\.id), [id])
    }

    func testSuccessfulLUTDeletionCommitsBeforeRemovingTheFile() throws {
        let store = try container()
        let context = store.mainContext
        let lut = CustomLUT(displayName: "Test", fileName: "test-\(UUID()).cube", iso: 200, dimension: 2)
        context.insert(lut)
        try context.save()
        let url = lut.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try CustomLUTPersistence.delete(lut, in: context, save: { context in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try context.save()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<CustomLUT>()).isEmpty)
    }

    func testFallbackBecomingLiveAssetRefreshesTheSameGridItem() {
        let id = UUID(), unchanged = UUID(), added = UUID()
        let before = [id: PhotoGridItemRevision(assetID: nil, isLive: false),
                      unchanged: PhotoGridItemRevision(assetID: "old", isLive: false)]
        let after = [id: PhotoGridItemRevision(assetID: "saved", isLive: true),
                     unchanged: PhotoGridItemRevision(assetID: "old", isLive: false),
                     added: PhotoGridItemRevision(assetID: "new", isLive: false)]
        XCTAssertEqual(PhotoGridItemRevision.changedIDs(from: before, to: after), [id])
        XCTAssertTrue(PhotoGridItemRevision.changedIDs(from: after, to: after).isEmpty)
        XCTAssertTrue(PhotoGridItemRevision.changedIDs(from: after, to: [:]).isEmpty)
    }

    func testGridSnapshotRefreshesLiveStateWithoutChangingPhotoIdentity() throws {
        let photo = Photo(assetLocalIdentifier: nil, imageData: nil)
        let grid = PhotoGridView(photos: [photo], columns: 3, cornerRadius: 8,
            isSelecting: .constant(false), selectedPhotos: .constant([]), onOpen: { _ in })
        let coordinator = PhotoGridView.Coordinator(grid)
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), collectionViewLayout: SquareGridLayout())
        collection.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        coordinator.makeDataSource(for: collection)
        coordinator.apply(photos: [photo], animating: false)
        let dataSource = collection.dataSource as? UICollectionViewDiffableDataSource<Int, UUID>
        XCTAssertEqual(dataSource?.snapshot().itemIdentifiers, [photo.id])
        collection.layoutIfNeeded()
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let badge = try XCTUnwrap(cell.contentView.subviews.first { $0.accessibilityIdentifier == "photo.liveBadge" })
        XCTAssertTrue(badge.isHidden)
        photo.isLivePhoto = true
        coordinator.apply(photos: [photo], animating: false)
        collection.layoutIfNeeded()
        XCTAssertFalse(badge.isHidden)
        XCTAssertTrue(cell === collection.cellForItem(at: IndexPath(item: 0, section: 0)))
    }

    func testShareBatchesCannotDeleteEachOthersFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = ShareExportDirectory(root: root)
        let first = try exports.create().appendingPathComponent("photo.jpg")
        try Data([1]).write(to: first)
        let second = try exports.create().appendingPathComponent("photo.jpg")
        try Data([2]).write(to: second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        exports.remove(files: [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        exports.remove(files: [first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testShareCleanupDoesNotRemoveFilesOutsideItsBatchDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kept.jpg")
        try Data([1]).write(to: file)
        ShareExportDirectory(root: root.appendingPathComponent("Share")).remove(files: [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRawDataRequestUsesTheSameCancellationGateAsImages() async {
        let state = PhotoRequestState<Data>()
        let bytes = Data([1, 2, 3])
        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(state.install(continuation))
            XCTAssertFalse(state.register(123))
            XCTAssertTrue(state.finish(bytes))
            XCTAssertFalse(state.cancel().didFinish)
        }
        XCTAssertEqual(result, bytes)
    }
}
