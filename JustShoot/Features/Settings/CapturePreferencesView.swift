import SwiftUI

struct CapturePreferencesView: View {
    @AppStorage(FilmSource.simulationGrainPreferenceKey) private var simulationGrain = false
    @EnvironmentObject private var curveLibrary: FilmCurveLibrary

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Toggle(isOn: $simulationGrain) {
                    SettingRow(icon: SettingsIcon("circle.grid.3x3.circle.fill", color: .orange),
                               title: "FUJIFILM Grain")
                }
                .accessibilityLabel("Grain for FUJIFILM simulations")
                .tint(.green)
                NavigationLink {
                    FilmCurveLibraryView()
                } label: {
                    SettingRow(icon: SettingsIcon("chart.line.uptrend.xyaxis.circle.fill", color: .mint),
                               title: "Film Curves",
                               value: "\(curveLibrary.visibleCurveCount)/\(curveLibrary.totalCurveCount)",
                               showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .settingsGlassCard(cornerRadius: 24)
            .padding(16)
            .pageContentWidth()
        }
        .appPageBackground()
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
