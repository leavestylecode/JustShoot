import SwiftUI

/// iPad Camera keeps the shutter at the right-hand grip and zoom at the left.
/// Tools and look pickers overlay the viewfinder without changing its geometry.
struct IPadCameraLayoutGeometry {
    let preview: CGRect
    let shutter: CGPoint
    let recentPhoto: CGPoint
    let zoom: CGPoint
    let back: CGPoint
    let tools: CGRect
    let toolsAxis: Axis
    let permissions: CGRect
    let picker: CGRect
    private let size: CGSize

    fileprivate static let pickerRowSpacing: CGFloat = 10
    fileprivate static let pickerVerticalPadding: CGFloat = 12

    static func pickerHeight(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        2 * (CameraPickerStyle.iPadOverlay.rowHeight(for: sizeClass) + pickerVerticalPadding) + pickerRowSpacing
    }

    init(size: CGSize, aspect: CGFloat, pickerHeight: CGFloat = IPadCameraLayoutGeometry.pickerHeight(for: .regular),
        toolCount: Int = 4, zoomCount: Int = 4, permissionCount: Int = 0) {
        self.size = size
        let bounds = CGRect(origin: .zero, size: size)
        preview = CameraFraming.centeredCrop(in: bounds, aspect: aspect)
        let bottomPickerHeight = min(pickerHeight, max(0, size.height - 32))
        let zoomHeight = CGFloat(max(1, zoomCount)) * 46 + 6
        let needsSideClearance = size.height < 84 + zoomHeight + 12 + bottomPickerHeight + 16
        let pickerWidth = min(840, max(0, size.width - (needsSideClearance ? 208 : 32)))
        picker = CGRect(x: (size.width - pickerWidth) / 2, y: size.height - 16 - bottomPickerHeight,
            width: pickerWidth, height: bottomPickerHeight)
        // Anchor capture controls to the 4:3 image, so they never straddle its
        // edge when the display is wider than the photograph.
        let controlX = max(44, preview.maxX - 60)
        // Reserve room even while the picker is closed, so compact windows do
        // not move the shutter or cover recent photos when the rows appear.
        let shutterY = min(size.height / 2, max(72, picker.minY - 16 - 28 - 90))
        shutter = CGPoint(x: controlX, y: shutterY)
        recentPhoto = CGPoint(x: controlX, y: min(size.height - 36, shutter.y + 90))
        let zoomBottom = needsSideClearance ? size.height - 16 : picker.minY - 12
        zoom = CGPoint(x: preview.minX + 52, y: min(zoomBottom - zoomHeight / 2,
            max(shutter.y, 84 + zoomHeight / 2)))
        // The independent 52 pt Back button shares the focal capsule's axis,
        // with a 16 pt gap above it. The zoom rail reserves this space at the top.
        back = CGPoint(x: zoom.x, y: zoom.y - zoomHeight / 2 - 16 - 26)
        let toolsBottom = shutter.y - 56
        let columnHeight = CGFloat(toolCount) * 56 + CGFloat(max(0, toolCount - 1)) * 16
        if toolsBottom - columnHeight >= 16 {
            toolsAxis = .vertical
            tools = CGRect(x: controlX - 28, y: toolsBottom - columnHeight, width: 56, height: columnHeight)
        } else {
            // Short windows keep every camera action visible in a top row.
            toolsAxis = .horizontal
            let width = CGFloat(toolCount) * 44 + CGFloat(max(0, toolCount - 1)) * 8
            tools = CGRect(x: max(16, controlX + 22 - width), y: 16, width: width, height: 44)
        }
        let permissionWidth = CGFloat(permissionCount * 44 + max(0, permissionCount - 1) * 4)
        let permissionLeading: CGFloat = 86
        let needsSecondRow = toolsAxis == .horizontal && permissionLeading + permissionWidth + 8 > tools.minX
        permissions = permissionCount == 0 ? .zero : CGRect(x: permissionLeading,
            y: needsSecondRow ? tools.maxY + 8 : 16, width: permissionWidth, height: 44)
    }

    func adjustmentFrame(showsPicker: Bool) -> CGRect {
        let width = min(380, max(146, size.width - 208))
        let bottom = min(preview.maxY - 6, showsPicker ? picker.minY - 6 : size.height - 6)
        // Tint belongs at the top of the viewfinder. Temperature stays at the
        // lower edge and rises above the look picker when it opens.
        // WhiteBalanceControl adds 10 pt internally: both visible rows sit
        // 16 pt inside the image. Short windows reserve the top tools row.
        let minimumTop: CGFloat = toolsAxis == .horizontal ? max(64, permissions.maxY + 4) : 6
        let top = max(minimumTop, min(preview.minY + 6, bottom - 164))
        return CGRect(x: (size.width - width) / 2, y: top, width: width, height: max(164, bottom - top))
    }

    func exposurePosition(showsColorControls: Bool, showsPicker: Bool) -> CGPoint {
        let frame = adjustmentFrame(showsPicker: showsPicker)
        // Keep the EV badge just below Tint, away from the center of the scene.
        return CGPoint(x: frame.midX, y: frame.minY + (showsColorControls ? 84 : 22))
    }
}

struct IPadCameraBackButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            NavigationBackLabel()
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CameraPalette.foreground(for: colorScheme))
        .accessibilityIdentifier("camera.back")
        .accessibilityLabel("Back")
    }
}

struct IPadCameraLayout<Preview: View, Tools: View, Shutter: View, RecentPhoto: View, Zoom: View, Picker: View, Overlays: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let aspect: CGFloat
    let showsPicker: Bool
    var toolCount = 4
    var zoomCount = 4
    var permissionCount = 0
    @ViewBuilder var preview: Preview
    @ViewBuilder var tools: (Axis) -> Tools
    @ViewBuilder var shutter: Shutter
    @ViewBuilder var recentPhoto: RecentPhoto
    @ViewBuilder var zoom: Zoom
    @ViewBuilder var picker: Picker
    @ViewBuilder var overlays: (IPadCameraLayoutGeometry) -> Overlays

    var body: some View {
        GeometryReader { geometry in
            let layout = IPadCameraLayoutGeometry(size: geometry.size, aspect: aspect,
                pickerHeight: IPadCameraLayoutGeometry.pickerHeight(for: sizeClass),
                toolCount: toolCount, zoomCount: zoomCount, permissionCount: permissionCount)
            ZStack {
                preview
                    .frame(width: layout.preview.width, height: layout.preview.height)
                    .position(x: layout.preview.midX, y: layout.preview.midY)

                tools(layout.toolsAxis)
                    .frame(width: layout.tools.width, height: layout.tools.height)
                    .position(x: layout.tools.midX, y: layout.tools.midY)

                shutter.position(layout.shutter)
                recentPhoto.position(layout.recentPhoto)
                zoom.position(layout.zoom)
                overlays(layout)

                if showsPicker {
                    picker
                        .frame(width: layout.picker.width, height: layout.picker.height)
                        .position(x: layout.picker.midX, y: layout.picker.midY)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct IPadCameraTools<Content: View>: View {
    let axis: Axis
    @ViewBuilder var content: Content

    var body: some View {
        let layout = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 8))
        layout { content }
    }
}

struct IPadCameraLookPanel<Curves: View, Films: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var curves: Curves
    @ViewBuilder var films: Films

    var body: some View {
        VStack(spacing: IPadCameraLayoutGeometry.pickerRowSpacing) {
            curves
            films
        }
        .padding(.vertical, IPadCameraLayoutGeometry.pickerVerticalPadding)
        .background(colorScheme == .light ? .white.opacity(0.76) : .black.opacity(0.24), in: .rect(cornerRadius: 24))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
    }
}

extension View {
    func iPadCameraTool(compact: Bool = false) -> some View {
        font(.system(size: compact ? 18 : 20, weight: .medium))
            .buttonStyle(.plain)
            .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
            .cameraControlSurface()
            .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)
    }
}
