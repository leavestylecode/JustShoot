import SwiftUI

struct PhotoEditFilmStrip: View {
    let session: PhotoEditSession
    let films: [FilmSource]
    @Binding var recipe: PhotoEditRecipe
    @State private var shotSample: CGImage?
    @State private var filmBase: CGImage?

    private var selected: String {
        recipe.filmID ?? (recipe.useCameraOriginal ? "camera-original" : "as-shot")
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    choice("as-shot", title: String(localized: "As Shot"), base: shotSample)
                    if session.hasCameraOriginal {
                        choice("camera-original", title: String(localized: "Camera original"), base: filmBase)
                    }
                    ForEach(films) { film in
                        choice(film.id, title: film.displayName, base: filmBase, film: film)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .onAppear { reader.scrollTo(selected, anchor: .center) }
        }
        .frame(height: 76)
        .task {
            shotSample = try? await session.filmSampleBase(cameraOriginal: false)
            filmBase = session.hasCameraOriginal ? try? await session.filmSampleBase(cameraOriginal: true) : shotSample
        }
    }

    private func shortTitle(_ film: FilmSource?, fallback: String) -> String {
        if case .preset(let preset) = film { return preset.tileTitle }
        return fallback
    }

    private func choice(_ id: String, title: String, base: CGImage?, film: FilmSource? = nil) -> some View {
        Button {
            recipe.filmID = film?.id
            recipe.useCameraOriginal = session.hasCameraOriginal && id != "as-shot"
        } label: {
            VStack(spacing: 4) {
                PhotoEditFilmTile(session: session, base: base, film: film)
                    .frame(width: 56, height: 48)
                    .clipShape(.rect(cornerRadius: 6))
                    .padding(2)
                    .overlay { if selected == id { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 2) } }
                Text(verbatim: shortTitle(film, fallback: title))
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }
}

private struct PhotoEditFilmTile: View {
    let session: PhotoEditSession
    let base: CGImage?
    let film: FilmSource?
    @State private var graded: CGImage?

    var body: some View {
        ZStack {
            if let image = film == nil ? base : graded {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else { Color.secondary.opacity(0.12) }
        }
        .task(id: base.map(ObjectIdentifier.init)) {
            guard let film, let base else { return }
            let sample = try? await session.filmSample(film, base: base)
            if !Task.isCancelled { graded = sample }
        }
    }
}
