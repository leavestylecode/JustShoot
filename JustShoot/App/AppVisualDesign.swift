import SwiftUI

extension View {
    /// Also apply at independently hosted SwiftUI roots, including the gallery's photo viewer.
    func appVisualDesign() -> some View {
        dynamicTypeSize(.large)
            .scrollIndicators(.never)
    }
}
