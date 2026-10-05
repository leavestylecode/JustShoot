import SwiftUI
import UIKit
import AVFoundation

// MARK: - 系统设置跳转
/// 跳转到当前 App 的系统设置页。两处权限被拒流程（相机、定位）共用。
@MainActor
func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

// MARK: - 闪光灯模式
enum FlashMode: String, CaseIterable {
    case on = "on"
    case off = "off"

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .on: return .on
        case .off: return .off
        }
    }
}

// MARK: - 对焦完成通知
extension Notification.Name {
    static let focusDidComplete = Notification.Name("JustShoot.focusDidComplete")
}

// MARK: - UIDeviceOrientation Extension
extension UIDeviceOrientation {
    var isValidInterfaceOrientation: Bool {
        switch self {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }
}

// MARK: - 焦段切换条（仿 iPhone 相机样式）
/// 焦距选择条（iOS 26 Liquid Glass）：整条胶囊容器套 .glassEffect()，
/// 选中项在内部用黄色胶囊高亮，配合 matchedGeometryEffect 在选项间滑动。
/// 视觉与 iPhone 17 Camera 对齐：玻璃质感不依赖背景，亮/暗场景下都有稳定对比度。
/// **交互**：tap 单点切换 + 横向 drag 滑动选档（手指落在哪个胶囊就选哪个），
///          drag 跨选项时通过 onSelect 自然触发逐档切换 + 触感反馈。
/// **方向**：`contentRotation` 仅旋转每个选项的数字 Text，整条容器/选中胶囊位置不变,
///          与 iPhone Camera 横屏时"数字转向、容器不动"行为一致。
struct FocalLengthStrip: View {
    let focalInfo: DeviceFocalInfo
    let current: FocalLengthOption
    let contentRotation: Angle
    let onSelect: (FocalLengthOption) -> Void

    @Namespace private var selectionNamespace
    @State private var lastDraggedOption: FocalLengthOption?

    /// 单个胶囊宽度 + spacing，用于 drag 命中检测（与 focalButton frame.width=36 + HStack spacing=2 一致）
    private static let buttonStride: CGFloat = 38
    /// HStack 容器的水平 padding（用于把 drag x 坐标减去 leading inset）
    private static let leadingInset: CGFloat = 6
    /// 视图坐标空间名称
    private static let coordSpace = NamedCoordinateSpace.named("focalStrip")

    var body: some View {
        if focalInfo.options.count <= 1 {
            EmptyView()
        } else {
            HStack(spacing: 2) {
                ForEach(focalInfo.options) { option in
                    Button { onSelect(option) } label: {
                        focalButton(for: option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(option.rawValue)mm equivalent focal length"))
                    .accessibilityAddTraits(option == current ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, Self.leadingInset)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .coordinateSpace(Self.coordSpace)
            // simultaneousGesture：tap 与 drag 共存——静态点击仍走 Button.action，移动 ≥8pt 时
            // 进入 drag 路径。两者最终都通过 onSelect 触发同一切档逻辑（haptic + setFocalLength）。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: Self.coordSpace)
                    .onChanged { value in
                        let count = focalInfo.options.count
                        guard count > 0 else { return }
                        let x = max(0, value.location.x - Self.leadingInset)
                        let index = min(count - 1, max(0, Int(x / Self.buttonStride)))
                        let option = focalInfo.options[index]
                        // 仅在跨入新选项时触发；首次进入时如果落点已是当前档则跳过，避免重复 setFocalLength。
                        guard option != lastDraggedOption else { return }
                        lastDraggedOption = option
                        if option != current {
                            onSelect(option)
                        }
                    }
                    .onEnded { _ in
                        lastDraggedOption = nil
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Focal length selector")
        }
    }

    @ViewBuilder
    private func focalButton(for option: FocalLengthOption) -> some View {
        let isSelected = option == current
        let isCrop = focalInfo.isDigitalCrop(option)

        Text(option.label)
            .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? .yellow : isCrop ? .white.opacity(0.45) : .white.opacity(0.78))
            // 仅旋转数字本身，胶囊背景与容器位置保持不变（横屏时数字立起来给用户看）
            .rotationEffect(contentRotation)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: contentRotation)
            .frame(width: 36, height: 30)
            .background {
                if isSelected {
                    // matchedGeometryEffect 让选中胶囊在选项间平滑滑动，对齐 iPhone Camera 体验。
                    Capsule()
                        .fill(.yellow.opacity(0.22))
                        .matchedGeometryEffect(id: "focal_selection", in: selectionNamespace)
                }
            }
            .contentShape(Capsule())
            .animation(.spring(duration: 0.32, bounce: 0.18), value: isSelected)
    }
}

// MARK: - 对焦框视图（响应对焦完成 KVO）
struct FocusIndicatorView: View {
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 0.0
    @State private var focusLocked = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: focusLocked ? 1.5 : 1)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDidComplete)) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    focusLocked = true
                    scale = 0.9
                }
                withAnimation(.easeOut(duration: 0.1).delay(0.15)) {
                    scale = 1.0
                }
            }
    }
}

// MARK: - 曝光补偿 sun rail
/// 对焦框旁的 sun 图标 + 细竖轨：tap-to-focus 后跟随手指上下滑动显示当前 EV 偏置。
/// 视觉行程 ±55pt 对应 ±1 EV，与 CameraManager.setExposureBias 的 ±1 软上限一致——
/// sun 触到 rail 端点就是真的触底，不存在"还能拖但视觉不动"的脱节。
/// `isAdjusting` 仅控制 sun 图标缩放反馈，rail 始终显示——避免拖动结束后视觉突然丢失参考。
struct ExposureSunRail: View {
    let bias: Float
    let isAdjusting: Bool

    private static let railHeight: CGFloat = 110
    /// sun 视觉行程对应的最大 EV。与 CameraManager.setExposureBias 的 ±1 EV 上限对齐——
    /// 用户拖到顶 / 底时 sun 恰好停在 rail 端点，视觉与实际触底同步。
    private static let maxVisualEV: Float = 1.0

    private var sunYOffset: CGFloat {
        let normalized = max(-1, min(1, bias / Self.maxVisualEV))
        return -CGFloat(normalized) * (Self.railHeight / 2)
    }

    var body: some View {
        ZStack {
            // 细竖轨：sun 在轨上滑。0.5pt + 高对比黄，亮/暗背景下都能看清
            Capsule()
                .fill(Color.yellow.opacity(0.55))
                .frame(width: 1, height: Self.railHeight)

            // 中位刻度：bias=0 处的横向短线
            Rectangle()
                .fill(Color.yellow.opacity(0.55))
                .frame(width: 7, height: 1)

            // sun 图标：vertical offset 跟随 bias，深色阴影保证白底场景下也可见
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.yellow)
                .shadow(color: .black.opacity(0.55), radius: 2.5, y: 0.5)
                .scaleEffect(isAdjusting ? 1.18 : 1.0)
                .offset(y: sunYOffset)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isAdjusting)
        }
        .frame(width: 22, height: Self.railHeight)
        .animation(.linear(duration: 0.05), value: bias)
        .transition(.opacity)
    }
}

// MARK: - 色温 / 色调

/// A separate hit region keeps slider drags out of the viewfinder's focus/EV/film gesture.
struct WhiteBalanceControl: View {
    let selection: CameraWhiteBalanceSelection
    let tint: CameraTintSelection
    let automaticReading: CameraWhiteBalanceReading?
    let onTemperature: (Float) -> Void
    let onTint: (Float) -> Void
    let onAutomaticTemperature: () -> Void
    let onAutomaticTint: () -> Void
    let onEditingEnded: () -> Void

    private var temperatureValue: Float? {
        selection.isAutomatic ? automaticReading?.temperature : selection.kelvin
    }

    private var tintValue: Float? {
        switch tint {
        case .automatic: automaticReading?.tint
        case .value(let value): value
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                CameraColorSlider(kind: .temperature, value: temperatureValue, automatic: selection.isAutomatic,
                    onChange: onTemperature, onEditingEnded: onEditingEnded)
                    .frame(minWidth: 66, maxWidth: .infinity)
                    .disabled(automaticReading == nil)
                automaticButton(selected: selection.isAutomatic, label: "Auto color temperature",
                    identifier: "camera.white_balance.temperature.auto", action: onAutomaticTemperature)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .background { capsuleBackground }
            .accessibilityElement(children: .contain)

            HStack(spacing: 0) {
                CameraColorSlider(kind: .tint, value: tintValue, automatic: tint.isAutomatic,
                    onChange: onTint, onEditingEnded: onEditingEnded)
                    .frame(minWidth: 66, maxWidth: .infinity)
                    .disabled(automaticReading == nil)
                automaticButton(selected: tint.isAutomatic, label: "Auto tint",
                    identifier: "camera.white_balance.tint.auto", action: onAutomaticTint)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .background { capsuleBackground }
            .accessibilityElement(children: .contain)
        }
        .foregroundStyle(.white)
        .frame(height: 44)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(.black.opacity(0.52))
            .overlay {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom))
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
            .frame(height: 34)
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
    }

    private func automaticButton(selected: Bool, label: LocalizedStringKey, identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Auto")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(selected ? Color(red: 1, green: 0.86, blue: 0.52) : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(selected ? Color.white.opacity(0.10) : .clear, in: .capsule)
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

enum CameraColorSliderKind: Equatable {
    case temperature, tint

    var range: ClosedRange<Float> {
        self == .temperature ? CameraWhiteBalancePolicy.temperatureRange : CameraWhiteBalancePolicy.tintRange
    }

    var step: Float { self == .temperature ? 100 : 1 }

    func normalized(_ value: Float) -> Float? {
        self == .temperature ? CameraWhiteBalancePolicy.temperature(value) : CameraWhiteBalancePolicy.tint(value)
    }

    func text(for value: Float?) -> String {
        guard let value, value.isFinite else { return "—" }
        return self == .temperature ? String(format: "%.0f K", Double(value)) : value == 0 ? "0" : String(format: "%+.0f", Double(value))
    }
}

private struct CameraColorSlider: UIViewRepresentable {
    let kind: CameraColorSliderKind
    let value: Float?
    let automatic: Bool
    let onChange: (Float) -> Void
    let onEditingEnded: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> CameraColorSliderView { CameraColorSliderView() }

    func updateUIView(_ view: CameraColorSliderView, context: Context) {
        view.onChange = onChange
        view.onEditingEnded = onEditingEnded
        view.configure(kind: kind, value: value, automatic: automatic, enabled: isEnabled, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CameraColorSliderView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 90
        return CGSize(width: max(66, width), height: 44)
    }
}

/// Only the thumb layer animates. Camera telemetry and LUT preparation remain at their existing
/// cadence, and no per-frame SwiftUI state updates reach the shutter or camera view.
final class CameraColorSliderView: UIControl {
    var onChange: ((Float) -> Void)?
    var onEditingEnded: (() -> Void)?
    private let number = UILabel()
    private let gradient = CAGradientLayer()
    private let ticks = CAShapeLayer()
    private let thumb = CALayer()
    private var kind: CameraColorSliderKind = .temperature
    private var value: Float?
    private var automatic = true
    private var reduceMotion = false
    private var previousBounds: CGRect = .zero
    private var drag: CameraColorSliderDrag?
    private var lastEmittedValue: Float?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        number.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        number.textAlignment = .center
        number.textColor = UIColor.white.withAlphaComponent(0.88)
        number.adjustsFontSizeToFitWidth = true
        number.minimumScaleFactor = 0.7
        number.isAccessibilityElement = false
        number.accessibilityIdentifier = "color.value"
        addSubview(number)

        gradient.name = "color.track"
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 2.25
        gradient.borderWidth = 0.5
        gradient.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        layer.addSublayer(gradient)
        ticks.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        ticks.lineWidth = 0.5
        gradient.addSublayer(ticks)

        thumb.name = "color.thumb"
        thumb.bounds = CGRect(x: 0, y: 0, width: 12, height: 16)
        thumb.cornerRadius = 6
        thumb.backgroundColor = UIColor(white: 0.97, alpha: 1).cgColor
        thumb.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        thumb.borderWidth = 0.5
        thumb.shadowColor = UIColor.black.cgColor
        thumb.shadowOpacity = 0.3
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 1)
        let grip = CALayer()
        grip.frame = CGRect(x: 5.5, y: 5, width: 1, height: 6)
        grip.cornerRadius = 0.5
        grip.backgroundColor = UIColor.black.withAlphaComponent(0.2).cgColor
        thumb.addSublayer(grip)
        layer.addSublayer(thumb)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: 90, height: 44) }

    private var trackRect: CGRect {
        // With the capsule's 10/6 pt padding, both end regions are 56 pt wide.
        // The value and 44 pt Auto button sit at their respective region centers.
        CGRect(x: 46, y: bounds.midY - 2.25, width: max(12, bounds.width - 52), height: 4.5)
    }

    func configure(kind: CameraColorSliderKind, value: Float?, automatic: Bool, enabled: Bool, reduceMotion: Bool) {
        let next = value.flatMap { $0.isFinite ? $0 : nil }
        isEnabled = enabled && next != nil
        if !isEnabled, drag != nil { cancelTracking(with: nil) }
        guard drag == nil else { return }
        let changed = self.kind != kind || self.value != next || self.automatic != automatic || self.reduceMotion != reduceMotion
        let hadValue = self.value != nil
        self.kind = kind
        self.value = next
        self.automatic = automatic
        self.reduceMotion = reduceMotion
        accessibilityIdentifier = kind == .temperature ? "camera.white_balance.temperature" : "camera.white_balance.tint"
        accessibilityLabel = kind == .temperature ? String(localized: "Color temperature") : String(localized: "Tint")
        accessibilityHint = kind == .temperature ? String(localized: "Adjust color temperature") : String(localized: "Adjust green and magenta tint")
        updateReadout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = kind == .temperature
            ? [UIColor(red: 0.26, green: 0.58, blue: 0.96, alpha: 1).cgColor,
               UIColor(red: 0.75, green: 0.85, blue: 0.88, alpha: 1).cgColor,
               UIColor(red: 1, green: 0.79, blue: 0.31, alpha: 1).cgColor]
            : [UIColor(red: 0.29, green: 0.77, blue: 0.50, alpha: 1).cgColor,
               UIColor(red: 0.80, green: 0.83, blue: 0.79, alpha: 1).cgColor,
               UIColor(red: 0.91, green: 0.43, blue: 0.72, alpha: 1).cgColor]
        gradient.opacity = enabled ? 1 : 0.4
        thumb.isHidden = next == nil
        thumb.opacity = enabled ? 1 : 0.45
        CATransaction.commit()
        if changed { placeThumb(at: fraction(for: next), animated: automatic && hadValue && !reduceMotion) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != previousBounds else { return }
        previousBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        number.frame = CGRect(x: 0, y: 0, width: 36, height: bounds.height)
        gradient.frame = trackRect
        let path = UIBezierPath()
        for fraction in [CGFloat(0.25), 0.5, 0.75] {
            let x = trackRect.width * fraction
            path.move(to: CGPoint(x: x, y: 1))
            path.addLine(to: CGPoint(x: x, y: 3.5))
        }
        ticks.path = path.cgPath
        CATransaction.commit()
        placeThumb(at: fraction(for: value), animated: false)
    }

    private func fraction(for value: Float?) -> CGFloat {
        guard let value else { return 0.5 }
        return CGFloat(min(1, max(0, (value - kind.range.lowerBound) / (kind.range.upperBound - kind.range.lowerBound))))
    }

    private func placeThumb(at fraction: CGFloat, animated: Bool) {
        let from = thumb.presentation()?.position.x ?? thumb.position.x
        let to = trackRect.minX + fraction * trackRect.width
        thumb.removeAnimation(forKey: "automatic.position")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.position = CGPoint(x: to, y: bounds.midY)
        CATransaction.commit()
        guard animated, bounds.width > 0, abs(from - to) > 0.01 else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = WhiteBalanceReadingGate.samplingInterval
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        thumb.add(animation, forKey: "automatic.position")
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, value != nil else { return false }
        let visibleX = thumb.presentation()?.position.x ?? thumb.position.x
        let visibleFraction = min(1, max(0, (visibleX - trackRect.minX) / trackRect.width))
        drag = CameraColorSliderDrag(startX: touch.location(in: self).x, startFraction: visibleFraction)
        lastEmittedValue = nil
        placeThumb(at: visibleFraction, animated: false)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let drag else { return false }
        select(fraction: drag.fraction(at: touch.location(in: self).x, travel: trackRect.width))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let drag else { return }
        if let touch {
            let x = touch.location(in: self).x
            let fraction = drag.endingFraction(at: x, trackStart: trackRect.minX,
                travel: trackRect.width, hasEmittedValue: lastEmittedValue != nil)
            select(fraction: fraction)
        }
        self.drag = nil
        onEditingEnded?()
    }

    override func cancelTracking(with event: UIEvent?) {
        let wasDragging = drag != nil
        drag = nil
        super.cancelTracking(with: event)
        if wasDragging { onEditingEnded?() }
    }

    override func accessibilityIncrement() { adjust(by: kind.step) }
    override func accessibilityDecrement() { adjust(by: -kind.step) }

    private func adjust(by step: Float) {
        guard isEnabled, let value else { return }
        lastEmittedValue = nil
        select(fraction: fraction(for: value + step))
        onEditingEnded?()
    }

    private func select(fraction: CGFloat) {
        let raw = kind.range.lowerBound + Float(fraction) * (kind.range.upperBound - kind.range.lowerBound)
        guard let normalized = kind.normalized(raw) else { return }
        value = normalized
        automatic = false
        placeThumb(at: fraction, animated: false)
        updateReadout()
        if normalized != lastEmittedValue {
            lastEmittedValue = normalized
            onChange?(normalized)
        }
    }

    private func updateReadout() {
        let text = kind.text(for: value)
        number.text = text
        accessibilityValue = value == nil ? String(localized: "Automatic value unavailable")
            : automatic ? "\(text), \(String(localized: "Auto"))" : text
    }
}

// MARK: - 拍摄页右下角胶片封面缩略图
/// 拍摄页右下角的胶片封面缩略图（与左下最近照片缩略图对称）。
/// FilmSource.preset → 加载胶片图鉴的 libraryCardImage；FilmSource.custom → 配色 + 滤镜图标
/// （和列表 CustomLUTTile 一致）。列表 tile 通过 navigationTransition(.zoom) 放大成本页时,
/// 视觉上封面落位在这里。当前仅展示，后续会挂点击交互。
struct FilmSourceCoverThumbnail: View {
    let source: FilmSource
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private static let customAccent = Color(red: 0.6, green: 0.5, blue: 0.8)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        ZStack {
            switch source {
            case .preset:
                Color.white.opacity(0.05)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            case .custom:
                Self.customAccent.opacity(0.18)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Self.customAccent)
            }
        }
        .clipShape(shape)
        // 不用 glassEffect：与左下角照片角标渲染一致——纯封面图裁成圆角方块，整块随设备方向旋转。
        // glass 的高光描边会让旋转中途的方块对角线特别显眼（看起来像突然放大），左角标没有这层描边，
        // 所以整块旋转也不刺眼。去掉 glass 后两边外观与旋转手感完全统一。
        .task(id: source.id) {
            // 46pt × scale ≈ 138 px；预留余量取 200，与列表缓存的 cacheKey 解耦避免反复解码。
            guard case .preset(let preset) = source else {
                image = nil
                return
            }
            let pixel = max(Int(46.0 * displayScale * 1.5), 100)
            image = await FilmCardImageCache.shared.loadImage(
                imageName: preset.libraryCardImage,
                cacheKey: "thumb_\(preset.rawValue)",
                maxPixel: pixel
            )
        }
        .accessibilityLabel(Text("Current film: \(source.displayName)"))
    }
}
