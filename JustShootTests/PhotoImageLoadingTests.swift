import XCTest
import UIKit
import SwiftData
import os
@testable import JustShoot

@MainActor
final class PhotoImageLoadingTests: XCTestCase {
    private final class Gate: Sendable {
        private let released = OSAllocatedUnfairLock(initialState: false)
        func wait() {
            for _ in 0..<600 {
                if released.withLock({ $0 }) { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        func open() { released.withLock { $0 = true } }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    func testColdDiskThumbnailAndPreviewWorkWithoutOriginalBytes() async throws {
        // iOS 17 requires an active container even before a model is inserted. Keep this
        // test independent of startup/storage tests that may have run earlier in the suite.
        let container = try ModelContainer(for: Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        defer { withExtendedLifetime(container) {} }
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = Photo(assetLocalIdentifier: nil, imageData: nil)
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let data = try jpeg()
        for (folder, suffix) in [("Thumbs", "t_96"), ("Previews", "p_256")] {
            let path = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try data.write(to: path.appendingPathComponent("\(photo.id.uuidString)_\(suffix).jpg"))
        }
        let loader = ImageLoader(cacheDirectory: directory)
        XCTAssertNil(loader.cachedThumbnail(for: photo.id, maxPixel: 88))
        XCTAssertNil(loader.cachedPreview(for: photo.id, maxPixel: 100))
        let thumbnail = await PhotoImage.thumbnail(for: photo, maxPixel: 88, loader: loader)
        let preview = await PhotoImage.preview(for: photo, maxPixel: 100, loader: loader)
        XCTAssertNotNil(thumbnail)
        XCTAssertNotNil(preview)
        XCTAssertTrue(loader.cachedThumbnail(for: photo.id, maxPixel: 96) === thumbnail)
        XCTAssertTrue(loader.cachedPreview(for: photo.id, maxPixel: 256) === preview)
        XCTAssertNil(photo.imageData)
    }

    func testConcurrentPhotoRequestsShareTheDecodedImage() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ImageLoader(cacheDirectory: directory)
        let data = try jpeg(), id = UUID()
        let images = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for _ in 0..<24 {
                group.addTask { await loader.loadThumbnail(imageData: data, photoId: id, maxPixel: 120) }
            }
            var result: [UIImage] = []
            for await image in group { if let image { result.append(image) } }
            return result
        }
        XCTAssertEqual(images.count, 24)
        XCTAssertTrue(images.allSatisfy { $0 === images.first })
    }

    func testCancelledConsumerReturnsWhileAnotherConsumerKeepsItsQueuedPhoto() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let gate = Gate()
        defer { gate.open() }
        let started = expectation(description: "Worker occupied")
        let occupied = Task { await worker.run { started.fulfill(); gate.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 1)
        let loader = ImageLoader(worker: worker, cacheDirectory: directory)
        let data = try jpeg(), id = UUID()
        let returned = expectation(description: "Cancelled consumer returned before worker release")
        let first = Task {
            let image = await loader.loadThumbnail(imageData: data, photoId: id, maxPixel: 120)
            XCTAssertNil(image)
            returned.fulfill()
        }
        let second = Task { await loader.loadThumbnail(imageData: data, photoId: id, maxPixel: 120) }
        first.cancel()
        await fulfillment(of: [returned], timeout: 1)
        gate.open()
        let remaining = await second.value
        XCTAssertNotNil(remaining)
        await first.value
        _ = await occupied.value
    }

    func testAbandonedQueuedPreviewDoesNotDecodeOrWriteCacheAndCanRetry() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let gate = Gate()
        defer { gate.open() }
        let started = expectation(description: "Worker occupied")
        let occupied = Task { await worker.run { started.fulfill(); gate.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 1)
        let loader = ImageLoader(worker: worker, cacheDirectory: directory)
        let data = try jpeg(), id = UUID()
        let load = Task { await loader.loadPreview(imageData: data, photoId: id, maxPixel: 256) }
        // Give the request its actor turn while the dedicated image queue remains blocked.
        for _ in 0..<20 { await Task.yield() }
        load.cancel()
        let cancelled = await load.value
        XCTAssertNil(cancelled)
        gate.open()
        _ = await occupied.value
        _ = await worker.run { 1 }
        XCTAssertNil(loader.cachedPreview(for: id, maxPixel: 256))
        let url = directory.appendingPathComponent("Previews/\(id.uuidString)_p_256.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let retry = await loader.loadPreview(imageData: data, photoId: id, maxPixel: 256)
        XCTAssertNotNil(retry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPhotoDeletedDuringDiskLookupDoesNotPublishOrReadItsOriginal() async throws {
        let container = try ModelContainer(for: Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let photo = Photo(assetLocalIdentifier: nil, imageData: try jpeg())
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let gate = Gate()
        defer { gate.open() }
        let started = expectation(description: "Worker occupied")
        let occupied = Task { await worker.run { started.fulfill(); gate.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 1)
        let loader = ImageLoader(worker: worker, cacheDirectory: directory)
        let load = Task { await PhotoImage.thumbnail(for: photo, maxPixel: 96, loader: loader) }
        for _ in 0..<20 { await Task.yield() }
        container.mainContext.delete(photo)
        // Retain the pending-deletion marker until the suspended read resumes.
        gate.open()
        let result = await load.value
        XCTAssertNil(result)
        _ = await occupied.value
        try container.mainContext.save()
    }

    func testPhotoDeletedBeforeQueuedLoadDoesNotReadDetachedOriginal() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        defer { withExtendedLifetime(container) {} }
        let photo = Photo(assetLocalIdentifier: nil, imageData: try jpeg())
        let loader = ImageLoader(cacheDirectory: directory)
        let standalone = await PhotoImage.thumbnail(for: photo, maxPixel: 96, loader: loader)
        XCTAssertNotNil(standalone)
        container.mainContext.insert(photo)
        try container.mainContext.save()
        container.mainContext.delete(photo)
        try container.mainContext.save()

        let thumbnail = await PhotoImage.thumbnail(for: photo, maxPixel: 320, loader: loader)
        let preview = await PhotoImage.preview(for: photo, maxPixel: 256, loader: loader)
        let exif = await PhotoImage.exifData(for: photo)
        XCTAssertNil(thumbnail)
        XCTAssertNil(preview)
        XCTAssertNil(exif)
    }

    func testClearingPreviewsKeepsGridThumbnailsAndPreventsLateCacheRepopulation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = BlockingImageWork(maximumConcurrentOperations: 1)
        let loader = ImageLoader(worker: worker, cacheDirectory: directory)
        let data = try jpeg(), id = UUID()
        let thumb = await loader.loadThumbnail(imageData: data, photoId: id, maxPixel: 160)
        let preview = await loader.loadPreview(imageData: data, photoId: id, maxPixel: 256)
        XCTAssertNotNil(preview)
        loader.clearPreviewCache()
        XCTAssertNil(loader.cachedPreview(for: id, maxPixel: 256))
        XCTAssertTrue(loader.cachedThumbnail(for: id, maxPixel: 160) === thumb)
        XCTAssertTrue(loader.anyCachedThumbnail(for: id) === thumb)

        let gate = Gate()
        defer { gate.open() }
        let started = expectation(description: "Worker occupied")
        let occupied = Task { await worker.run { started.fulfill(); gate.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 1)
        let load = Task { await loader.loadPreview(imageData: data, photoId: id, maxPixel: 256) }
        for _ in 0..<100 {
            if worker.diagnosticFields.contains("image_work_queued=1") { break }
            await Task.yield()
        }
        XCTAssertTrue(worker.diagnosticFields.contains("image_work_queued=1"))
        loader.clearPreviewCache()
        gate.open()
        let image = await load.value
        XCTAssertNotNil(image)
        XCTAssertNil(loader.cachedPreview(for: id, maxPixel: 256))
        _ = await occupied.value
    }
}
