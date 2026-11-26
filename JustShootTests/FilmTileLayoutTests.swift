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
            let labels = labelWidths(locale: locale, titleSize: 11, subtitleSize: 11)
            for visibility in visibilityOptions {
                // Include narrow/zoomed containers and every column-count transition.
                for pointWidth in 320...480 {
                    let width = CGFloat(pointWidth)
                    let columns = PageLayout.homeColumns(width: width, isRegular: false,
                        minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: visibility))
                    let tileWidth = (width - 28 - CGFloat(columns - 1) * 14) / CGFloat(columns)
                    assertFilmTextFits(width: tileWidth, labels: labels, visibility: visibility)
                }
            }
        }
    }

    func testAllFilmTextFitsOneLineInRegularWindows() {
        for language in ["en", "zh-Hans"] {
            let locale = Locale(identifier: language)
            let labels = labelWidths(locale: locale, titleSize: 13, subtitleSize: 12)
            for visibility in visibilityOptions {
                // Cover portrait, landscape and narrower iPad windows, including
                // the transitions where an additional column becomes possible.
                for pointWidth in stride(from: 375, through: 1390, by: 5) {
                    let width = CGFloat(pointWidth)
                    let columns = PageLayout.homeColumns(width: width, isRegular: true,
                        minimumTileWidth: FilmTileLayout.minimumWidth(locale: locale, textVisibility: visibility))
                    let tileWidth = (width - 48 - CGFloat(columns - 1) * 14) / CGFloat(columns)
                    assertFilmTextFits(width: tileWidth, labels: labels, visibility: visibility)
                }
            }
        }
    }

    func testDetailSceneTagsFillOneRowAndBalanceTwoRowsWhenTheyFit() {
        let widths: [CGFloat] = [72, 60, 88, 64, 56]
        let host = UIHostingController(rootView: FilmSceneTagLayout {
            ForEach(widths, id: \.self) { width in
                Color.clear.frame(width: width, height: 44)
            }
        })
        // At 363 pt, all five miss fitting by one point. Three on the first row measure 232 pt.
        let cases: [(CGFloat, CGFloat, CGFloat)] = [
            (402, 402, 44), (375, 375, 44), (364, 364, 44),
            (363, 232, 90), (164, 158, 136), (90, 88, 228)
        ]
        for (width, usedWidth, height) in cases {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
            XCTAssertEqual(size.width, usedWidth, accuracy: 0.5)
            XCTAssertEqual(size.height, height, accuracy: 0.5)
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
                let tile = FilmPresetTile(preset: .fujiRawClassicChrome, textVisibility: visibility)
                let height = fittingHeight(tile, width: width)
                heights.append(height)
                if visibility.showsText {
                    XCTAssertGreaterThan(height, width + 8)
                } else {
                    XCTAssertEqual(height, width, accuracy: 0.5, "Cover-only tiles must remain square")
                }

                let customHeight = fittingHeight(CustomLUTTile(lut: custom, textVisibility: visibility), width: width)
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
            .appVisualDesign())
        return host.sizeThatFits(in: CGSize(width: width, height: 2000)).height
    }

    private struct LabelWidths {
        let name: String
        let title: CGFloat
        let subtitle: CGFloat
    }

    private func labelWidths(locale: Locale, titleSize: CGFloat, subtitleSize: CGFloat) -> [LabelWidths] {
        // Use the same SwiftUI font environment as a tile, including when the simulator uses Bold Text.
        func width(_ text: String, size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
            let renderer = ImageRenderer(content: Text(verbatim: text)
                .font(.system(size: size, weight: weight)).fixedSize()
                .environment(\.locale, locale).appVisualDesign())
            var width: CGFloat = 0
            renderer.render { size, _ in width = size.width }
            XCTAssertGreaterThan(width, 0)
            return ceil(width)
        }
        return FilmPreset.allCases.map { preset in
            LabelWidths(name: "\(locale.identifier) \(preset.tileTitle)",
                title: width(preset.tileTitle, size: titleSize, weight: .semibold),
                subtitle: width(preset.sceneSubtitles(locale: locale).compact, size: subtitleSize))
        }
    }

    private func assertFilmTextFits(width: CGFloat, labels: [LabelWidths], visibility: FilmTileTextVisibility,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for label in labels {
            if visibility.showsTitle {
                XCTAssertLessThanOrEqual(label.title, width, label.name, file: file, line: line)
            }
            if visibility.showsSubtitle {
                XCTAssertLessThanOrEqual(label.subtitle, width, "\(label.name) scenes", file: file, line: line)
            }
        }
    }
}
