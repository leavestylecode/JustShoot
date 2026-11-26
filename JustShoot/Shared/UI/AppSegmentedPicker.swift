import SwiftUI

struct AppSegmentedPicker<Option: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Option
    let options: [Option]
    var size: ControlSize = .regular
    let label: (Option) -> Text

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(iOS 26.0, *) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    label(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(size)
            .labelsHidden()
            .accessibilityLabel(Text(title))
        } else {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let isSelected = selection == option
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = option }
                    } label: {
                        label(option)
                            .font((size == .small ? Font.caption : .subheadline).weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: segmentHeight)
                            .background {
                                if isSelected {
                                    Capsule().fill(colorScheme == .dark ? .white.opacity(0.20) : .white)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.65)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        }
    }

    private var segmentHeight: CGFloat {
        switch size {
        case .mini, .small: 22
        case .regular: 28
        default: 42
        }
    }
}
