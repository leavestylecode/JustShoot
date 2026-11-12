import SwiftUI
import UIKit
import XCTest
@testable import JustShoot

@MainActor
final class FilmTileLayoutTests: XCTestCase {
    private let visibilityOptions = [
        FilmTileTextVisibility(),
        FilmTileTextVisibility(showsTitle: true, showsSubtitle: false),
        FilmTileTextVisibility(showsTitle: false, showsSubtitle: true),
        FilmTileTextVisibility(showsTitle: false, showsSubtitle: false)
    ]

    func testAllFilmTextFitsOneLineOnCompactPhones() {
        for language in ["en", "zh-Hans"] {
            let locale = Locale(identifier: language)
            for visibility in visibilityOptions {
                // Include narrow/zoomed containers and every column-count transition.
                for pointWidth in 320...480 {
                    let width = CGFloat(pointWidth)
                    let columns = PageLayout.homeColumns(width: width, isRegular: false,
                        minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: visibility))
                    let tileWidth = (width - 28 - CGFloat(columns - 1) * 14) / CGFloat(columns)
                    assertFilmTextFits(width: tileWidth, locale: locale, titleSize: 11, subtitleSize: 11,
                        visibility: visibility)
                }
            }
        }
    }

    func testAllFilmTextFitsOneLineInRegularWindows() {
        for language in ["en", "zh-Hans"] {
            let locale = Locale(identifier: language)
            for visibility in visibilityOptions {
                // Cover portrait, landscape and narrower iPad windows, including
                // the transitions where an additional column becomes possible.
                for pointWidth in stride(from: 375, through: 1390, by: 5) {
                    let width = CGFloat(pointWidth)
                    let columns = PageLayout.homeColumns(width: width, isRegular: true,
                        minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: visibility))
                    let tileWidth = (width - 48 - CGFloat(columns - 1) * 14) / CGFloat(columns)
                    assertFilmTextFits(width: tileWidth, locale: locale, titleSize: 13, subtitleSize: 12,
                        visibility: visibility)
                }
            }
        }
    }

    func testHidingSubtitleRestoresCompactEnglishGrid() {
        let locale = Locale(identifier: "en")
        for width in [CGFloat(375), 393, 402, 430, 440] {
            for visibility in visibilityOptions {
                let columns = PageLayout.homeColumns(width: width, isRegular: false,
                    minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: visibility))
                XCTAssertEqual(columns, visibility.showsSubtitle ? 2 : 3)
            }
        }
    }

    func testHiddenTextDoesNotReserveTileHeight() {
        let custom = HomeCustomFilter(CustomLUT(displayName: "Custom", fileName: "test.jslut", iso: 200, dimension: 2))
        for width in [CGFloat(106), 160, 214] {
            var heights: [CGFloat] = []
            for visibility in visibilityOptions {
                let tile = FilmPresetTile(preset: .fujiRawClassicChrome, image: nil, textVisibility: visibility)
                let height = fittingHeight(tile, width: width)
                heights.append(height)
                if visibility.showsText {
                    XCTAssertGreaterThan(height, width + 8)
                } else {
                    XCTAssertEqual(height, width, accuracy: 0.5, "Cover-only tiles must remain square")
                }

                let customHeight = fittingHeight(CustomLUTTile(lut: custom, image: nil, textVisibility: visibility), width: width)
                if visibility.showsTitle {
                    XCTAssertGreaterThan(customHeight, width + 8)
                } else {
                    XCTAssertEqual(customHeight, width, accuracy: 0.5, "Custom LUTs have no subtitle to reserve")
                }
            }
            XCTAssertGreaterThan(heights[0], heights[1] + 3)
            XCTAssertGreaterThan(heights[0], heights[2] + 3)
        }
    }

    private func fittingHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.locale, Locale(identifier: "en"))
            .dynamicTypeSize(.large))
        return host.sizeThatFits(in: CGSize(width: width, height: 2000)).height
    }

    private func assertFilmTextFits(width: CGFloat, locale: Locale, titleSize: CGFloat, subtitleSize: CGFloat,
        visibility: FilmTileTextVisibility = .init(),
        file: StaticString = #filePath, line: UInt = #line) {
        for preset in FilmPreset.allCases {
            let title = preset.tileTitle
            let titleWidth = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: titleSize, weight: .semibold)]).width
            let subtitleWidth = (preset.sceneSubtitle(locale: locale) as NSString)
                .size(withAttributes: [.font: UIFont.systemFont(ofSize: subtitleSize)]).width
            if visibility.showsTitle {
                XCTAssertLessThanOrEqual(ceil(titleWidth), width, "\(locale.identifier) \(title)", file: file, line: line)
            }
            if visibility.showsSubtitle {
                XCTAssertLessThanOrEqual(ceil(subtitleWidth), width, "\(locale.identifier) \(title) scenes", file: file, line: line)
            }
        }
    }
}
