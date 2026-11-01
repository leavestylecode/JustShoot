import VideoToolbox

enum LivePhotoEncoderConfiguration {
    static var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Both the hardware encoder requirement and the sRGB writer tag must be
    /// supported. iOS 17 omits Live capture; saved Live Photos remain readable.
    static var specification: CFDictionary? {
        if #available(iOS 18.0, *) {
            return [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        }
        return nil
    }
}
