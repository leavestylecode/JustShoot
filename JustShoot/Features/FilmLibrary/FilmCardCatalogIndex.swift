import Foundation

struct FilmCardSelection: Hashable, Sendable {
    var brands: Set<String> = []
    var formats: Set<String> = []
    var colors: Set<String> = []
    var isos: Set<String> = []

    var isEmpty: Bool { brands.isEmpty && formats.isEmpty && colors.isEmpty && isos.isEmpty }
}

/// Immutable catalog metadata. Layout changes reuse these counts and buckets.
struct FilmCardCatalogIndex: Sendable {
    static let mainISOs = [50, 100, 200, 400, 800, 1600]
    static let otherKey = "__OTHER__"
    private static let mainISOSet = Set(mainISOs)

    let cards: [FilmCard]
    let brandChips: [BrandChipEntry]
    let formatChips: [BrandChipEntry]
    let isoChips: [BrandChipEntry]
    let availableColors: [String]
    private let majorBrands: Set<String>
    private let majorFormats: Set<String>
    private let searchText: [String]

    init(cards: [FilmCard], includesSmallGroups: Bool = false) {
        self.cards = cards
        searchText = cards.map { card in
            [card.brand, card.product, card.format, card.iso.map(String.init)]
                .compactMap { $0 }.joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        var brands: [String: Int] = [:]
        var formats: [String: Int] = [:]
        var colors: [String: Int] = [:]
        var isos: [Int: Int] = [:]
        for card in cards {
            if let brand = card.brand, !brand.isEmpty { brands[brand, default: 0] += 1 }
            if let format = card.format, !format.isEmpty { formats[format, default: 0] += 1 }
            if let color = card.color { colors[color, default: 0] += 1 }
            if let iso = card.iso { isos[iso, default: 0] += 1 }
        }
        let brandChips = Self.chips(counts: brands, total: cards.count, minimumCount: includesSmallGroups ? 1 : 11)
        let formatChips = Self.chips(counts: formats, total: cards.count, minimumCount: includesSmallGroups ? 1 : 11)
        self.brandChips = brandChips
        self.formatChips = formatChips
        majorBrands = Set(brandChips.map(\.key)).subtracting([Self.otherKey])
        majorFormats = Set(formatChips.map(\.key)).subtracting([Self.otherKey])
        var isoChips = Self.mainISOs.compactMap { iso -> BrandChipEntry? in
            guard let count = isos[iso], count > 0 else { return nil }
            return BrandChipEntry(key: String(iso), displayName: "ISO \(iso)", count: count)
        }
        let otherISOs = cards.count - isoChips.reduce(0) { $0 + $1.count }
        if otherISOs > 0 { isoChips.append(Self.other(count: otherISOs)) }
        self.isoChips = isoChips
        availableColors = CardColorPalette.order.filter { (colors[$0] ?? 0) >= (includesSmallGroups ? 1 : 30) }
    }

    func filtered(using selection: FilmCardSelection, query: String = "") -> [FilmCard] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        guard !selection.isEmpty || !terms.isEmpty else { return cards }
        return cards.enumerated().filter { index, card in
            guard terms.allSatisfy({ searchText[index].contains($0) }) else { return false }
            if !selection.brands.isEmpty {
                let brand = card.brand.flatMap { majorBrands.contains($0) ? $0 : nil } ?? Self.otherKey
                guard selection.brands.contains(brand) else { return false }
            }
            if !selection.formats.isEmpty {
                let format = card.format.flatMap { majorFormats.contains($0) ? $0 : nil } ?? Self.otherKey
                guard selection.formats.contains(format) else { return false }
            }
            if !selection.colors.isEmpty {
                guard let color = card.color, selection.colors.contains(color) else { return false }
            }
            if !selection.isos.isEmpty {
                let iso = card.iso.flatMap { Self.mainISOSet.contains($0) ? String($0) : nil } ?? Self.otherKey
                guard selection.isos.contains(iso) else { return false }
            }
            return true
        }.map(\.element)
    }

    private static func chips(counts: [String: Int], total: Int, minimumCount: Int) -> [BrandChipEntry] {
        var chips = counts.filter { $0.value >= minimumCount }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }.map { BrandChipEntry(key: $0.key, displayName: $0.key, count: $0.value) }
        let otherCount = total - chips.reduce(0) { $0 + $1.count }
        if otherCount > 0 { chips.append(other(count: otherCount)) }
        return chips
    }

    private static func other(count: Int) -> BrandChipEntry {
        BrandChipEntry(key: otherKey, displayName: String(localized: "Other"), count: count)
    }
}
