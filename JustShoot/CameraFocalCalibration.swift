import Foundation
@preconcurrency import AVFoundation

/// Resolved once on the hardware queue, never in a view update or per frame.
/// iOS 17–18 expose format FOV, but not Apple's nominal 35mm focal length.
struct CameraFocalCalibration: Equatable, Sendable {
    enum Source: String, Sendable { case systemNominal, fieldOfView }
    let millimeters: Float
    let source: Source

    static func resolve(device: AVCaptureDevice) -> Self? {
        if #available(iOS 26.0, *), let nominal = nominal(device.nominalFocalLengthIn35mmFilm) {
            return nominal
        }
        // Prefer the widest 4:3 photo format, avoiding a cropped video format's
        // misleading diagonal. This is an estimate, labelled as such in the UI.
        let formats = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.height > 0 && abs(Float(size.width) / Float(size.height) - 4 / 3.0) < 0.02
        }
        let estimates = formats.compactMap { format -> Self? in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return estimate(horizontalFieldOfView: format.videoFieldOfView, width: size.width, height: size.height)
        }
        if let widest = estimates.min(by: { $0.millimeters < $1.millimeters }) { return widest }
        let format = device.activeFormat
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return estimate(horizontalFieldOfView: format.videoFieldOfView, width: size.width, height: size.height)
    }

    static func nominal(_ value: Float) -> Self? {
        guard value.isFinite, value > 0 else { return nil }
        return Self(millimeters: value, source: .systemNominal)
    }

    static func estimate(horizontalFieldOfView degrees: Float, width: Int32, height: Int32) -> Self? {
        guard degrees.isFinite, degrees > 0, degrees < 179, width > 0, height > 0 else { return nil }
        let aspect = Double(height) / Double(width)
        let diagonal = 2 * tan(Double(degrees) * .pi / 360) * sqrt(1 + aspect * aspect)
        let mm = Float(sqrt(36.0 * 36 + 24.0 * 24) / diagonal)
        guard mm.isFinite, mm >= 5, mm <= 1_000 else { return nil }
        return Self(millimeters: mm, source: .fieldOfView)
    }
}
