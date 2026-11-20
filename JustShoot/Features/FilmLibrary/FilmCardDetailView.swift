import SwiftUI

struct FilmCardDetailView: View {
    private static let pageInset: CGFloat = 20

    let preset: FilmPreset
    @ObservedObject private var settings: FilmPageSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var pageScheme

    init(preset: FilmPreset, settings: FilmPageSettings? = nil) {
        self.preset = preset
        self.settings = settings ?? .shared
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            detail.toolbarVerticalBehavior(.disabled)
        } else {
            detail
        }
    }

    private var detail: some View {
        let packaging = preset.coverDetails
        return GeometryReader { geometry in
            let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
            let pageWidth = wide ? PageLayout.browseWidth
                : min(PageLayout.readingWidth, max(PageLayout.detailCoverWidth, geometry.size.height))
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            let scroll = ScrollView {
                VStack(spacing: 64) {
                    layout {
                        cover
                            .frame(maxWidth: wide ? PageLayout.detailCoverWidth : .infinity)
                        VStack(alignment: .leading, spacing: 30) {
                            filmInfo(packaging)
                            FilmSceneGallery(preset: preset)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    shootingButton
                }
                .padding(.top, 12)
                .padding(.bottom, 44)
                .padding(.horizontal, Self.pageInset)
                .frame(maxWidth: pageWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            let header = navigationHeader
                .padding(.horizontal, Self.pageInset)
                .frame(maxWidth: pageWidth)

            if #available(iOS 26.0, *) {
                scroll
                    .safeAreaBar(edge: .top, spacing: 0) {
                        header
                            .frame(maxWidth: .infinity)
                            .background {
                                let base: Color = pageScheme == .dark ? .black : .white
                                LinearGradient(stops: [
                                    .init(color: base.opacity(0.82), location: 0),
                                    .init(color: base.opacity(0.64), location: 0.72),
                                    .init(color: .clear, location: 1)
                                ], startPoint: .top, endPoint: .bottom)
                                .ignoresSafeArea(edges: .top)
                            }
                            .environment(\.colorScheme, pageScheme)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                scroll.safeAreaInset(edge: .top, spacing: 0) {
                    header.frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
        .background {
            Color(.systemBackground)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: packaging.color.opacity(0.14), location: 0),
                        .init(color: .clear, location: 0.65)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
        }
        .navigationTitle(Text(verbatim: preset.coverTitle))
        .toolbar(.hidden, for: .navigationBar, .tabBar)
    }

    private var navigationHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .cameraControlSurface()
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Film Vault")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)

            membership
        }
        .padding(.vertical, 4)
    }

    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Group {
            if let filename = preset.libraryCardImage {
                VaultImage(filename: filename, maxPixel: 1024, isHero: true)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "film") }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.2), lineWidth: 1) }
        .accessibilityLabel(Text(verbatim: preset.displayName))
    }

    private func filmInfo(_ packaging: FilmCoverDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: packaging.brand.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Text(verbatim: preset.coverTitle)
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if preset.rawSimulation == nil {
                let specs = ["ISO \(Int(preset.iso))", packaging.format, packaging.process].compactMap { $0 }
                Text(verbatim: specs.joined(separator: "  ·  "))
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(preset.introduction)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var membership: some View {
        if settings.preferences.isVisible(.preset(preset)) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(.primary.opacity(0.12), in: Circle())
                .accessibilityLabel(Text("Added \(preset.displayName)"))
        } else {
            Button { settings.setVisible(preset, true) } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .cameraControlSurface()
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add \(preset.displayName) to Films"))
            .accessibilityIdentifier("filmLibrary.add.\(preset.id)")
        }
    }

    private var shootingButton: some View {
        let label = Label("Start Shooting", systemImage: "camera.fill")
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)

        return Group {
            if #available(iOS 26.0, *) {
                NavigationLink(value: FilmSource.preset(preset)) { label }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            } else {
                NavigationLink(value: FilmSource.preset(preset)) {
                    label
                        .frame(minHeight: 50)
                        .cameraControlSurface()
                        .contentShape(.capsule)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("filmLibrary.use.\(preset.id)")
    }
}

private struct FilmSceneGallery: View {
    let preset: FilmPreset
    @ScaledMetric(relativeTo: .subheadline) private var minimumCaptionWidth: CGFloat = 132
    @State private var selectedTag: FilmSceneTag?
    @State private var showsOriginal = false

    var body: some View {
        let recommendations = preset.recommendations
        return VStack(alignment: .leading, spacing: 12) {
            if let selection = recommendations.first(where: { $0.tag == selectedTag }) ?? recommendations.first {
                FilmSceneTagLayout {
                    sceneButtons(recommendations, selected: selection.tag)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recommended scenes")

                let scene = selection.scene
                let filename = scene.filename(gradedWith: showsOriginal ? nil : preset)
                VaultImage(filename: filename, maxPixel: 1024, isHero: true)
                    .id(filename)
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(Text(scene.title))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        caption(for: scene)
                            .frame(minWidth: minimumCaptionWidth, maxWidth: .infinity, alignment: .leading)
                        comparison.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        caption(for: scene)
                        comparison
                    }
                }
            }
        }
    }

    private func sceneButtons(_ recommendations: [FilmRecommendation], selected: FilmSceneTag) -> some View {
        ForEach(recommendations) { item in
            let active = item.tag == selected
            Button { selectedTag = item.tag } label: {
                Text(item.tag.title)
                    .font(.subheadline.weight(active ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.primary.opacity(active ? 1 : 0.70))
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        if active {
                            Capsule().fill(.primary).frame(height: 2)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("filmLibrary.scene.\(item.tag.rawValue)")
        }
    }

    private func caption(for scene: FilmSampleScene) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(scene.title)
                .font(.subheadline.weight(.semibold))
            Text("JustShoot · AI-generated", tableName: "FilmIntroductions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var comparison: some View {
        Picker("Sample appearance", selection: $showsOriginal) {
            Text("Unfiltered").tag(true)
            Text("Film look").tag(false)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("filmLibrary.compare")
    }
}

/// Spread one row across the sample. Wrapped rows keep their natural widths and reading order.
struct FilmSceneTagLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        let spacing: CGFloat = 6
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width > width
                ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
        func rowWidth(_ row: ArraySlice<CGSize>) -> CGFloat {
            row.reduce(CGFloat(max(0, row.count - 1)) * spacing) { $0 + $1.width }
        }
        let naturalWidth = rowWidth(sizes[...])
        let fitsOneRow = width.isFinite && naturalWidth <= width && !sizes.isEmpty
        let extraWidth = fitsOneRow ? (width - naturalWidth) / CGFloat(sizes.count) : 0
        let middle = (sizes.count + 1) / 2
        let balancesTwoRows = naturalWidth > width
            && rowWidth(sizes[..<middle]) <= width && rowWidth(sizes[middle...]) <= width
        var origin = CGPoint.zero
        var rowBottom: CGFloat = 0
        return sizes.enumerated().map { index, size in
            let startsNextRow = (balancesTwoRows && index == middle) || origin.x + size.width > width
            if !fitsOneRow, origin.x > 0, startsNextRow {
                origin = CGPoint(x: 0, y: rowBottom + 2)
            }
            let frame = CGRect(origin: origin, size: CGSize(width: size.width + extraWidth, height: size.height))
            rowBottom = max(rowBottom, frame.maxY)
            origin.x = frame.maxX + spacing
            return frame
        }
    }
}
