import SwiftUI

struct CapturePreferencesView: View {
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary

    var body: some View {
        ScrollView {
            NavigationLink {
                FilmCurveLibraryView()
            } label: {
                SettingRow(icon: SettingsIcon("chart.line.uptrend.xyaxis.circle.fill", color: .mint),
                           title: "Film Curves",
                           value: "\(curveLibrary.visibleCurveCount)/\(curveLibrary.totalCurveCount)",
                           chevron: .forward)
            }
            .buttonStyle(.plain)
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
