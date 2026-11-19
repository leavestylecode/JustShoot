import PhotosUI
import SwiftUI

struct GeneralBackgroundSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var preferences = PageBackgroundPreferences()

    private var accent: Color {
        preferences.isEnabled ? preferences.palette.colors.inner : .primary
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Toggle(isOn: preferences.$isEnabled) {
                    HStack(spacing: 10) {
                        Image(systemName: preferences.isEnabled ? "circle.fill" : "circle")
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Effect").font(.headline)
                            Text("Apply the selected background to app pages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(accent)
                .padding(16)
                .appearanceSettingsGlass()
                .contentShape(Rectangle())
                // Treat a tap anywhere on the card as one switch activation.
                .highPriorityGesture(TapGesture().onEnded { preferences.isEnabled.toggle() })

                Group {
                    styleCard
                    if preferences.style == .gradient {
                        slider("Color Intensity", symbol: "circle.lefthalf.filled", value: preferences.$intensity)
                        slider("Gradient Range", symbol: "circle.dotted.circle", value: preferences.$range)
                        BackgroundGradientOptions()
                    }
                }
                .disabled(!preferences.isEnabled)
                .opacity(preferences.isEnabled ? 1 : 0.4)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .appPageBackground()
        .navigationTitle("General Page Background")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Background Style", symbol: "circle.lefthalf.filled.righthalf.striped.horizontal.inverse")
            Picker("Background Style", selection: preferences.$style) {
                Text("Gradient").tag(BackgroundStyle.gradient)
                Text("Custom Photo").tag(BackgroundStyle.photo)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()

            if preferences.style == .photo {
                BackgroundPhotoControls(blur: preferences.$blur, saturation: preferences.$saturation)
            }
        }
        .padding(16)
        .appearanceSettingsGlass()
    }

    private func slider(_ title: LocalizedStringKey, symbol: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading(title, symbol: symbol)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(preferences.isEnabled ? accent : .secondary)
                    .brightness(preferences.isEnabled ? (colorScheme == .dark ? 0.32 : -0.32) : 0)
            }
            Slider(value: value, in: 0.1...1, step: 0.1)
                .tint(preferences.isEnabled ? accent : .secondary)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        }
        .padding(16)
        .appearanceSettingsGlass()
    }

    private func heading(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title).font(.headline)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BackgroundPhotoControls: View {
    @Binding var blur: PhotoEffectLevel
    @Binding var saturation: PhotoEffectLevel
    private let store = BackgroundPhotoStore.shared
    @State private var selection: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var photoError = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                levelPicker("Blur", selection: $blur)
                levelPicker("Saturation", selection: $saturation)
            }
            .padding(16)
            .appearanceSettingsGlass()

            ZStack(alignment: .topTrailing) {
                if let image = store.image {
                    Button {
                        showsPhotoPicker = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: 14))
                    }
                    .accessibilityLabel("Replace Photo")

                    Button(role: .destructive) {
                        Task {
                            do { try await store.remove() }
                            catch { photoError = true }
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Remove Background Photo")
                } else {
                    Button {
                        showsPhotoPicker = true
                    } label: {
                        VStack(spacing: 14) {
                            Image(systemName: "plus.viewfinder")
                                .font(.system(size: 60))
                            Text("Choose Photo").font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .contentShape(Rectangle())
                    }
                    .appearanceSettingsGlass(interactive: true)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 220)
            .disabled(selection != nil || store.isChanging)
            .overlay {
                if selection != nil || store.isChanging {
                    ProgressView().padding(12).background(.regularMaterial, in: .circle)
                }
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selection, matching: .images)
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

    private func levelPicker(_ title: LocalizedStringKey, selection: Binding<PhotoEffectLevel>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(PhotoEffectLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    @ViewBuilder
    func appearanceSettingsGlass(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            settingsGlassCard(cornerRadius: cornerRadius, interactive: interactive)
        } else {
            background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}
