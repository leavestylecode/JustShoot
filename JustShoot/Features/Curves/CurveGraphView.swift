import SwiftUI

struct CurveGraphView: View {
    let data: CurvePreviewData
    let accent: Color

    init(data: CurvePreviewData, accent: Color) {
        self.data = data
        self.accent = accent
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

            var midtoneGuide = Path()
            midtoneGuide.move(to: CGPoint(x: size.width / 2, y: 2))
            midtoneGuide.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            context.stroke(midtoneGuide, with: .color(.white.opacity(0.07)), lineWidth: 0.5)

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

/// Both the curve library and the film guide use the same graph and output scale.
struct CurveResponsePreview: View {
    let data: CurvePreviewData

    var body: some View {
        VStack(spacing: 6) {
            CurveGraphView(data: data, accent: .white)
                .aspectRatio(220.0 / 60, contentMode: .fit)
            CurveOutputStrip(data: data)
                .frame(height: 5)
        }
        .padding(8)
        .background(Color(white: 0.085), in: .rect(cornerRadius: 9))
    }
}
