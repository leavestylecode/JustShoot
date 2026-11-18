import SwiftUI

enum AppBrand {
    static let wordmark = "OOO"
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
