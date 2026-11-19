import PhotosUI
import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(SettingsIconStyle.key) private var iconStyle = SettingsIconStyle.standard
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    private var preferences = PageBackgroundPreferences()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                card("Appearance", icon: SettingsIcon("circle.lefthalf.filled", color: .indigo)) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                card("Settings Icons", icon: .preferences) {
                    Picker("Settings Icons", selection: $iconStyle) {
                        ForEach(SettingsIconStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 18) {
                        SettingsIcon.language
                        SettingsIcon.appearance
                        SettingsIcon.author
                        SettingsIcon.rating
                        SettingsIcon.share
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
                }

                Toggle(isOn: preferences.$isEnabled) {
                    Label { Text("Background Effect") } icon: { SettingsIcon.appearance }
                }
                .tint(.green)
                .padding(16)
                .settingsGlassCard(cornerRadius: 20)

                if preferences.isEnabled {
                    card("Background Style", icon: SettingsIcon("square.circle.fill", color: .teal)) {
                        Picker("Background Style", selection: preferences.$style) {
                            Text("Gradient").tag(BackgroundStyle.gradient)
                            Text("Custom Photo").tag(BackgroundStyle.photo)
                        }
                        .pickerStyle(.segmented)
                    }
                    switch preferences.style {
                    case .gradient:
                        paletteCard
                        gradientControls
                    case .photo:
                        BackgroundPhotoControls()
                    }
                }
            }
            .padding(16)
            .pageContentWidth()
        }
        .appPageBackground()
        .navigationTitle("Appearance Management")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var paletteCard: some View {
        card("Palette", icon: SettingsIcon("circle.hexagongrid.circle.fill", color: .pink)) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BackgroundPalette.allCases, id: \.self) { palette in
                    let selected = preferences.palette == palette
                    Button {
                        preferences.palette = palette
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [palette.colors.inner, palette.colors.outer],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 36)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.72))
                                    }
                                }
                            Text(palette.title).font(.caption.weight(selected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(palette.title))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var gradientControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            slider("Color Intensity", icon: SettingsIcon("drop.circle.fill", color: .blue), value: preferences.$intensity)
            slider("Gradient Range", icon: SettingsIcon("arrow.up.left.and.arrow.down.right.circle.fill", color: .teal), value: preferences.$range)
            Label { Text("Gradient Origin").font(.headline) } icon: { SettingsIcon("scope", color: .indigo) }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(GradientOrigin.allCases, id: \.self) { origin in
                    let selected = preferences.origin == origin
                    Button {
                        preferences.origin = origin
                    } label: {
                        Image(systemName: origin == .center ? "circle.dotted" : "arrow.right")
                            .rotationEffect(.radians(atan2(origin.point.y - 0.5, origin.point.x - 0.5)))
                            .font(.body.weight(selected ? .bold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.primary.opacity(selected ? 0.15 : 0.045), in: .rect(cornerRadius: 10))
                            .overlay { if selected { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(origin.title))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(16)
        .settingsGlassCard(cornerRadius: 20)
    }

    private func card(_ title: LocalizedStringKey, icon: SettingsIcon, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(title).font(.headline) } icon: { icon }
            content()
        }
        .padding(16)
        .settingsGlassCard(cornerRadius: 20)
    }

    private func slider(_ title: LocalizedStringKey, icon: SettingsIcon, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Label { Text(title).font(.headline) } icon: { icon }
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.1...1, step: 0.1)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        }
    }
}

private struct BackgroundPhotoControls: View {
    private var preferences = PageBackgroundPreferences()
    private let store = BackgroundPhotoStore.shared
    @State private var selection: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var photoError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let image = store.image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .accessibilityHidden(true)
            }
            let hasPhoto = store.image != nil
            HStack {
                Button {
                    showsPhotoPicker = true
                } label: {
                    Label {
                        Text(hasPhoto ? LocalizedStringKey("Replace Photo") : "Choose Photo")
                    } icon: {
                        SettingsIcon("photo.circle.fill", color: .blue)
                    }
                    .frame(minHeight: 44)
                }
                .photosPicker(isPresented: $showsPhotoPicker, selection: $selection, matching: .images)
                Spacer()
                if selection != nil || store.isChanging {
                    ProgressView()
                } else if store.image != nil {
                    Button(role: .destructive) {
                        Task {
                            do { try await store.remove() }
                            catch { photoError = true }
                        }
                    } label: {
                        Image(systemName: "trash.circle.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Remove Background Photo")
                }
            }
            .disabled(store.isChanging || selection != nil)
            levelPicker("Blur", icon: SettingsIcon("drop.circle.fill", color: .blue), selection: preferences.$blur)
            levelPicker("Saturation", icon: SettingsIcon("circle.hexagongrid.circle.fill", color: .pink), selection: preferences.$saturation)
        }
        .padding(16)
        .settingsGlassCard(cornerRadius: 20)
        .task { await store.loadIfNeeded() }
        .task(id: selection) {
            guard let selection else { return }
            defer { if !Task.isCancelled { self.selection = nil } }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                try await store.replace(with: data)
            } catch {
                if !Task.isCancelled { photoError = true }
            }
        }
        .alert("Couldn’t update the background photo", isPresented: $photoError) {
            Button("OK", role: .cancel) {}
        }
    }

    private func levelPicker(_ title: LocalizedStringKey, icon: SettingsIcon, selection: Binding<PhotoEffectLevel>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(title).font(.headline) } icon: { icon }
            Picker(title, selection: selection) {
                ForEach(PhotoEffectLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
