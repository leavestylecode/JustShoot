import AVFoundation

struct CameraRAWFormat: Equatable, Sendable {
    enum Kind: String, Sendable { case appleProRAW, bayerRAW }
    let pixelFormat: OSType
    let kind: Kind
}

enum CameraRAWCapturePolicy {
    /// Bayer RAW requires native 1x with no output scaling; reject cropped captures
    /// rather than triggering AVFoundation's NSInvalidArgumentException.
    static func select(formats: [CameraRAWFormat], zoom: CGFloat, outputScale: CGFloat = 1) -> CameraRAWFormat? {
        if let pro = formats.first(where: { $0.kind == .appleProRAW }) { return pro }
        guard abs(zoom - 1) < 0.0001, abs(outputScale - 1) < 0.0001 else { return nil }
        return formats.first(where: { $0.kind == .bayerRAW })
    }

    static func format(output: AVCapturePhotoOutput, zoom: CGFloat) -> CameraRAWFormat? {
        let formats = output.availableRawPhotoPixelFormatTypes.compactMap { type -> CameraRAWFormat? in
            if output.isAppleProRAWEnabled, AVCapturePhotoOutput.isAppleProRAWPixelFormat(type) {
                return CameraRAWFormat(pixelFormat: type, kind: .appleProRAW)
            }
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(type) {
                return CameraRAWFormat(pixelFormat: type, kind: .bayerRAW)
            }
            return nil
        }
        return select(formats: formats, zoom: zoom,
                      outputScale: output.connection(with: .video)?.videoScaleAndCropFactor ?? 1)
    }

    static func acceptsDelivery(expectsRAW: Bool, isRAW: Bool) -> Bool { expectsRAW == isRAW }
}
