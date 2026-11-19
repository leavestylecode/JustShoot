import SwiftUI

struct FilmCardDetailView: View {
    let preset: FilmPreset
    @ObservedObject private var settings: FilmPageSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedScene: FilmSampleScene?
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
        let wash: Color = packaging.scheme == .dark ? .black : .white
        return VStack(spacing: 0) {
            navigationHeader
            GeometryReader { geometry in
                let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
                let coverWidth = min(geometry.size.height * 0.76,
                                     sizeClass == .regular ? PageLayout.detailCoverWidth : .infinity)
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                                  : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                ScrollView {
                    VStack(spacing: 26) {
                        layout {
                            cover
                                .frame(maxWidth: coverWidth)
                                .frame(maxWidth: wide ? coverWidth : .infinity)
                            VStack(alignment: .leading, spacing: 22) {
                                filmInfo(packaging)
                                introduction
                                recommendations
                                gallery
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        shootingButton
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .pageContentWidth(wide ? PageLayout.browseWidth : PageLayout.readingWidth)
                }
            }
        }
        .background {
            packaging.color.overlay {
                LinearGradient(colors: [wash.opacity(0.08), .clear, wash.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, packaging.scheme)
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

            Text(verbatim: preset.coverTitle)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

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
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: packaging.brand.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                Text(verbatim: preset.coverTitle)
                    .font(.title2.bold())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if preset.rawSimulation == nil {
                HStack(spacing: 10) {
                    Text(verbatim: "ISO \(Int(preset.iso))")
                    if let format = packaging.format { Text(verbatim: format) }
                    if let process = packaging.process { Text(verbatim: process) }
                }
                .font(.subheadline.monospacedDigit())
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("About this film", tableName: "FilmIntroductions")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    let sources = preset.guideSources
                    Link(destination: sources.manufacturer) {
                        Text("Manufacturer’s guide", tableName: "FilmIntroductions")
                    }
                    Link(destination: sources.community) {
                        Text("Photographers’ notes", tableName: "FilmIntroductions")
                    }
                    if let scene = selectedScene ?? preset.sampleScenes.first {
                        Link(destination: scene.archiveURL) {
                            Text("Photograph by Carol M. Highsmith", tableName: "FilmIntroductions")
                        }
                    }
                } label: {
                    Image(systemName: "book")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(Text("Sources", tableName: "FilmIntroductions"))
            }
            Text(preset.introduction)
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scene = selectedScene ?? preset.sampleScenes.first {
                Text("Sample photographs", tableName: "FilmIntroductions")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                let filename = scene.filename(gradedWith: showsOriginal ? nil : preset)
                VaultImage(filename: filename, maxPixel: 1024, isHero: true)
                    .id(filename)
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(Text(scene.title))

                let controls = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                controls {
                    HStack(spacing: 6) {
                        ForEach(preset.sampleScenes) { sample in
                            let selected = sample == scene
                            Button { selectedScene = sample } label: {
                                VaultImage(filename: sample.filename(gradedWith: preset), maxPixel: 256)
                                    .aspectRatio(1.5, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 5))
                                    .padding(3)
                                    .overlay {
                                        if selected {
                                            RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 1.5)
                                        }
                                    }
                                    .frame(maxWidth: 62, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(sample.title))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("filmLibrary.scene.\(sample.id.rawValue)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Sample appearance", selection: $showsOriginal) {
                        Text("Unfiltered").tag(true)
                        Text("Film look").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 142)
                    .accessibilityIdentifier("filmLibrary.compare")
                }
            }
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended scenes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { tags }
                VStack(alignment: .leading, spacing: 7) { tags }
            }
        }
    }

    private var tags: some View {
        ForEach(preset.sceneTags) { tag in
            Text(tag.title)
                .font(.subheadline.weight(.medium))
                .fixedSize()
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.07), in: Capsule())
        }
    }

    @ViewBuilder
    private var membership: some View {
        if settings.preferences.isVisible(.preset(preset)) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(preset.coverDetails.scheme == .dark ? Color.white : VaultMembershipStyle.green)
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
