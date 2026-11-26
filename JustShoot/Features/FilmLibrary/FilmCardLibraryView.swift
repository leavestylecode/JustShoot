import SwiftUI

struct FilmCardLibraryView: View {
    @StateObject private var settings: FilmPageSettings
    private let library: FilmCardLibrary
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var gridScale = 1.0
    @Namespace private var zoomNamespace

    init(settings: FilmPageSettings? = nil, library: FilmCardLibrary = .shared) {
        _settings = StateObject(wrappedValue: settings ?? .shared)
        self.library = library
    }

    var body: some View {
        // Register these dependencies before SwiftUI evaluates the deferred layout closures.
        let loadState = library.loadState
        let presets = library.presets
        GeometryReader { geometry in
            let regular = sizeClass == .regular
            let inset: CGFloat = regular ? 24 : 14
            let width = min(geometry.size.width, PageLayout.browseWidth) - 2 * inset
            let count = PageLayout.gridColumns(width: width, minimum: (regular ? 144 : 100) * gridScale,
                spacing: 10, maximum: 8)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(presets) { preset in
                        tile(preset)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .pageContentWidth(PageLayout.browseWidth)
            }
            .overlay {
                switch loadState {
                case .loading:
                    ProgressView().accessibilityLabel("Loading films")
                case .failed:
                    PageNotice(title: "Film Vault unavailable", systemImage: "shippingbox",
                        action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await library.loadIfNeeded() } })
                case .ready where presets.isEmpty:
                    PageNotice(title: "No films available", systemImage: "film")
                case .ready:
                    EmptyView()
                }
            }
        }
        .appPageBackground()
        .navigationTitle("Film Vault")
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges()
        .navigationDestination(for: FilmPreset.self) { preset in
            FilmCardDetailView(preset: preset, settings: settings)
                .filmZoomTransition(id: preset.id, in: zoomNamespace)
        }
        .navigationDestination(for: FilmSource.self) { source in
            CameraView(source: source, filmSettings: settings)
        }
        .task { await library.loadIfNeeded() }
        .mainTabRoot(.library)
    }

    private func tile(_ preset: FilmPreset) -> some View {
        let added = settings.preferences.isVisible(.preset(preset))
        return NavigationLink(value: preset) {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let cover = preset.libraryCardImage {
                        VaultImage(filename: cover, maxPixel: sizeClass == .regular ? 640 : 384)
                    } else {
                        Rectangle().fill(.primary.opacity(0.05)).overlay { Image(systemName: "film") }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    badge(added: added)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Text(verbatim: preset.tileTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: preset.displayName))
        .accessibilityValue(added ? Text("Added") : Text("Not added"))
        .accessibilityIdentifier("filmLibrary.film.\(preset.id)")
        .filmTransitionSource(id: preset.id, in: zoomNamespace)
    }

    private func badge(added: Bool) -> some View {
        Image(systemName: added ? "checkmark" : "circle.dashed")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(added ? .white : AppBrand.ink)
            .frame(width: 26, height: 26)
            .background(added ? VaultMembershipStyle.green : AppBrand.paper, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
            .padding(8)
    }
}

enum VaultMembershipStyle {
    static let green = Color(red: 0.15, green: 0.34, blue: 0.26)
}

/// All images use the cancellable, coalescing bundle decoder. Giving each file its
/// own view identity also prevents a previous scene from flashing under a new label.
struct VaultImage: View {
    let filename: String
    let maxPixel: Int
    var gradedWith: FilmPreset?
    var isHero = false
    var placeholderSystemImage = "photo"
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    private struct Request: Hashable {
        let filename: String
        let maxPixel: Int
        let preset: FilmPreset?
        let attempt: Int
    }

    var body: some View {
        Rectangle().fill(.primary.opacity(0.05))
            .overlay {
                if let image = image ?? FilmCardImageCache.shared.cachedImage(imageName: filename, maxPixel: maxPixel, gradedWith: gradedWith) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if isHero && failed {
                    PageNotice(title: "Preview unavailable", systemImage: "photo",
                        action: .init(title: "Retry", icon: "arrow.clockwise") { attempt += 1 })
                } else if isHero {
                    ProgressView().accessibilityLabel("Loading sample")
                } else {
                    Image(systemName: placeholderSystemImage).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: Request(filename: filename, maxPixel: maxPixel, preset: gradedWith, attempt: attempt)) {
                failed = false
                let result = await FilmCardImageCache.shared.loadImage(imageName: filename, maxPixel: maxPixel, gradedWith: gradedWith)
                guard !Task.isCancelled else { return }
                image = result
                failed = result == nil
            }
    }
}
