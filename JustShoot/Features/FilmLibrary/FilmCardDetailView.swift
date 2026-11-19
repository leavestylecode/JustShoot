import SwiftUI

struct FilmCardDetailView: View {
    let preset: FilmPreset
    @ObservedObject private var settings: FilmPageSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTag: FilmSceneTag?
    @State private var showsOriginal = false

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
        return VStack(spacing: 0) {
            navigationHeader
            GeometryReader { geometry in
                let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
                let coverWidth = min(geometry.size.height * 0.76,
                                     sizeClass == .regular ? PageLayout.detailCoverWidth : .infinity)
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                                  : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                ScrollView {
                    VStack(spacing: 32) {
                        layout {
                            cover
                                .frame(maxWidth: coverWidth)
                                .frame(maxWidth: wide ? coverWidth : .infinity)
                            VStack(alignment: .leading, spacing: 30) {
                                filmInfo(packaging)
                                gallery
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        shootingButton
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .pageContentWidth(wide ? PageLayout.browseWidth : PageLayout.readingWidth)
                }
                .scrollIndicators(.hidden)
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
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            membership
        }
        .padding(.horizontal, 18)
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

    private var gallery: some View {
        let recommendations = preset.recommendations
        return VStack(alignment: .leading, spacing: 12) {
            if let selection = recommendations.first(where: { $0.tag == selectedTag }) ?? recommendations.first {
                Text("Recommended scenes")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { sceneButtons(recommendations, selected: selection.tag) }
                    VStack(alignment: .leading, spacing: 2) { sceneButtons(recommendations, selected: selection.tag) }
                }

                let scene = selection.scene
                let filename = scene.filename(gradedWith: showsOriginal ? nil : preset)
                VaultImage(filename: filename, maxPixel: 1024, isHero: true)
                    .id(filename)
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(Text(scene.title))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        caption(for: scene).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
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
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .foregroundStyle(active ? Color(.systemBackground) : .primary)
                    .background(active ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                    .frame(minHeight: 44)
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
            Text(verbatim: scene.credit)
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
