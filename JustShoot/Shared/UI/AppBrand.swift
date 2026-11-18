import SwiftUI

enum AppBrand {
    static let wordmark = "OOO"
    static let paper = Color(red: 0.957, green: 0.941, blue: 0.910)
    static let ink = Color(red: 0.102, green: 0.094, blue: 0.086)
    static let ringStrokeFraction: CGFloat = 1 / 7
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OOO Cam"
}

struct AppBrandMark: View {
    var body: some View {
        Image(decorative: "OOOLogo")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
