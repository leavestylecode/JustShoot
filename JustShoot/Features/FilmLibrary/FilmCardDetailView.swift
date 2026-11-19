import SwiftUI

struct FilmCardDetailView: View {
    let preset: FilmPreset
    @ObservedObject private var settings: FilmPageSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedScene: FilmSampleScene?
    @State private var showsOriginal = false
    @State private var showsInfo = false

    init(preset: FilmPreset, settings: FilmPageSettings? = nil) {
        self.preset = preset
        self.settings = settings ?? .shared
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = PageLayout.usesLandscapeColumns(in: geometry.size, isRegular: sizeClass == .regular)
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        if let cover = preset.libraryCardImage {
                            VaultImage(filename: cover, maxPixel: 256)
                                .frame(width: 52, height: 52)
                                .clipShape(.rect(cornerRadius: 10))
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: preset.displayName)
                            .font(.system(.largeTitle, design: .serif, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }

                    layout {
                        gallery
                        recommendations
                            .frame(maxWidth: wide ? 240 : .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 18)
                .padding(.vertical, 12)
                .pageContentWidth(wide ? PageLayout.browseWidth : PageLayout.readingWidth)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .pageContentWidth(PageLayout.readingWidth)
                .background(.bar)
        }
        .appPageBackground()
        .softScrollEdges()
        .navigationTitle("OOO Samples")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About these samples")
            }
        }
        .alert("About these samples", isPresented: $showsInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("OOO created these scenes with AI and applied this film’s color treatment. Choose Original to compare the same scene before grading.")
        }
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

    private var actions: some View {
        let added = settings.preferences.isVisible(.preset(preset))
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if added {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(scheme == .dark ? Color.mint : VaultMembershipStyle.green)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .accessibilityLabel(Text("Added \(preset.displayName)"))
            } else {
                Button { settings.setVisible(preset, true) } label: {
                    Label("Add to Films", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add \(preset.displayName) to Films"))
                .accessibilityIdentifier("filmLibrary.add.\(preset.id)")
            }

            NavigationLink(value: FilmSource.preset(preset)) {
                Label("Start Shooting", systemImage: "camera.fill")
                    .font(.headline)
                    .foregroundStyle(scheme == .dark ? AppBrand.ink : AppBrand.paper)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(scheme == .dark ? AppBrand.paper : AppBrand.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filmLibrary.use.\(preset.id)")
        }
    }
}
