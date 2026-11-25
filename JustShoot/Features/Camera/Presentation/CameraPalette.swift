import SwiftUI

enum CameraPalette {
    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .light ? .black : .white
    }

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color(red: 0.46, green: 0.30, blue: 0.02) : .yellow
    }
}
