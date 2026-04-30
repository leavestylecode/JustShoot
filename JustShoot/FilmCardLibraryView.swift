import SwiftUI
import UIKit

// MARK: - Color palette (matches the bucket names emitted by the offline script)

enum CardColorPalette {
    /// Display order: warm → cool → neutral
    static let order: [String] = [
        "red", "orange", "yellow", "green", "blue", "purple", "brown", "black", "white", "gray"
    ]

    /// Localized name for accessibility. Each case returns a `LocalizedStringKey`
    /// literal so Xcode's catalog can extract them.
    static func localizedName(_ key: String) -> LocalizedStringKey {
        switch key {
        case "red":    return "Red"
        case "orange": return "Orange"
        case "yellow": return "Yellow"
        case "green":  return "Green"
        case "blue":   return "Blue"
        case "purple": return "Purple"
        case "brown":  return "Brown"
        case "black":  return "Black"
        case "white":  return "White"
        case "gray":   return "Gray"
        default:       return ""
        }
    }

    static func swatch(_ key: String) -> Color {
        switch key {
        case "red": return Color(red: 0.95, green: 0.27, blue: 0.27)
        case "orange": return Color(red: 0.97, green: 0.58, blue: 0.20)
        case "yellow": return Color(red: 0.99, green: 0.83, blue: 0.20)
        case "green": return Color(red: 0.30, green: 0.75, blue: 0.40)
        case "blue": return Color(red: 0.25, green: 0.55, blue: 0.95)
        case "purple": return Color(red: 0.65, green: 0.40, blue: 0.85)
        case "brown": return Color(red: 0.55, green: 0.38, blue: 0.25)
        case "black": return Color(red: 0.10, green: 0.10, blue: 0.10)
        case "white": return Color(red: 0.95, green: 0.95, blue: 0.95)
        case "gray": return Color(red: 0.55, green: 0.55, blue: 0.55)
        default: return Color.gray
        }
    }
}

// MARK: - Library main view

struct FilmCardLibraryView: View {
    @State private var library = FilmCardLibrary.shared
    /// Brand selection. Contains specific brand names, or `otherKey` for "Other (small brands)".
    @State private var selectedBrands: Set<String> = []
    @State private var selectedFormats: Set<String> = []
    @State private var selectedColors: Set<String> = []
    /// ISO selection. Contains stringified main ISO values ("50"/"100"/…) or `otherKey` for "Other".
    @State private var selectedISOs: Set<String> = []
    @State private var showFilterSheet = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    /// Brand / format threshold: count > 10 gets its own chip, the rest go into "Other".
    private static let majorBrandThreshold = 10
    private static let majorFormatThreshold = 10
    /// Main ISO list (covers ~73%). Other ISOs and missing ISOs all go into "Other".
    static let mainISOs: [Int] = [50, 100, 200, 400, 800, 1600]
    /// Color threshold: only render chips with count >= 30. Rare buckets (purple / brown)
    /// don't make it into the filter UI.
    private static let majorColorThreshold = 30
    /// Sentinel string used as the "Other" bucket key. No real brand / format / ISO collides with this.
    static let otherKey = "__OTHER__"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(filteredCards) { card in
                    NavigationLink(value: card) {
                        FilmCardThumbnail(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.black)
        .navigationTitle(Text("Film Library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 17, weight: hasActiveFilter ? .semibold : .medium))
                        .foregroundStyle(hasActiveFilter ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel(hasActiveFilter ? Text("Filter (active)") : Text("Filter"))
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilmCardFilterSheet(
                brandChips: brandChips,
                formatChips: formatChips,
                availableColors: availableColors,
                isoChips: isoChips,
                resultCount: filteredCards.count,
                selectedBrands: $selectedBrands,
                selectedFormats: $selectedFormats,
                selectedColors: $selectedColors,
                selectedISOs: $selectedISOs
            )
            .presentationDetents([.medium])
        }
        .navigationDestination(for: FilmCard.self) { card in
            FilmCardDetailView(card: card)
        }
        .task {
            await library.loadIfNeeded()
        }
        .overlay {
            if !library.isLoaded {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else if filteredCards.isEmpty {
                ContentUnavailableView {
                    Label("No matches", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text("Try adjusting the filters")
                }
                .foregroundColor(.white.opacity(0.6))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Filter computation

    private var filteredCards: [FilmCard] {
        guard library.isLoaded else { return [] }
        let brands = selectedBrands
        let formats = selectedFormats
        let colors = selectedColors
        let isos = selectedISOs
        let majorBrands = majorBrandSet
        let majorFormats = majorFormatSet
        let mainISOSet = Set(Self.mainISOs)

        return library.all.filter { card in
            if !brands.isEmpty {
                if !brandMatches(card, selected: brands, majors: majorBrands) { return false }
            }
            if !formats.isEmpty {
                if !formatMatches(card, selected: formats, majors: majorFormats) { return false }
            }
            if !colors.isEmpty {
                guard let c = card.color, colors.contains(c) else { return false }
            }
            if !isos.isEmpty {
                if !isoMatches(card, selected: isos, mainISOSet: mainISOSet) { return false }
            }
            return true
        }
    }

    private func brandMatches(_ card: FilmCard, selected: Set<String>, majors: Set<String>) -> Bool {
        if let b = card.brand, majors.contains(b) {
            return selected.contains(b)
        }
        // Small brand or no brand → check if "Other" is selected
        return selected.contains(Self.otherKey)
    }

    private func formatMatches(_ card: FilmCard, selected: Set<String>, majors: Set<String>) -> Bool {
        if let f = card.format, majors.contains(f) {
            return selected.contains(f)
        }
        // Non-major or missing format → check if "Other" is selected
        return selected.contains(Self.otherKey)
    }

    private func isoMatches(_ card: FilmCard, selected: Set<String>, mainISOSet: Set<Int>) -> Bool {
        if let iso = card.iso, mainISOSet.contains(iso) {
            return selected.contains(String(iso))
        }
        // Long-tail ISO or missing ISO → check if "Other" is selected
        return selected.contains(Self.otherKey)
    }

    /// Major brand set (count > threshold)
    private var majorBrandSet: Set<String> {
        Set(library.sortedBrands.filter { (library.byBrand[$0]?.count ?? 0) > Self.majorBrandThreshold })
    }

    /// Major format set (count > threshold)
    private var majorFormatSet: Set<String> {
        var counts: [String: Int] = [:]
        for c in library.all {
            if let f = c.format { counts[f, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value > Self.majorFormatThreshold }.keys)
    }

    /// Brand chip rendering data: majors descending by count, then a single "Other" rollup.
    private var brandChips: [BrandChipEntry] {
        var majors: [BrandChipEntry] = []
        var otherTotal = 0
        for brand in library.sortedBrands {
            let count = library.byBrand[brand]?.count ?? 0
            if count > Self.majorBrandThreshold {
                majors.append(BrandChipEntry(key: brand, displayName: brand, count: count))
            } else {
                otherTotal += count
            }
        }
        // Cards without a brand also fold into "Other"
        let untagged = library.all.filter { $0.brand == nil }.count
        otherTotal += untagged
        if otherTotal > 0 {
            let other = String(localized: "Other")
            majors.append(BrandChipEntry(key: Self.otherKey, displayName: other, count: otherTotal))
        }
        return majors
    }

    /// ISO chip list: fixed main-ISO order followed by an "Other" rollup.
    private var isoChips: [BrandChipEntry] {
        guard library.isLoaded else { return [] }
        var counts: [Int: Int] = [:]
        var otherTotal = 0
        let mainSet = Set(Self.mainISOs)
        for card in library.all {
            if let iso = card.iso, mainSet.contains(iso) {
                counts[iso, default: 0] += 1
            } else {
                otherTotal += 1
            }
        }
        var entries: [BrandChipEntry] = Self.mainISOs.compactMap { iso in
            let n = counts[iso] ?? 0
            // "ISO 100" is universal — leave verbatim regardless of locale.
            return n > 0 ? BrandChipEntry(key: String(iso), displayName: "ISO \(iso)", count: n) : nil
        }
        if otherTotal > 0 {
            let other = String(localized: "Other")
            entries.append(BrandChipEntry(key: Self.otherKey, displayName: other, count: otherTotal))
        }
        return entries
    }

    /// Format chip rendering data: count > threshold descending by count, then "Other".
    private var formatChips: [BrandChipEntry] {
        var counts: [String: Int] = [:]
        var untagged = 0
        for card in library.all {
            if let f = card.format { counts[f, default: 0] += 1 }
            else { untagged += 1 }
        }
        let majors = counts
            .filter { $0.value > Self.majorFormatThreshold }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { BrandChipEntry(key: $0.key, displayName: $0.key, count: $0.value) }

        let majorKeys = Set(majors.map { $0.key })
        let otherTotal = counts.filter { !majorKeys.contains($0.key) }.values.reduce(0, +) + untagged
        if otherTotal > 0 {
            let other = String(localized: "Other")
            return majors + [BrandChipEntry(key: Self.otherKey, displayName: other, count: otherTotal)]
        }
        return majors
    }

    /// Show only mainstream colors (count >= threshold), in palette order. Rare buckets
    /// (purple / brown) are dropped.
    private var availableColors: [String] {
        var counts: [String: Int] = [:]
        for card in library.all {
            if let c = card.color { counts[c, default: 0] += 1 }
        }
        return CardColorPalette.order.filter { (counts[$0] ?? 0) >= Self.majorColorThreshold }
    }

    private var hasActiveFilter: Bool {
        !selectedBrands.isEmpty
            || !selectedFormats.isEmpty
            || !selectedColors.isEmpty
            || !selectedISOs.isEmpty
    }
}

/// Data for a "name + count + Other" style chip used by brand / format / ISO sections.
struct BrandChipEntry: Hashable {
    let key: String
    let displayName: String
    let count: Int
}

// MARK: - Thumbnail cell

struct FilmCardThumbnail: View {
    let card: FilmCard
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                // Product names are proper nouns from source data — render verbatim.
                // Fall back to the localized "Unknown" string when product is missing.
                Group {
                    if let product = card.product, !product.isEmpty {
                        Text(verbatim: product)
                    } else {
                        Text("Unknown")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

                HStack(spacing: 4) {
                    if let iso = card.iso {
                        Text(verbatim: "ISO \(iso)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    if let format = card.format {
                        Text(verbatim: format)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: card.id) {
            // Grid cell ~120pt; multiply by display scale, floor at 300 to
            // satisfy the thumbnail API's minimum.
            let pixel = max(Int(120.0 * displayScale), 300)
            image = await FilmCardLibrary.shared.image(for: card, maxPixel: pixel)
        }
    }
}

// MARK: - Detail view

struct FilmCardDetailView: View {
    let card: FilmCard
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                glassImageCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 14) {
                    if let brand = card.brand, !brand.isEmpty {
                        Text(verbatim: brand)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                    if let product = card.product, !product.isEmpty {
                        Text(verbatim: product)
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                    }

                    Divider().background(Color.white.opacity(0.08))

                    metaRow("Format", value: card.format)
                    metaRow("ISO", value: card.iso.map { "\($0)" })
                    metaRow("Process", value: card.process)
                    metaRow("Exposures", value: card.quantity)
                    metaRow("Subtype", value: card.subtype)
                    metaRow("Notes", value: card.notes)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                principalTitle
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .task {
            image = await FilmCardLibrary.shared.image(for: card, maxPixel: 1024)
        }
    }

    @ViewBuilder
    private var principalTitle: some View {
        if let product = card.product, !product.isEmpty {
            Text(verbatim: product)
        } else if let brand = card.brand, !brand.isEmpty {
            Text(verbatim: brand)
        } else {
            Text("Film Card")
        }
    }

    /// Rounded image with `glassEffect` overlaid on the same shape so the
    /// material aligns with the image edge.
    private var glassImageCard: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white.opacity(0.05)
                    .overlay(ProgressView().tint(.white).scaleEffect(0.9))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
    }

    @ViewBuilder
    private func metaRow(_ label: LocalizedStringKey, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 76, alignment: .leading)
                Text(verbatim: value)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Filter sheet

struct FilmCardFilterSheet: View {
    let brandChips: [BrandChipEntry]
    let formatChips: [BrandChipEntry]
    let availableColors: [String]
    let isoChips: [BrandChipEntry]
    /// Live result count from the parent. Updates as bindings change because the parent
    /// re-renders the sheet content view on each state change.
    let resultCount: Int
    @Binding var selectedBrands: Set<String>
    @Binding var selectedFormats: Set<String>
    @Binding var selectedColors: Set<String>
    @Binding var selectedISOs: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    countedChipSection(title: "Brand", chips: brandChips, selection: $selectedBrands)
                    countedChipSection(title: "Format", chips: formatChips, selection: $selectedFormats)
                    colorSection
                    countedChipSection(title: "ISO", chips: isoChips, selection: $selectedISOs)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(Text("Filter · \(resultCount)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset", action: reset)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }

    /// Renders one of the "name + count + Other" chip sections (brand / format / ISO).
    @ViewBuilder
    private func countedChipSection(title: LocalizedStringKey, chips: [BrandChipEntry], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(chips, id: \.key) { entry in
                    let isOn = selection.wrappedValue.contains(entry.key)
                    Button {
                        if isOn { selection.wrappedValue.remove(entry.key) }
                        else { selection.wrappedValue.insert(entry.key) }
                    } label: {
                        BrandCountChipLabel(brand: entry.displayName, count: entry.count, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    // Verbatim avoids forcing the catalog to carry a key whose only
                    // content is format specifiers (Xcode can't derive a symbol).
                    .accessibilityLabel(Text(verbatim: "\(entry.displayName), \(entry.count)"))
                }
            }
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.headline)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(availableColors, id: \.self) { key in
                    let isOn = selectedColors.contains(key)
                    Button {
                        if isOn { selectedColors.remove(key) }
                        else { selectedColors.insert(key) }
                    } label: {
                        ColorSwatchChip(colorKey: key, selected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel(Text(CardColorPalette.localizedName(key)))
                }
            }
        }
    }

    private func reset() {
        selectedBrands = []
        selectedFormats = []
        selectedColors = []
        selectedISOs = []
    }
}

// MARK: - Chip visuals

/// Brand / format / ISO chip: name + lighter trailing count. No nested backgrounds.
struct BrandCountChipLabel: View {
    /// Already-localized display string (proper nouns rendered verbatim,
    /// "Other" already passed through `String(localized:)` by the caller).
    let brand: String
    let count: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: brand)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(verbatim: "\(count)")
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .lineLimit(1)
                .opacity(selected ? 0.7 : 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected
                           ? Color.accentColor
                           : Color.secondary.opacity(0.15))
        )
        .foregroundColor(selected ? .white : .primary)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Color chip: swatch only, no label. Selected state uses a thicker white ring + slight scale.
struct ColorSwatchChip: View {
    let colorKey: String
    let selected: Bool

    var body: some View {
        Circle()
            .fill(CardColorPalette.swatch(colorKey))
            .frame(width: 32, height: 32)
            .overlay(
                Circle().stroke(
                    selected ? Color.white : Color.white.opacity(0.18),
                    lineWidth: selected ? 2.5 : 0.5
                )
            )
            .scaleEffect(selected ? 1.08 : 1.0)
            .animation(.spring(duration: 0.18), value: selected)
            .padding(2) // Expand the tap target
    }
}

// MARK: - Generic chip flow layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            // Wrap only if we're not at the start of a row — otherwise let an oversized
            // item overflow on its own row. Matches placeSubviews exactly.
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: proposal.width ?? x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
