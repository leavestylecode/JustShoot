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
