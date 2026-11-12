import SwiftUI
import SwiftData
import UIKit

enum CameraPickerStyle {
    case standard
    case iPadOverlay
}

// MARK: - 底部胶片选择条
/// 右下角胶片封面点开后从底部弹出的横向胶片选择条。胶片顺序：
///   用户已添加的胶片与导入的自定义 LUT，沿用首页的显示顺序。
/// 当前选中胶片用黄色描边标识；点击后通过 onSelect 更新预览，面板保持展开以便连续比较。
/// 展开瞬间 ScrollViewReader 自动滚到当前胶片，便于看到"我现在在哪一张"。
struct FilmSourcePickerStrip: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let current: FilmSource
    let sources: [FilmSource]
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var preparedCovers: [FilmPreset: UIImage] = [:]
    var style: CameraPickerStyle = .standard
    let onSelect: (FilmSource) -> Void

    /// Completion means the bounded worker finished preparing the covers for display.
    /// A caller that needs eviction-proof first paint can retain the returned snapshot.
    static func preloadCovers(presets: [FilmPreset] = FilmPreset.allCases, displayScale: CGFloat) async throws -> [FilmPreset: UIImage] {
        try await FilmPresetCoverPreparation.preparePicker(presets: presets, displayScale: displayScale)
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: style == .iPadOverlay ? 8 : 10) {
                        ForEach(sources) { s in
                            FilmSourcePickerCell(
                                source: s,
                                isSelected: s.id == current.id,
                                contentRotation: contentRotation,
                                orientation: orientation,
                                preparedImage: { if case .preset(let preset) = s { return preparedCovers[preset] }; return nil }(),
                                style: style
                            ) { onSelect(s) }
                            .id(s.id)
                        }
                    }
                    .padding(.horizontal, style == .iPadOverlay ? 16 : 12)
                    .padding(.vertical, 8)
                    .frame(minWidth: style == .iPadOverlay ? geometry.size.width : nil)
                }
            }
            .frame(height: style == .iPadOverlay
                ? (sizeClass == .regular ? 88 : 76) : (sizeClass == .regular ? 88 : 68))
            .onAppear {
                // 展开后下一帧滚到当前胶片，避免 ScrollView 还没布局完就 scrollTo 失效。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .onChange(of: current.id) { _, newId in
                // 预览区左右滑动切胶片时 picker 条同步把新选中胶片滚到中心。
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Film picker"))
        }
    }
}

// MARK: - 曲线选择条
/// 只展示用户启用的内置/自定义曲线；末尾的管理入口可直接调整显隐或创建新效果。
struct FilmCurvePickerStrip: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let curves: [FilmCurve]
    let current: FilmCurve
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var style: CameraPickerStyle = .standard
    let onManage: () -> Void
    let onSelect: (FilmCurve) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(curves) { curve in
                            FilmCurvePickerCell(
                                curve: curve,
                                isSelected: curve == current,
                                contentRotation: contentRotation,
                                orientation: orientation,
                                style: style
                            ) { onSelect(curve) }
                            .id(curve.id)
                        }
                        CurveManagerPickerCell(
                            contentRotation: contentRotation,
                            orientation: orientation,
                            style: style,
                            onTap: onManage
                        )
                    }
                    .padding(.horizontal, style == .iPadOverlay ? 16 : 10)
                    .padding(.vertical, 5)
                    .frame(minWidth: style == .iPadOverlay ? geometry.size.width : nil)
                }
            }
            .frame(height: style == .iPadOverlay
                ? (sizeClass == .regular ? 72 : 64) : (sizeClass == .regular ? 98 : 78))
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
            .onChange(of: current.id) { _, newID in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Curve picker"))
        }
    }
}

// MARK: - 曲线效果卡
struct FilmCurvePickerCell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let curve: FilmCurve
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var style: CameraPickerStyle = .standard
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            Group {
                if style == .iPadOverlay {
                    iPadCurveCard
                } else {
                    FilmCurvePreviewCard(curve: curve, isSelected: isSelected,
                        cardSize: sizeClass == .regular ? CGSize(width: 88, height: 88) : CGSize(width: 68, height: 68),
                        graphSize: sizeClass == .regular ? CGSize(width: 70, height: 46) : CGSize(width: 54, height: 34))
                }
            }
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
            .scaleEffect(reduceMotion || style == .iPadOverlay ? 1.0 : (isSelected ? 1.04 : 1.0))
            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.22), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(curve.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var iPadCurveCard: some View {
        VStack(spacing: 4) {
            CurveGraphView(curve: curve, accent: isSelected ? .yellow : .white.opacity(0.8))
                .frame(width: sizeClass == .regular ? 50 : 44, height: 26)
            Text(curve.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .yellow : .white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: sizeClass == .regular ? 72 : 64, height: sizeClass == .regular ? 62 : 54)
        .background(isSelected ? .yellow.opacity(0.08) : .white.opacity(0.035), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.yellow.opacity(0.85) : .white.opacity(0.07),
                    lineWidth: isSelected ? 1 : 0.5)
        }
    }
}

/// 拍摄条与曲线管理页共用的视觉组件，确保两处展示的是同一套名称、曲线差异和输出色阶。
struct FilmCurvePreviewCard: View {
    let curve: FilmCurve
    let isSelected: Bool
    var cardSize = CGSize(width: 68, height: 68)
    var graphSize = CGSize(width: 54, height: 34)

    var body: some View {
        VStack(spacing: 3) {
            Text(curve.displayName)
                .font(.system(
                    size: cardSize.width > 80 ? 12 : 9,
                    weight: isSelected ? .bold : .semibold,
                    design: .rounded
                ))
                .foregroundStyle(isSelected ? .yellow : .white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            CurveGraphView(curve: curve, accent: accentColor)
                .frame(width: graphSize.width, height: graphSize.height)

            CurveOutputStrip(curve: curve)
                .frame(width: graphSize.width, height: 5)
        }
        .padding(6)
        .frame(width: cardSize.width, height: cardSize.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            isSelected ? accentColor.opacity(0.22) : .white.opacity(0.10),
                            .white.opacity(0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.yellow : .white.opacity(0.14),
                    lineWidth: isSelected ? 2 : 0.5
                )
        }
        .shadow(
            color: isSelected ? accentColor.opacity(0.35) : .clear,
            radius: 7,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var accentColor: Color {
        switch curve.builtInPreset {
        case .some(.none): return Color(white: 0.82)
        case .some(.filmSoft): return Color(red: 0.96, green: 0.70, blue: 0.32)
        case .some(.punch): return Color(red: 1.00, green: 0.38, blue: 0.30)
        case .some(.matte): return Color(red: 0.78, green: 0.66, blue: 0.52)
        case .some(.crossProcess): return Color(red: 0.92, green: 0.34, blue: 0.72)
        case nil: return Color(red: 0.38, green: 0.82, blue: 0.72)
        }
    }
}

private struct CurveManagerPickerCell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var style: CameraPickerStyle = .standard
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                if style == .standard {
                    Text("Manage")
                        .font(.system(size: sizeClass == .regular ? 12 : 9, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.84))
            .frame(width: style == .iPadOverlay ? 44 : (sizeClass == .regular ? 88 : 68),
                height: style == .iPadOverlay ? 44 : (sizeClass == .regular ? 88 : 68))
            .background(Color.white.opacity(style == .iPadOverlay ? 0.035 : 0.07), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            }
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage film curves")
    }
}

// MARK: - 曲线差异图
/// 虚线是恒等响应；半透明面积直接显示预设相对恒等线提亮/压暗了多少。
/// 只有实际响应不同的 RGB 通道才画三线；相同通道只画一条合成线。
struct FilmSourcePickerCell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let source: FilmSource
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var preparedImage: UIImage? = nil
    var style: CameraPickerStyle = .standard
    let onTap: () -> Void

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    /// Reduce Motion 时关闭 selected 状态的 scaleEffect bounce——它是装饰性放大，
    /// 黄色描边已足以表达选中。rotation 跟随设备方向是功能性的（让用户横握时看清内容），
    /// HIG 不视为应抑制的 motion，保留。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let customAccent = Color(red: 0.6, green: 0.5, blue: 0.8)
    static let coverSize: CGFloat = 52
    private var displayCoverSize: CGFloat {
        sizeClass == .regular ? (style == .iPadOverlay ? 64 : 72) : Self.coverSize
    }

    /// 封面解码像素：52pt × scale × 1.5 余量，下限 100。供 cell 的 .task 与
    /// `FilmSourcePickerStrip.preloadCovers` 共用，确保预热与实际加载的 maxPixel 一致。
    static func coverPixel(displayScale: CGFloat) -> Int {
        FilmPresetCoverPreparation.pickerPixel(displayScale: displayScale)
    }

    var body: some View {
        Button(action: onTap) {
            // 整块随设备方向旋转，与右下角封面 / 左下角照片角标同款手感。cell 只有极淡描边
            // （未选 0.08 / 选中黄 2pt），不像 glass 那样有高光，整块旋转不显得放大。
            cover
                .frame(width: displayCoverSize, height: displayCoverSize)
                .padding(style == .iPadOverlay ? 4 : 0)
                .overlay {
                    RoundedRectangle(cornerRadius: style == .iPadOverlay ? 12 : 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.yellow : .white.opacity(style == .iPadOverlay ? 0 : 0.08),
                            lineWidth: isSelected ? (style == .iPadOverlay ? 1.5 : 2) : 0.5)
                }
                .rotationEffect(contentRotation)
                .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
                .scaleEffect(reduceMotion || style == .iPadOverlay ? 1.0 : (isSelected ? 1.06 : 1.0))
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(source.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: source.id) {
            if let preparedImage { image = preparedImage; return }
            // 仅 preset 有 catalog 封面；custom LUT 用占位图标渲染。
            guard case .preset(let preset) = source, let imageName = preset.libraryCardImage else {
                image = nil
                return
            }
            let loaded = await FilmCardImageCache.shared.loadImage(
                imageName: imageName,
                maxPixel: Self.coverPixel(displayScale: displayScale)
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    @ViewBuilder
    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            switch source {
            case .preset:
                Color.white.opacity(0.05)
                if let image = preparedImage ?? image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            case .custom:
                Self.customAccent.opacity(0.18)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Self.customAccent)
            }
        }
        .clipShape(shape)
    }
}
