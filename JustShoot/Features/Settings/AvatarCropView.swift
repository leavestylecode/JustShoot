import SwiftUI
import UIKit

struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (Data) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pinchScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var pendingCrop: AvatarCropSelection?
    @State private var showError = false

    private var liveZoom: CGFloat {
        min(max(zoom * pinchScale, 1), 4)
    }

    private func clampedOffset(_ proposed: CGSize, side: CGFloat, imageSize: CGSize, zoom: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let baseScale = max(side / imageSize.width, side / imageSize.height)
        let maxX = max(0, (imageSize.width * baseScale * zoom - side) / 2)
        let maxY = max(0, (imageSize.height * baseScale * zoom - side) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func displayedOffset(side: CGFloat, imageSize: CGSize) -> CGSize {
        clampedOffset(
            CGSize(
                width: offset.width + dragTranslation.width,
                height: offset.height + dragTranslation.height
            ),
            side: side,
            imageSize: imageSize,
            zoom: liveZoom
        )
    }

    @ViewBuilder
    private func cropCanvas(side: CGFloat, image: UIImage) -> some View {
        let baseScale = max(side / image.size.width, side / image.size.height)
        let displayedWidth = image.size.width * baseScale * liveZoom
        let displayedHeight = image.size.height * baseScale * liveZoom
        let currentOffset = displayedOffset(side: side, imageSize: image.size)

        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: displayedWidth, height: displayedHeight)
            .offset(currentOffset)
            .frame(width: side, height: side)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
            .contentShape(Circle())
            .gesture(
                DragGesture()
                    .onChanged { dragTranslation = $0.translation }
                    .onEnded { value in
                        offset = clampedOffset(
                            CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            ),
                            side: side,
                            imageSize: image.size,
                            zoom: liveZoom
                        )
                        dragTranslation = .zero
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { pinchScale = $0 }
                    .onEnded { value in
                        zoom = min(max(zoom * value, 1), 4)
                        pinchScale = 1
                        offset = clampedOffset(offset, side: side, imageSize: image.size, zoom: zoom)
                    }
            )
            .accessibilityLabel(Text("profile_crop_area"))
            .accessibilityHint(Text("profile_crop_hint"))
    }

    private func zoomControls(side: CGFloat, imageSize: CGSize) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...4)
                .accessibilityLabel(Text("profile_zoom"))
                .onChange(of: zoom) { _, value in
                    offset = clampedOffset(offset, side: side, imageSize: imageSize, zoom: value)
                }
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420)
    }

    private func confirm(side: CGFloat, imageSize: CGSize) {
        guard pendingCrop == nil, imageSize.width > 0, imageSize.height > 0 else { return }
        let currentOffset = displayedOffset(side: side, imageSize: imageSize)
        pendingCrop = AvatarCropSelection(
            viewportSide: Double(side),
            zoom: Double(liveZoom),
            offsetX: Double(currentOffset.width),
            offsetY: Double(currentOffset.height)
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = max(120, min(min(geometry.size.width - 48, geometry.size.height - 150), 420))

                VStack(spacing: 24) {
                    Spacer(minLength: 0)

                    cropCanvas(side: side, image: image)
                    zoomControls(side: side, imageSize: image.size)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .onChange(of: side) { _, newSide in
                    offset = clampedOffset(offset, side: newSide, imageSize: image.size, zoom: zoom)
                }
                .navigationTitle("profile_adjust_photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .toolbarControlSurface()
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            confirm(side: side, imageSize: image.size)
                        } label: {
                            Image(systemName: "checkmark")
                                .toolbarControlSurface()
                        }
                        .accessibilityLabel(Text("Done"))
                        .disabled(pendingCrop != nil)
                    }
                }
                .alert("profile_adjust_photo", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("profile_photo_unavailable")
                }
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .legacySoftToolbarEdges()
        }
        .task(id: pendingCrop) {
            guard let selection = pendingCrop else { return }
            guard let original = image.cgImage else {
                pendingCrop = nil
                showError = true
                return
            }
            let result = await BlockingImageWork.shared.run {
                ProfileAvatarImageProcessor.croppedJPEG(from: original, selection: selection)
            }
            guard !Task.isCancelled else { return }
            pendingCrop = nil
            if let result { onConfirm(result) }
            else { showError = true }
        }
    }
}

nonisolated struct AvatarCropSelection: Equatable, Sendable {
    let viewportSide: Double
    let zoom: Double
    let offsetX: Double
    let offsetY: Double

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0,
              viewportSide.isFinite, viewportSide > 0,
              zoom.isFinite, zoom >= 1,
              offsetX.isFinite, offsetY.isFinite else { return nil }

        let baseScale = max(viewportSide / Double(imageWidth), viewportSide / Double(imageHeight))
        let pixelScale = baseScale * zoom
        let drawnWidth = Double(imageWidth) * pixelScale
        let drawnHeight = Double(imageHeight) * pixelScale
        let maxOffsetX = max(0, (drawnWidth - viewportSide) / 2)
        let maxOffsetY = max(0, (drawnHeight - viewportSide) / 2)
        let clampedX = min(max(offsetX, -maxOffsetX), maxOffsetX)
        let clampedY = min(max(offsetY, -maxOffsetY), maxOffsetY)
        let side = min(Int(ceil(viewportSide / pixelScale)), min(imageWidth, imageHeight))
        let originX = (Double(imageWidth - side) / 2) - clampedX / pixelScale
        let originY = (Double(imageHeight - side) / 2) - clampedY / pixelScale
        let x = min(max(Int(originX.rounded()), 0), imageWidth - side)
        let y = min(max(Int(originY.rounded()), 0), imageHeight - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

private nonisolated enum ProfileAvatarImageProcessor {
    static func croppedJPEG(from image: CGImage, selection: AvatarCropSelection) -> Data? {
        guard let rect = selection.pixelRect(imageWidth: image.width, imageHeight: image.height),
              let cropped = image.cropping(to: rect) else {
            return nil
        }

        let outputSize = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: outputSize))
        }.jpegData(compressionQuality: 0.8)
    }
}
