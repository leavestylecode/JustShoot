import CoreImage
import CoreImage.CIFilterBuiltins

/// The look always receives SDR. Disable auxiliary gain-map expansion on both
/// paths; newer systems keep the existing explicit headroom mapping.
enum PhotoInputDecoder {
    static func decode(_ data: Data, applyOrientation: Bool = false) -> CIImage? {
        if #available(iOS 18.0, *) {
            guard let image = CIImage(data: data, options: [.expandToHDR: false,
                .toneMapHDRtoSDR: false, .applyOrientationProperty: applyOrientation]) else { return nil }
            guard image.contentHeadroom > 1 else { return image }
            let toneMap = CIFilter.toneMapHeadroom()
            toneMap.inputImage = image
            toneMap.sourceHeadroom = image.contentHeadroom
            toneMap.targetHeadroom = 1
            return toneMap.outputImage
        }
        return decodeSDROnly(data, applyOrientation: applyOrientation)
    }

    /// iOS 17 processes the SDR base of gain-map photos. Standalone PQ/HLG
    /// inputs require the newer headroom mapper: reject them without rendering
    /// rather than silently clipping highlights or producing a black image.
    static func decodeSDROnly(_ data: Data, applyOrientation: Bool = false) -> CIImage? {
        guard let image = CIImage(data: data, options: [.expandToHDR: false, .toneMapHDRtoSDR: false,
            .applyOrientationProperty: applyOrientation]) else { return nil }
        if let colorSpace = image.colorSpace, CGColorSpaceUsesITUR_2100TF(colorSpace) { return nil }
        return image
    }
}
