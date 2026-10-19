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

    private func image(in cell: PhotoCell) -> UIImage? {
        (cell.contentView.subviews.first as? UIImageView)?.image
    }

    func testOffscreenCellDropsItsImageAndCanResumeWithoutReuse() async throws {
        let photo = try await preparedPhoto()
        let cell = PhotoCell(frame: .zero)
        cell.configure(photo: photo, editing: false, maxPixel: 120, cornerRadius: 8)
        XCTAssertNotNil(image(in: cell))
        cell.suspendLoading()
        XCTAssertNil(image(in: cell))
        cell.resumeLoading()
        XCTAssertNotNil(image(in: cell))
        cell.prepareForReuse()
        cell.resumeLoading()
        XCTAssertNil(image(in: cell))
        ImageLoader.shared.removeDiskCache(for: photo.id)
    }

    func testHiddenGridDoesNotLoadUntilVisibleAndReuseCannotShowThePreviousPhoto() async throws {
        let photo = try await preparedPhoto()
        let cell = PhotoCell(frame: .zero)
        cell.configure(photo: photo, editing: false, maxPixel: 120, cornerRadius: 8, isActive: false)
        XCTAssertNil(image(in: cell))
        cell.resumeLoading()
        XCTAssertNotNil(image(in: cell))
        let missing = Photo(assetLocalIdentifier: nil, imageData: nil)
        cell.configure(photo: missing, editing: false, maxPixel: 120, cornerRadius: 8)
        XCTAssertNil(image(in: cell))
        cell.suspendLoading()
        ImageLoader.shared.removeDiskCache(for: photo.id)
    }
}
