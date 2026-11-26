import SwiftUI

struct BackgroundGradientOptions: View {
    private var preferences = PageBackgroundPreferences()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVStack(spacing: 16) {
            section("Theme Selection") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(BackgroundPalette.allCases, id: \.self) { palette in
                        paletteButton(palette)
                    }
                }
            }
            section("Gradient Direction") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(GradientOrigin.allCases, id: \.self) { origin in
                        directionButton(origin)
                    }
                }
                .frame(maxWidth: 252)
                .padding(.bottom, 8)
            }
        }
        .sensoryFeedback(.selection, trigger: preferences.palette)
        .sensoryFeedback(.selection, trigger: preferences.origin)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
                .padding(16)
                .frame(maxWidth: .infinity)
                .settingsGlassCard()
        }
    }

    private func paletteButton(_ palette: BackgroundPalette) -> some View {
        let selected = preferences.palette == palette
        let highlighted = selected && preferences.isEnabled
        return Button {
            preferences.palette = palette
        } label: {
            VStack(spacing: 10) {
                GradientSwatch(palette: palette, origin: preferences.origin,
                               intensity: preferences.intensity, diameter: 50)
                    .overlay {
                        if highlighted {
                            Circle().stroke(ring(for: palette), lineWidth: 3)
                                .frame(width: 56, height: 56)
                        }
                    }
                    .saturation(preferences.isEnabled ? 1 : 0.3)
                    .scaleEffect(highlighted ? 1.05 : 1)
                    .frame(width: 60, height: 60)
                Text(palette.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(selected ? 1 : 0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(tileFill(selected: highlighted), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(highlighted ? 0.3 : 0.1), lineWidth: highlighted ? 1.5 : 0.5)
            }
            .contentShape(Rectangle())
            .animation(.bouncy(duration: 0.3), value: highlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(palette.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func directionButton(_ origin: GradientOrigin) -> some View {
        let selected = preferences.origin == origin
        let highlighted = selected && preferences.isEnabled
        return Button {
            preferences.origin = origin
        } label: {
            GradientSwatch(palette: preferences.palette, origin: origin,
                           intensity: preferences.intensity, diameter: 40)
                .overlay {
                    Circle()
                        .fill(.white)
                        .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5) }
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: (origin.point.x - 0.5) * 24, y: (origin.point.y - 0.5) * 24)
                }
                .frame(width: 60, height: 60)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black.opacity(0.18))
                        .overlay { RoundedRectangle(cornerRadius: 16).fill(tileFill(selected: highlighted)) }
                }
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(ring(for: preferences.palette), lineWidth: 2)
                    }
                }
                .scaleEffect(highlighted ? 1.03 : 1)
                .animation(.bouncy(duration: 0.25), value: highlighted)
                .frame(maxWidth: 76, minHeight: 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(origin.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tileFill(selected: Bool) -> LinearGradient {
        LinearGradient(colors: [.white.opacity(selected ? 0.15 : 0.06), .white.opacity(selected ? 0.08 : 0.02)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func ring(for palette: BackgroundPalette) -> LinearGradient {
        LinearGradient(colors: [.white, palette.colors.inner, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct GradientSwatch: View {
    let palette: BackgroundPalette
    let origin: GradientOrigin
    let intensity: Double
    let diameter: CGFloat

    var body: some View {
        let colors = palette.colors
        let strength = 0.5 + 0.5 * intensity
        Circle()
            .fill(.black)
            .overlay {
                Circle().fill(RadialGradient(
                    colors: [colors.inner.opacity(strength), colors.inner.opacity(strength * 0.9),
                             colors.outer.opacity(strength * 0.7), .black.opacity(0.9)],
                    center: origin.point, startRadius: 0,
                    endRadius: diameter * (origin == .center ? 0.5 : 0.7)))
            }
            .overlay {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.3), .clear], center: UnitPoint(
                    x: min(max(origin.point.x - 0.15, 0.15), 0.85),
                    y: min(max(origin.point.y - 0.15, 0.15), 0.85)
                ), startRadius: 2, endRadius: diameter * 0.36))
            }
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}
