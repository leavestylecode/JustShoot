import SwiftUI
import UIKit

enum CameraPickerStyle {
    case standard
    case iPhoneCamera
    case iPadOverlay

    var rowHorizontalInset: CGFloat {
        switch self {
        case .standard: 12
        case .iPhoneCamera: 0 // The camera layout aligns the rows with the capture bar.
        case .iPadOverlay: 16
        }
    }

    func itemSize(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        switch self {
        case .standard, .iPhoneCamera: sizeClass == .regular ? 80 : 64
        case .iPadOverlay: sizeClass == .regular ? 68 : 60
        }
    }

    func rowHeight(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        itemSize(for: sizeClass) + (sizeClass == .regular ? 12 : 10)
    }
}

private struct CameraPickerRow<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let style: CameraPickerStyle
    var isPreview = false
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: style == .iPadOverlay ? 8 : 10) {
                    content(style.itemSize(for: sizeClass))
                }
                .padding(.horizontal, isPreview ? 0 : style.rowHorizontalInset)
                .frame(minWidth: style == .iPadOverlay && !isPreview ? geometry.size.width : nil,
                    minHeight: geometry.size.height)
            }
        }
        .frame(height: style.rowHeight(for: sizeClass))
    }
}

// MARK: - 底部胶片选择条
/// 右下角胶片封面点开后从底部弹出的横向胶片选择条。胶片顺序：
///   用户已添加的胶片与导入的自定义 LUT，沿用首页的显示顺序。
/// 当前选中胶片用黄色描边标识；点击后通过 onSelect 更新预览，面板保持展开以便连续比较。
/// 展开瞬间 ScrollViewReader 自动滚到当前胶片，便于看到"我现在在哪一张"。
struct FilmSourcePickerStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            CameraPickerRow(style: style) { itemSize in
                ForEach(sources) { source in
                    FilmSourcePickerCell(
                        source: source,
                        isSelected: source.id == current.id,
                        contentRotation: contentRotation,
                        orientation: orientation,
                        preparedImage: preparedCover(for: source),
                        style: style,
                        size: itemSize
                    ) { onSelect(source) }
                    .id(source.id)
                }
            }
            .task {
                proxy.scrollTo(current.id, anchor: .center)
            }
            .onChange(of: current.id) { _, newId in
                // 预览区左右滑动切胶片时 picker 条同步把新选中胶片滚到中心。
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Film picker"))
        }
    }

    private func preparedCover(for source: FilmSource) -> UIImage? {
        guard case .preset(let preset) = source else { return nil }
        return preparedCovers[preset]
    }
}

// MARK: - 曲线选择条
/// 拍摄页用它选择曲线，曲线管理页用同样的卡片预览已启用的曲线。
struct FilmCurvePickerStrip: View {
    enum Presentation: Equatable, Sendable {
        case camera, preview, sortingPreview
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let curves: [FilmCurve]
    let current: FilmCurve
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    var style: CameraPickerStyle = .standard
    var presentation: Presentation = .camera
    var onManage: (() -> Void)? = nil
    var onSelect: ((FilmCurve) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            CameraPickerRow(style: style, isPreview: presentation != .camera) { itemSize in
                ForEach(curves) { curve in
                    FilmCurvePickerCell(
                        curve: curve,
                        isSelected: curve == current,
                        contentRotation: contentRotation,
                        orientation: orientation,
                        style: style,
                        size: itemSize,
                        isPreview: presentation != .camera,
                        onTap: onSelect.map { select in { select(curve) } }
                    )
                    .id(curve.id)
                }
                if let onManage {
                    CurveManagerPickerCell(
                        contentRotation: contentRotation,
                        orientation: orientation,
                        style: style,
                        size: style == .iPadOverlay ? 44 : itemSize,
                        onTap: onManage
                    )
                }
            }
            .task(id: presentation) {
                switch presentation {
                case .camera:
                    proxy.scrollTo(current.id, anchor: .center)
                case .sortingPreview:
                    if let first = curves.first {
                        proxy.scrollTo(first.id, anchor: .center)
                    }
                case .preview:
                    break
                }
            }
            .onChange(of: current.id) { _, newID in
                guard presentation == .camera else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presentation == .camera ? Text("Curve picker") : Text("Preview"))
            .environment(\.colorScheme, presentation == .camera ? colorScheme : .dark)
        }
    }
}

private struct CameraPickerCard<Content: View>: View {
    let size: CGFloat
    let style: CameraPickerStyle
    let isSelected: Bool
    var showsSelectionBorder = true
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let onTap: (() -> Void)?
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .iPadOverlay ? 12 : 10, style: .continuous)
        let highlightsBorder = isSelected && showsSelectionBorder
        let enlargesSelection = !reduceMotion && style == .standard && onTap != nil
        let card = content
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(highlightsBorder ? CameraPalette.accent(for: colorScheme) : .primary.opacity(0.10),
                    lineWidth: highlightsBorder ? (style == .iPadOverlay ? 1.5 : 2) : 0.5)
            }
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: orientation)
            .scaleEffect(enlargesSelection && isSelected ? 1.06 : 1)
            .animation(enlargesSelection ? .spring(duration: 0.28, bounce: 0.25) : nil, value: isSelected)
            .contentShape(shape)

        Group {
            if let onTap {
                Button(action: onTap) { card }
                    .buttonStyle(.plain)
            } else {
                card.accessibilityElement(children: .ignore)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FilmCurvePickerCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let curve: FilmCurve
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let style: CameraPickerStyle
    let size: CGFloat
    let isPreview: Bool
    let onTap: (() -> Void)?

    var body: some View {
        let foreground = CameraPalette.foreground(for: colorScheme)
        CameraPickerCard(size: size, style: style, isSelected: isSelected, showsSelectionBorder: !isPreview,
            contentRotation: contentRotation, orientation: orientation, onTap: onTap) {
            VStack(spacing: 3) {
                Text(curve.displayName)
                    .font(.system(size: size >= 68 ? 11 : 10, weight: isSelected ? .bold : .semibold,
                        design: .rounded))
                    .foregroundStyle(isSelected ? CameraPalette.accent(for: colorScheme) : foreground.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                CurveGraphView(curve: curve, accent: .white)
                    .frame(height: size / 2)
                    .background {
                        if colorScheme == .light {
                            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08))
                        }
                    }

                CurveOutputStrip(curve: curve)
                    .frame(height: 5)
            }
            .frame(width: size - 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LinearGradient(
                    colors: [isSelected ? accentColor.opacity(0.22) : foreground.opacity(0.10), foreground.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(isPreview ? Color(white: 0.08) : .clear)
            }
        }
        .accessibilityLabel(Text(curve.displayName))
    }

    private var accentColor: Color {
        curve.builtInPreset?.graphAccent ?? Color(red: 0.38, green: 0.82, blue: 0.72)
    }
}

private struct CurveManagerPickerCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let style: CameraPickerStyle
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        let foreground = CameraPalette.foreground(for: colorScheme)
        CameraPickerCard(size: size, style: style, isSelected: false,
            contentRotation: contentRotation, orientation: orientation, onTap: onTap) {
            VStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                if style != .iPadOverlay {
                    Text("Manage")
                        .font(.system(size: size >= 68 ? 11 : 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground.opacity(0.84))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(foreground.opacity(style == .iPadOverlay ? 0.035 : 0.07))
        }
        .accessibilityLabel("Manage film curves")
    }
}

private struct FilmSourcePickerCell: View {
    let source: FilmSource
    let isSelected: Bool
    let contentRotation: Angle
    let orientation: UIDeviceOrientation
    let preparedImage: UIImage?
    let style: CameraPickerStyle
    let size: CGFloat
    let onTap: () -> Void

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private static let customAccent = Color(red: 0.6, green: 0.5, blue: 0.8)

    var body: some View {
        CameraPickerCard(size: size, style: style, isSelected: isSelected,
            contentRotation: contentRotation, orientation: orientation, onTap: onTap) {
            cover
        }
        .accessibilityLabel(Text(source.displayName))
        .task(id: source.id) {
            if let preparedImage { image = preparedImage; return }
            // 仅 preset 有 catalog 封面；custom LUT 用占位图标渲染。
            guard case .preset(let preset) = source, let imageName = preset.libraryCardImage else {
                image = nil
                return
            }
            let loaded = await FilmCardImageCache.shared.loadImage(
                imageName: imageName,
                maxPixel: FilmPresetCoverPreparation.pickerPixel(displayScale: displayScale)
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var cover: some View {
        ZStack {
            switch source {
            case .preset:
                Color.primary.opacity(0.05)
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
    }
}
