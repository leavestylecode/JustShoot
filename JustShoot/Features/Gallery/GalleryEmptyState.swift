import SwiftUI

struct GalleryEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            Image(decorative: "LaunchRing")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(colorScheme == .dark ? AppBrand.paper : AppBrand.ink)
            Text("No photos yet")
                .font(.subheadline)
                .foregroundStyle(colorScheme == .light ? AppBrand.ink.opacity(0.76) : .secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}
