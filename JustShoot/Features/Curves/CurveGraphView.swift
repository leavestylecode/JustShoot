import SwiftUI

struct CurveGraphView: View {
    let data: CurvePreviewData
    let accent: Color
    private let showsGrid: Bool

    init(data: CurvePreviewData, accent: Color, showsGrid: Bool = false) {
        self.data = data
        self.accent = accent
        self.showsGrid = showsGrid
    }

    init(curve: FilmCurve, accent: Color) {
        self.init(data: curve.previewData, accent: accent)
    }

    private static let red = Color(red: 1.00, green: 0.30, blue: 0.28)
    private static let green = Color(red: 0.22, green: 0.86, blue: 0.40)
    private static let blue = Color(red: 0.26, green: 0.52, blue: 1.00)

    var body: some View {
        Canvas { context, size in
            let identity = CurveMath.identityTable

            var guides = Path()
            let divisions = showsGrid ? 4 : 2
            for index in 1..<divisions {
                let fraction = CGFloat(index) / CGFloat(divisions)
                let x = 2 + (size.width - 4) * fraction
                guides.move(to: CGPoint(x: x, y: 2))
                guides.addLine(to: CGPoint(x: x, y: size.height - 2))
                if showsGrid {
                    let y = 2 + (size.height - 4) * fraction
                    guides.move(to: CGPoint(x: 2, y: y))
                    guides.addLine(to: CGPoint(x: size.width - 2, y: y))
                }
            }
            context.stroke(guides, with: .color(.white.opacity(showsGrid ? 0.14 : 0.07)), lineWidth: 0.5)

            let identityPath = Self.linePath(from: identity, in: size)
            context.stroke(
                identityPath,
                with: .color(.white.opacity(0.24)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [2, 2])
            )

            if data.master != identity {
                context.fill(
                    Self.deltaPath(curve: data.master, identity: identity, in: size),
                    with: .color(accent.opacity(0.20))
                )
            }

            if data.usesChannelCurves {
                for (values, color) in [
                    (data.red, Self.red),
                    (data.green, Self.green),
                    (data.blue, Self.blue)
                ] {
                    context.stroke(
                        Self.linePath(from: values, in: size),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            context.stroke(
                Self.linePath(from: data.master, in: size),
                with: .color(data.usesChannelCurves ? .white.opacity(0.88) : accent),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func linePath(from values: [Float], in size: CGSize) -> Path {
        var path = Path()
        let inset: CGFloat = 2
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        for (i, v) in values.enumerated() {
            let x = inset + width * CGFloat(i) / CGFloat(values.count - 1)
            let y = inset + height * CGFloat(1.0 - Double(v))
            let point = CGPoint(x: x, y: y)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private static func deltaPath(curve: [Float], identity: [Float], in size: CGSize) -> Path {
        var path = linePath(from: curve, in: size)
        let inset: CGFloat = 2
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        for index in identity.indices.reversed() {
            let x = inset + width * CGFloat(index) / CGFloat(identity.count - 1)
            let y = inset + height * CGFloat(1.0 - Double(identity[index]))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 五档输出色阶
/// 比曲线图更直接地显示黑位、暗部、中间调、高光和白点；RGB 曲线的色偏也会真实显现。
struct CurveOutputStrip: View {
    let data: CurvePreviewData

    init(data: CurvePreviewData) { self.data = data }
    init(curve: FilmCurve) { self.init(data: curve.previewData) }

    private static let inputs: [Float] = [0.03, 0.18, 0.42, 0.70, 0.96]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Self.inputs.indices, id: \.self) { index in
                let sample = data.sampleGray(Self.inputs[index])
                Rectangle()
                    .fill(
                        Color(
                            red: Double(sample.red),
                            green: Double(sample.green),
                            blue: Double(sample.blue)
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

extension CurvePreset {
    var graphAccent: Color {
        switch self {
        case .none: Color(white: 0.82)
        case .filmSoft: Color(red: 0.96, green: 0.70, blue: 0.32)
        case .punch: Color(red: 1, green: 0.38, blue: 0.30)
        case .matte: Color(red: 0.78, green: 0.66, blue: 0.52)
        case .fadedS: Color(red: 0.88, green: 0.65, blue: 0.58)
        case .crossProcess: Color(red: 0.92, green: 0.34, blue: 0.72)
        }
    }
}

struct CurveResponsePreview: View {
    let preset: CurvePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tone Curve")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Label("Read Only", systemImage: "lock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }

            VStack(spacing: 8) {
                CurveGraphView(data: preset.previewData, accent: preset.graphAccent, showsGrid: true)
                    .aspectRatio(2.2, contentMode: .fit)
                CurveOutputStrip(data: preset.previewData).frame(height: 7)
                HStack {
                    Text("Shadows")
                    Spacer()
                    Text("Highlights")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(Color(white: 0.095), in: .rect(cornerRadius: 18))
    }
}
