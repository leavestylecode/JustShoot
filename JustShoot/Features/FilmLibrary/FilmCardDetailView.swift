import SwiftUI

struct FilmCardDetailView: View {
    let preset: FilmPreset
    @ObservedObject private var settings: FilmPageSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
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
        GeometryReader { geometry in
            let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        if let cover = preset.libraryCardImage {
                            VaultImage(filename: cover, maxPixel: 256)
                                .frame(width: 52, height: 52)
                                .clipShape(.rect(cornerRadius: 10))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: preset.displayName)
                                .font(.system(.largeTitle, design: .serif, weight: .medium))
                                .accessibilityAddTraits(.isHeader)
                            Text(preset.styleDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        membership
                    }

                    layout {
                        gallery
                        recommendations
                            .frame(maxWidth: wide ? 240 : .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 18)
                .padding(.vertical, 8)
                .pageContentWidth(wide ? PageLayout.browseWidth : PageLayout.readingWidth)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                shootingButton
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
        }
        .appPageBackground()
        .navigationTitle("OOO Samples")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scene = selectedScene ?? preset.sampleScenes.first {
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
                .foregroundStyle(scheme == .dark ? Color.mint : VaultMembershipStyle.green)
                .frame(width: 44, height: 44)
                .background(.green.opacity(0.1), in: Circle())
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
