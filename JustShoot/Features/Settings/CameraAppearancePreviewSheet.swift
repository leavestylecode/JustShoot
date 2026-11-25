import SwiftUI

struct CameraAppearancePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scheme: ColorScheme
    let canvasSize: CGSize

    init(scheme: ColorScheme, canvasSize: CGSize) {
        _scheme = State(initialValue: scheme)
        self.canvasSize = canvasSize
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CameraAppearanceSample(canvas: canvasSize)
                    .environment(\.colorScheme, scheme)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel("Camera Preview")
                    .accessibilityValue(scheme == .light ? Text("Light") : Text("Dark"))

                AppSegmentedPicker(title: "Camera Appearance", selection: $scheme, options: [.light, .dark]) {
                    $0 == .light ? Text("Light") : Text("Dark")
                }
                .frame(maxWidth: 320)
            }
            .padding(16)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Camera Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").toolbarControlSurface()
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

/// A scaled illustration of the capture controls, backed by a bundled photo.
private struct CameraAppearanceSample: View {
    @Environment(\.colorScheme) private var scheme
    let canvas: CGSize
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad
    private let focalInfo = DeviceFocalInfo.placeholder

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(canvas.width, 1), geometry.size.height / max(canvas.height, 1))
            let outline = RoundedRectangle(cornerRadius: 22, style: .continuous)

            Group {
                if isPad {
                    tablet(aspect: canvas.width > canvas.height ? 4.0 / 3 : 3.0 / 4)
                } else {
                    phone
                }
            }
            .dynamicTypeSize(.large)
            .frame(width: canvas.width, height: canvas.height)
            .foregroundStyle(CameraPalette.foreground(for: scheme))
            .background(scheme == .light ? Color.white : .black)
            .clipShape(outline)
            .overlay { outline.strokeBorder(.primary.opacity(0.16), lineWidth: 1) }
            .scaleEffect(scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }

    private var phone: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                NavigationBackLabel()
                Spacer()
                if LivePhotoEncoderConfiguration.isSupported {
                    Image(systemName: "livephoto.slash").iPadCameraTool(compact: true)
                }
                Image(systemName: "bolt.slash.fill").iPadCameraTool(compact: true)
                Image(systemName: "drop.halffull").iPadCameraTool(compact: true)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 12)
            VStack(spacing: 12) {
                viewfinder.aspectRatio(3.0 / 4, contentMode: .fit)
                zoom(.horizontal)
            }
            Spacer(minLength: 12)
            HStack {
                thumbnail
                Spacer()
                shutter
                Spacer()
                filmCover(size: 46)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
    }

    private func tablet(aspect: CGFloat) -> some View {
        IPadCameraLayout(aspect: aspect, showsPicker: false,
            toolCount: LivePhotoEncoderConfiguration.isSupported ? 4 : 3, zoomCount: focalInfo.options.count) {
            viewfinder
        } tools: { axis in
            let compact = axis == .horizontal
            IPadCameraTools(axis: axis) {
                Image(systemName: "bolt.slash.fill").iPadCameraTool(compact: compact)
                if LivePhotoEncoderConfiguration.isSupported {
                    Image(systemName: "livephoto.slash").iPadCameraTool(compact: compact)
                }
                Image(systemName: "drop.halffull").iPadCameraTool(compact: compact)
                filmCover(size: compact ? 44 : 56)
            }
        } shutter: {
            shutter
        } recentPhoto: {
            thumbnail
        } zoom: {
            zoom(.vertical)
        } picker: {
            EmptyView()
        } overlays: { layout in
            NavigationBackLabel().position(layout.back)
        }
    }

    private var viewfinder: some View {
        VaultImage(filename: FilmSampleScene.fuji.filename, maxPixel: 1200)
    }

    private var thumbnail: some View {
        let size: CGFloat = isPad ? 56 : 46
        return VaultImage(filename: FilmSampleScene.torii.filename, maxPixel: 160)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 8))
    }

    private var shutter: some View {
        CameraShutterButton(isCapturing: false, isPreparingFilm: false, canCapture: true, isPressed: false) {}
    }

    private func filmCover(size: CGFloat) -> some View {
        FilmSourceCoverThumbnail(source: .preset(.fujiRawVelvia)).frame(width: size, height: size)
    }

    private func zoom(_ axis: Axis) -> some View {
        FocalLengthStrip(focalInfo: focalInfo, current: focalInfo.defaultOption, contentRotation: .zero, axis: axis) { _ in }
    }
}
