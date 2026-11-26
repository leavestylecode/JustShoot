import SwiftUI

enum ToneCurvePlot {
    static func position(input: CGFloat, output: CGFloat, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + input * bounds.width, y: bounds.maxY - output * bounds.height)
    }

    static func path(for samples: [Float], in bounds: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        for (index, output) in samples.enumerated() {
            let input = CGFloat(index) / CGFloat(samples.count - 1)
            let point = position(input: input, output: CGFloat(output), in: bounds)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    static func grid(divisions: Int, in bounds: CGRect) -> Path {
        var path = Path()
        for index in 1..<divisions {
            let fraction = CGFloat(index) / CGFloat(divisions)
            path.move(to: position(input: fraction, output: 0, in: bounds))
            path.addLine(to: position(input: fraction, output: 1, in: bounds))
            path.move(to: position(input: 0, output: fraction, in: bounds))
            path.addLine(to: position(input: 1, output: fraction, in: bounds))
        }
        return path
    }

    /// The enclosed lobes show the change from equal input and output.
    static func differenceArea(for response: Path, in bounds: CGRect) -> Path {
        guard !response.isEmpty else { return Path() }
        var area = response
        area.addLine(to: position(input: 1, output: 1, in: bounds))
        area.addLine(to: position(input: 0, output: 0, in: bounds))
        area.closeSubpath()
        return area
    }
}

struct CurveGraphView: View {
    let data: CurvePreviewData
    let accent: Color
    private let showsGrid: Bool
    private let shadesDifference: Bool
    private let guideColor: Color

    init(data: CurvePreviewData, accent: Color, showsGrid: Bool = false, guideColor: Color? = nil,
         shadesDifference: Bool = false) {
        self.data = data
        self.accent = accent
        self.showsGrid = showsGrid
        self.shadesDifference = shadesDifference
        self.guideColor = guideColor ?? accent
    }

    init(curve: FilmCurve, accent: Color) {
        self.init(data: curve.previewData, accent: accent)
    }

    private static let red = Color(red: 0.88, green: 0.22, blue: 0.22)
    private static let green = Color(red: 0.13, green: 0.58, blue: 0.30)
    private static let blue = Color(red: 0.19, green: 0.43, blue: 0.90)

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let traces: [(path: Path, color: Color)]
            if let shared = data.sharedRGBResponse {
                traces = [(ToneCurvePlot.path(for: shared, in: bounds), accent)]
            } else {
                traces = [(data.red, Self.red), (data.green, Self.green), (data.blue, Self.blue)].map {
                    (ToneCurvePlot.path(for: $0.0, in: bounds), $0.1)
                }
            }

            if shadesDifference {
                let opacity = data.usesChannelCurves ? 0.08 : 0.20
                for trace in traces {
                    context.fill(ToneCurvePlot.differenceArea(for: trace.path, in: bounds),
                        with: .color(trace.color.opacity(opacity)), style: FillStyle(eoFill: true))
                }
            }
            context.stroke(ToneCurvePlot.grid(divisions: showsGrid ? 4 : 2, in: bounds),
                with: .color(guideColor.opacity(showsGrid ? 0.18 : 0.10)), lineWidth: 0.5)
            context.stroke(ToneCurvePlot.path(for: [0, 1], in: bounds), with: .color(guideColor.opacity(0.35)),
                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

            let style = StrokeStyle(lineWidth: data.usesChannelCurves ? 1.25 : 2, lineCap: .round, lineJoin: .round)
            for trace in traces {
                context.stroke(trace.path, with: .color(trace.color), style: style)
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
        CurveGraphView(data: preset.previewData, accent: .primary, showsGrid: true, shadesDifference: true)
            .padding(10)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
            .frame(maxWidth: PageLayout.curveEditorWidth)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tone Curve")
            .accessibilityValue(Text("Input runs left to right and output runs bottom to top, both from 0 to 255. \(preset.summary)"))
    }
}
