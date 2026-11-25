import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(SettingsIconStyle.key) private var iconStyle = SettingsIconStyle.standard
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @AppStorage(AppAppearance.cameraKey) private var cameraAppearance = AppAppearance.automatic
    private var preferences = PageBackgroundPreferences()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                card("Color Scheme") {
                    appearancePicker("Color Scheme", selection: $appearance)
                }

                card("Camera Appearance") {
                    appearancePicker("Camera Appearance", selection: $cameraAppearance)
                }

                card("Settings Icons") {
                    AppSegmentedPicker(title: "Settings Icons", selection: $iconStyle,
                        options: SettingsIconStyle.allCases, size: .large) { style in
                        Text(style.title)
                    }

                    iconPreview
                }

                card("Page Appearance") {
                    backgroundLink
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .appPageBackground()
        .navigationTitle("Appearance Management")
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .toolbar(.hidden, for: .tabBar)
    }

    private func appearancePicker(_ title: LocalizedStringKey, selection: Binding<AppAppearance>) -> some View {
        AppSegmentedPicker(title: title, selection: selection, options: AppAppearance.allCases, size: .large) { option in
            Text(option.title)
        }
    }

    private var iconPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                SettingsIcon.language
                SettingsIcon.appearance
                SettingsIcon.author
                SettingsIcon.rating
                SettingsIcon.share
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private var backgroundLink: some View {
        NavigationLink {
            GeneralBackgroundSettingsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("General Page Background")
                        .foregroundStyle(.primary)
                    Text(backgroundSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    private var backgroundSummary: LocalizedStringKey {
        guard preferences.isEnabled else { return "Off" }
        return preferences.style == .gradient ? preferences.palette.title : "Custom Photo"
    }

    private func card(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlassCard(cornerRadius: 24)
    }
}
