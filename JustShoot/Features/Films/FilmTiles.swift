import SwiftUI

// MARK: - Grid tiles

/// Cover-art tile for a built-in film preset. The image is sourced from the
/// bundled film-card library via `FilmPreset.libraryCardImage`.
struct FilmPresetTile: View {
    let preset: FilmPreset
    let image: UIImage?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Text(preset.rawSimulation?.displayName ?? preset.displayName)
                .font(.system(size: (sizeClass == .regular ? 15 : 11) * captionScale, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.rawSimulation != nil ? Text(verbatim: preset.displayName) : Text("\(preset.displayName), ISO \(Int(preset.iso))"))
        .accessibilityHint("Start shooting with this film")
    }

    private var coverArt: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Color.white.opacity(0.05)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .clipShape(shape)
    }
}

/// Cover-art tile for a custom LUT. No matching catalog image, so we
/// render an accent-tinted icon in the same square cell shape.
struct CustomLUTTile: View {
    let lut: HomeCustomFilter
    let image: UIImage?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .caption) private var captionScale = 1.0

    private static let accent = Color(red: 0.6, green: 0.5, blue: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArt
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Text(lut.displayName)
                .font(.system(size: (sizeClass == .regular ? 15 : 11) * captionScale, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
