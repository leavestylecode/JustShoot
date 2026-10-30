import XCTest
@testable import JustShoot

final class FilmCardCatalogIndexTests: XCTestCase {
    private func card(_ id: String, brand: String? = nil, format: String? = nil,
                      iso: Int? = nil, color: String? = nil) -> FilmCard {
        FilmCard(id: id, image: "\(id).heic", brand: brand, product: nil, format: format,
                 iso: iso, process: nil, expiry: nil, type: nil, subtype: nil,
                 quantity: nil, notes: nil, author: nil, color: color)
    }

    func testMissingAndEmptyMetadataRemainReachableInOtherBuckets() {
        let cards = [card("missing"), card("empty", brand: "", format: ""),
                     card("rare", brand: "Rare", format: "110", iso: 320)]
        let index = FilmCardCatalogIndex(cards: cards)
        XCTAssertEqual(index.brandChips.map(\.count), [3])
        XCTAssertEqual(index.formatChips.map(\.count), [3])
        XCTAssertEqual(index.isoChips.map(\.count), [3])
        let selection = FilmCardSelection(brands: [FilmCardCatalogIndex.otherKey],
            formats: [FilmCardCatalogIndex.otherKey], isos: [FilmCardCatalogIndex.otherKey])
        XCTAssertEqual(index.filtered(using: selection).map(\.id), cards.map(\.id))
    }

    func testMajorThresholdsAndChipTotalsPreserveEveryCard() {
        let cards = (0..<11).map { card("major-\($0)", brand: "Major", format: "135", iso: 400) }
            + (0..<10).map { card("minor-\($0)", brand: "Minor", format: "120", iso: 320) }
        let index = FilmCardCatalogIndex(cards: cards)
        XCTAssertEqual(index.brandChips.map(\.key), ["Major", FilmCardCatalogIndex.otherKey])
        XCTAssertEqual(index.formatChips.map(\.key), ["135", FilmCardCatalogIndex.otherKey])
        XCTAssertEqual(index.isoChips.map(\.key), ["400", FilmCardCatalogIndex.otherKey])
        for chips in [index.brandChips, index.formatChips, index.isoChips] {
            XCTAssertEqual(chips.reduce(0) { $0 + $1.count }, cards.count)
        }
    }

    func testCombinedFiltersIntersectDimensionsAndKeepCatalogOrder() {
        let cards = (0..<32).map { i in
            card(String(i), brand: i.isMultiple(of: 2) ? "A" : "B",
                 format: i < 16 ? "135" : "120", iso: i.isMultiple(of: 4) ? 100 : 400,
                 color: i.isMultiple(of: 3) ? "red" : "blue")
        }
        let index = FilmCardCatalogIndex(cards: cards)
        let selection = FilmCardSelection(brands: ["A", "B"], formats: ["135"], colors: ["red"], isos: ["400"])
        XCTAssertEqual(index.filtered(using: selection).map(\.id), ["3", "6", "9", "15"])
        XCTAssertEqual(index.filtered(using: FilmCardSelection()).map(\.id), cards.map(\.id))
        XCTAssertTrue(index.filtered(using: FilmCardSelection(colors: ["green"])).isEmpty)
    }

    func testColorThresholdAndDisplayOrderAreStable() {
        let cards = (0..<30).map { card("blue-\($0)", color: "blue") }
            + (0..<30).map { card("red-\($0)", color: "red") }
            + (0..<29).map { card("green-\($0)", color: "green") }
        XCTAssertEqual(FilmCardCatalogIndex(cards: cards).availableColors, ["red", "blue"])
    }

    func testSearchNormalizesCaseAccentsAndWhitespaceWhileIntersectingFilters() {
        let cards = [card("a", brand: "Café", format: "135", iso: 400, color: "red"),
                     card("b", brand: "CAFE", format: "120", iso: 100, color: "blue")]
        let index = FilmCardCatalogIndex(cards: cards)
        XCTAssertEqual(index.filtered(using: .init(), query: "  cafe  ").map(\.id), ["a", "b"])
        XCTAssertEqual(index.filtered(using: .init(), query: "CAFE 400").map(\.id), ["a"])
        XCTAssertEqual(index.filtered(using: .init(colors: ["blue"]), query: "cafe").map(\.id), ["b"])
        XCTAssertEqual(index.filtered(using: .init(), query: " \n ").map(\.id), ["a", "b"])
        XCTAssertTrue(index.filtered(using: .init(), query: "unknown").isEmpty)
    }

    func testSearchIncludesProductNameAndKeepsCatalogOrder() {
        let first = FilmCard(id: "first", image: "first.heic", brand: "Kodak", product: "Portra 400",
            format: "135", iso: 400, process: nil, expiry: nil, type: nil, subtype: nil,
            quantity: nil, notes: nil, author: nil, color: nil)
        let index = FilmCardCatalogIndex(cards: [first, card("other", brand: "Kodak")])
        XCTAssertEqual(index.filtered(using: .init(), query: "portra kodak").map(\.id), ["first"])
    }
}
