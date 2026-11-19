import SwiftUI

enum SettingsIconStyle: String, CaseIterable {
    static let key = "appearance.settingsIconStyle"
    case standard, monochrome, subtle

    var title: LocalizedStringKey {
        switch self {
        case .standard: "Standard"
        case .monochrome: "Monochrome"
        case .subtle: "Subtle"
        }
    }
}

struct SettingsIcon: View {
    @AppStorage(SettingsIconStyle.key) private var style = SettingsIconStyle.standard
    @Environment(\.colorSchemeContrast) private var contrast
    private let symbol: String
    private let color: Color

    init(_ symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    static var language: Self { Self("globe", color: .blue) }
    static var preferences: Self { Self("gearshape.circle.fill", color: .indigo) }
    static var appearance: Self { Self("circle.hexagongrid.circle.fill", color: .purple) }
    static var author: Self { Self("person.circle.fill", color: .teal) }
    static var rating: Self {
        Self("star.circle.fill", color: Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0.95, green: 0.76, blue: 0.35, alpha: 1)
            }
            return UIColor(red: 0.68, green: 0.45, blue: 0, alpha: 1)
        }))
    }
    static var share: Self { Self("heart.circle.fill", color: .red) }

    private var tint: Color {
        switch style {
        case .standard: color
        case .monochrome: .primary
        case .subtle: .primary.opacity(contrast == .increased ? 0.7 : 0.4)
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }
}

enum SettingsChevron: View {
    case forward, down

    var body: some View {
        Image(systemName: self == .forward ? "chevron.forward" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

struct SettingRow: View {
    let icon: SettingsIcon
    let title: LocalizedStringKey
    var value: String? = nil
    var chevron: SettingsChevron? = nil

    var body: some View {
        HStack(spacing: 15) {
            icon
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
            chevron
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
