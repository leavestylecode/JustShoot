import CoreImage
import Photos
import XCTest
@testable import JustShoot

final class PhotoEditTests: XCTestCase {
    func testCropUsesTopLeftAnchorsAndIntegerPixelsAtEveryRotation() throws {
        let extent = CGRect(x: -10, y: 20, width: 301, height: 200)
        var recipe = PhotoEditRecipe()
        XCTAssertEqual(recipe.crop.rect(in: extent), extent)
        recipe.crop.aspect = .square
        recipe.crop.zoom = 2
        recipe.crop.x = 1
        recipe.crop.y = 0
        XCTAssertEqual(recipe.crop.rect(in: extent), CGRect(x: 191, y: 120, width: 100, height: 100))
        recipe.crop.aspect = .original
        recipe.crop.zoom = 1
        recipe.crop.turns = 1
        let input = CIImage(color: .red).cropped(to: extent)
        let output = try PhotoEditRender(recipe, films: []).apply(to: input)
        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 200, height: 301))
    }

    func testOnlyReproducibleRecipesCanRequestTheAdjustmentBase() throws {
        var recipe = PhotoEditRecipe()
        recipe.filmID = FilmPreset.fujiC200.id
        recipe.curve = .custom(CustomFilmCurve(name: "Personal"))
        let films: [FilmSource] = [.preset(.fujiC200)]
        func adjustment(_ recipe: PhotoEditRecipe) throws -> PHAdjustmentData {
            try PhotoEditSession.Adjustment(recipe: recipe, hasCameraOriginal: false).encoded()
        }
        XCTAssertEqual(PhotoEditSession.Adjustment.decode(try adjustment(recipe), films: films)?.recipe, recipe)
        XCTAssertNil(PhotoEditSession.Adjustment.decode(try adjustment(recipe), films: []))
        recipe.crop.turns = -1
        XCTAssertNil(PhotoEditSession.Adjustment.decode(try adjustment(recipe), films: films))
        XCTAssertThrowsError(try PhotoEditRender(recipe, films: films))
    }

    func testZeroFilmIntensityKeepsInputAndTheToneCurveStillApplies() throws {
        let source = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let films = [FilmSource.preset(.ilfordHP5Plus400)]
        let context = FilmProcessor.shared.renderingContext()
        func sample(_ edit: PhotoEditRecipe) throws -> [UInt8] {
            let output = try PhotoEditRender(edit, films: films).apply(to: source)
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
                           format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
            return pixel
        }
        let original = try sample(.init())
        var edit = PhotoEditRecipe(filmID: films[0].id)
        XCTAssertNotEqual(try sample(edit), original)
        edit.intensity = 0
        XCTAssertEqual(try sample(edit), original)
        edit.curve = .preset(.matte)
        XCTAssertNotEqual(try sample(edit), original)
    }

    func testPhotosAlbumLinkUsesTheCollectionAndAssetUUIDs() throws {
        let album = UUID()
        let asset = UUID()
        let url = try XCTUnwrap(PhotoLibrary.albumURL(albumID: "\(album)/L0/040", assetID: "\(asset)/L0/001"))
        XCTAssertEqual(url.host, "album")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "uuid", value: album.uuidString),
            URLQueryItem(name: "revealassetuuid", value: asset.uuidString)
        ])
        XCTAssertNil(PhotoLibrary.albumURL(albumID: "unknown", assetID: asset.uuidString))
        XCTAssertNil(PhotoLibrary.albumURL(albumID: album.uuidString, assetID: ""))
    }

    func testPhotosSearchEncodesTheFilenameAsOneQueryValue() throws {
        let url = try XCTUnwrap(PhotoLibrary.searchURL(filename: "A & B#1.HEIC"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "searchTerm", value: "A & B#1")])
        XCTAssertNil(PhotoLibrary.searchURL(filename: ""))
    }
}
