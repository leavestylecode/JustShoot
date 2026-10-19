import XCTest
import UIKit
@testable import JustShoot

@MainActor
final class PhotoPageImageLoaderTests: XCTestCase {
    private final class Source: Sendable {
        let started = XCTestExpectation(description: "Source started")
        let state = PhotoRequestState<UIImage>()

        func image() async -> UIImage? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if state.install(continuation) { started.fulfill() }
                }
            } onCancel: { _ = self.state.cancel() }
        }
    }

    func testReadyPreviewDisplaysAndCancelsAStillPendingThumbnail() async {
        let thumbnail = Source(), preview = Source()
        var displayed: UIImage?
        var thumbnailCalls = 0
        let image = UIImage()
        let load = Task {
            await PhotoPageImageLoader.load(thumbnail: { await thumbnail.image() },
                preview: { await preview.image() }, onThumbnail: { _ in thumbnailCalls += 1 },
                onPreview: { displayed = $0 })
        }
        await fulfillment(of: [thumbnail.started, preview.started], timeout: 1)
        preview.state.finish(image)
        await load.value
        XCTAssertTrue(displayed === image)
        XCTAssertEqual(thumbnailCalls, 0)
        XCTAssertTrue(thumbnail.state.isFinished)
    }

    func testThumbnailDisplaysWhilePreviewLoadsThenPreviewReplacesIt() async {
        let thumbnail = Source(), preview = Source()
        let thumbDisplayed = expectation(description: "Thumbnail is visible")
        let small = UIImage(), large = UIImage()
        var displayed: [UIImage] = []
        let load = Task {
            await PhotoPageImageLoader.load(thumbnail: { await thumbnail.image() },
                preview: { await preview.image() }, onThumbnail: { displayed.append($0); thumbDisplayed.fulfill() },
                onPreview: { displayed.append($0) })
        }
        await fulfillment(of: [thumbnail.started, preview.started], timeout: 1)
        thumbnail.state.finish(small)
        await fulfillment(of: [thumbDisplayed], timeout: 1)
        XCTAssertEqual(displayed.count, 1)
        XCTAssertTrue(displayed.first === small)
        preview.state.finish(large)
        await load.value
        XCTAssertEqual(displayed.count, 2)
        XCTAssertTrue(displayed.last === large)
    }

    func testMissingPreviewStillWaitsForUsableThumbnailFallback() async {
        let thumbnail = Source(), preview = Source()
        var displayed: UIImage?
        let image = UIImage()
        let load = Task {
            await PhotoPageImageLoader.load(thumbnail: { await thumbnail.image() },
                preview: { await preview.image() }, onThumbnail: { displayed = $0 },
                onPreview: { _ in XCTFail("Missing preview was displayed") })
        }
        await fulfillment(of: [thumbnail.started, preview.started], timeout: 1)
        preview.state.finish(nil)
        thumbnail.state.finish(image)
        await load.value
        XCTAssertTrue(displayed === image)
    }

    func testLeavingThePageCancelsBothRequestsWithoutPublishingLateImages() async {
        let thumbnail = Source(), preview = Source()
        let load = Task {
            await PhotoPageImageLoader.load(thumbnail: { await thumbnail.image() },
                preview: { await preview.image() }, onThumbnail: { _ in XCTFail("Cancelled thumbnail displayed") },
                onPreview: { _ in XCTFail("Cancelled preview displayed") })
        }
        await fulfillment(of: [thumbnail.started, preview.started], timeout: 1)
        load.cancel()
        await load.value
        XCTAssertTrue(thumbnail.state.isFinished)
        XCTAssertTrue(preview.state.isFinished)
        XCTAssertFalse(thumbnail.state.finish(UIImage()))
        XCTAssertFalse(preview.state.finish(UIImage()))
    }
}
