import SwiftUI

/// Visual preferences only; a cover always retains its accessible film name.
struct FilmTileTextVisibility: Equatable, Sendable {
    var showsTitle = true
    var showsSubtitle = true

    var showsText: Bool { showsTitle || showsSubtitle }
}

// MARK: - Grid tiles

/// Cover-art tile for a built-in film preset. The image is sourced from the
/// bundled film-card library via `FilmPreset.libraryCardImage`.
struct FilmPresetTile: View {
    let preset: FilmPreset
    let image: UIImage?
    let textVisibility: FilmTileTextVisibility
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    init(preset: FilmPreset, image: UIImage?, textVisibility: FilmTileTextVisibility = .init()) {
        self.preset = preset
        self.image = image
        self.textVisibility = textVisibility
    }

    var body: some View {
        let sceneTitles = preset.sceneTags.map { $0.localizedTitle(locale: locale) }

        return VStack(alignment: .leading, spacing: 8) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            if textVisibility.showsText {
                VStack(alignment: .leading, spacing: 3) {
                    if textVisibility.showsTitle {
                        Text(preset.tileTitle)
                            .font(.system(size: (sizeClass == .regular ? 15 : 13) * captionScale, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(sizeClass == .regular ? 13.0 / 15.0 : 11.0 / 13.0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if textVisibility.showsSubtitle {
                        Text(verbatim: sceneTitles.joined(separator: " · "))
                            .font(.system(size: (sizeClass == .regular ? 12 : 11) * captionScale))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.rawSimulation != nil ? Text(verbatim: preset.displayName) : Text("\(preset.displayName), ISO \(Int(preset.iso))"))
        .accessibilityValue(Text(verbatim: sceneTitles.joined(separator: " · ")))
        .accessibilityHint("Start shooting with this film")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .clipShape(shape)
    }
}

enum FilmTileLayout {
    /// Wider cells keep the full English recommendations on one line at 11 pt.
    static func minimumWidth(locale: Locale, textVisibility: FilmTileTextVisibility = .init()) -> CGFloat {
        if textVisibility.showsSubtitle, locale.language.languageCode?.identifier != "zh" { return 160 }
        // Keep CLASSIC CHROME complete at the minimum 11 pt title size.
        return textVisibility.showsTitle ? 106 : 100
    }

    static func rowSpacing(showsText: Bool) -> CGFloat {
        showsText ? 18 : 14
    }
}

/// Cover-art tile for a custom LUT. No matching catalog image, so we
/// render an accent-tinted icon in the same square cell shape.
struct CustomLUTTile: View {
    let lut: HomeCustomFilter
    let image: UIImage?
    let textVisibility: FilmTileTextVisibility
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    private static let accent = Color(red: 0.6, green: 0.5, blue: 0.8)

    init(lut: HomeCustomFilter, image: UIImage?, textVisibility: FilmTileTextVisibility = .init()) {
        self.lut = lut
        self.image = image
        self.textVisibility = textVisibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            if textVisibility.showsTitle {
                Text(lut.displayName)
                    .font(.system(size: (sizeClass == .regular ? 15 : 13) * captionScale, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(sizeClass == .regular ? 13.0 / 15.0 : 11.0 / 13.0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Custom filter \(lut.displayName), ISO \(Int(lut.iso))"))
        .accessibilityHint("Start shooting with this filter")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Self.accent.opacity(0.18)
            if let image {
                Image(uiImage: image).renderingMode(.template)
                    .foregroundColor(Self.accent)
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(Self.accent)
            }
        }
        .clipShape(shape)
    }
}
