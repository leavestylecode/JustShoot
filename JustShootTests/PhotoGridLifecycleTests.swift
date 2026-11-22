import XCTest
import UIKit
@testable import JustShoot

@MainActor
final class PhotoGridLifecycleTests: XCTestCase {
    private func preparedPhoto() async throws -> Photo {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }.jpegData(compressionQuality: 0.9))
        let photo = Photo(assetLocalIdentifier: nil, imageData: data)
        let image = await ImageLoader.shared.loadThumbnail(imageData: data, photoId: photo.id, maxPixel: 120)
        XCTAssertNotNil(image)
        return photo
    }

    func testOffscreenCellDropsItsImageAndCanResumeWithoutReuse() async throws {
        let photo = try await preparedPhoto()
        let cell = PhotoCell(frame: .zero)
        cell.configure(photo: photo, editing: false, maxPixel: 120)
        XCTAssertNotNil(cell.transitionImage)
        cell.suspendLoading()
        XCTAssertNil(cell.transitionImage)
        cell.resumeLoading()
        XCTAssertNotNil(cell.transitionImage)
        cell.prepareForReuse()
        cell.resumeLoading()
        XCTAssertNil(cell.transitionImage)
        ImageLoader.shared.removeDiskCache(for: photo.id)
    }

    func testHiddenGridDoesNotLoadUntilVisibleAndReuseCannotShowThePreviousPhoto() async throws {
        let photo = try await preparedPhoto()
        let cell = PhotoCell(frame: .zero)
        cell.configure(photo: photo, editing: false, maxPixel: 120, isActive: false)
        XCTAssertNil(cell.transitionImage)
        cell.resumeLoading()
        XCTAssertNotNil(cell.transitionImage)
        let missing = Photo(assetLocalIdentifier: nil, imageData: nil)
        cell.configure(photo: missing, editing: false, maxPixel: 120)
        XCTAssertNil(cell.transitionImage)
        cell.suspendLoading()
        ImageLoader.shared.removeDiskCache(for: photo.id)
    }

    func testZoomKeepsTheCurrentThumbnailWhileLoadingASharperOne() async throws {
        let photo = try await preparedPhoto()
        defer { ImageLoader.shared.removeDiskCache(for: photo.id) }
        let cell = PhotoCell(frame: .zero)
        cell.configure(photo: photo, editing: false, maxPixel: 120)
        let initial = try XCTUnwrap(cell.transitionImage)
        cell.setThumbnailSize(192)
        XCTAssertTrue(cell.transitionImage === initial)

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while cell.transitionImage === initial, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let enlarged = try XCTUnwrap(cell.transitionImage)
        XCTAssertEqual(enlarged.cgImage?.width, 192)
        cell.setThumbnailSize(120)
        XCTAssertTrue(cell.transitionImage === enlarged)
    }
}
