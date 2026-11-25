import SwiftUI

struct CapturePreferencesView: View {
    @AppStorage(PhotoCaptureMode.hdrPreferenceKey) private var hdrEnabled = PhotoCaptureMode.hdrEnabledByDefault

    var body: some View {
        ScrollView {
            Toggle(isOn: $hdrEnabled) {
                SettingRow(icon: SettingsIcon("camera.aperture", color: .indigo), title: "HDR Capture")
            }
            .tint(.green)
            .accessibilityIdentifier("settings.capture.hdr")
            .padding(16)
            .settingsGlassCard(cornerRadius: 24)
            .padding(16)
            .pageContentWidth()
        }
        .appPageBackground()
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .toolbar(.hidden, for: .tabBar)
    }
}
