import CoreImage

/// Stills and Live Photo frames build the same lazy Core Image graph.
/// The preview uses the same LUT bytes, parameters and shared Metal math.
enum FilmImagePipeline {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    struct Stages {
        let graded: CIImage
        let optical: CIImage
        let final: CIImage
    }

    /// Mutable and intentionally not Sendable. One transcode owns one instance, used only
    /// on its serial video queue. The cube and color space stay fixed across every frame.
    final class LUTFilter {
        private let filter: CIFilter

        init?(lut: CubeLUT) {
            guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
            filter.setValue(lut.dimension, forKey: "inputCubeDimension")
            filter.setValue(lut.data, forKey: "inputCubeData")
            filter.setValue(colorSpace, forKey: "inputColorSpace")
            filter.setValue(false, forKey: "inputExtrapolate")
            self.filter = filter
        }

        func applying(to image: CIImage) -> CIImage? {
            filter.setValue(image, forKey: kCIInputImageKey)
            // outputImage is an immutable graph. Release the mutable filter's input after
            // taking that snapshot so it doesn't retain the previous camera buffer.
            defer { filter.setValue(nil, forKey: kCIInputImageKey) }
            return filter.outputImage
        }
    }

    static func stages(
        for image: CIImage,
        lut: CubeLUT?,
        lutFilter: LUTFilter? = nil,
        chromaticGain: SIMD3<Float>,
        protectChromaticHighlights: Bool = false,
        optics: FilmOpticsParameters,
        grain: FilmGrainParameters,
        grainSeed: UInt32,
        cancellation: CaptureRenderCancellation? = nil
    ) -> Stages? {
        guard cancellation?.isCancelled != true else { return nil }
        let responded = FilmChromaticRenderer.applying(to: image, gain: chromaticGain,
                                                      protectHighlights: protectChromaticHighlights)
        let graded: CIImage
        if let lutFilter {
            guard let output = lutFilter.applying(to: responded) else { return nil }
            graded = output
        } else if let lut {
            guard let output = LUTFilter(lut: lut)?.applying(to: responded) else { return nil }
            graded = output
        } else {
            graded = responded
        }
        guard cancellation?.isCancelled != true else { return nil }
        let optical = FilmOpticsRenderer.applying(to: graded, parameters: optics)
        guard cancellation?.isCancelled != true else { return nil }
        let final = FilmGrainRenderer.applying(to: optical, parameters: grain, seed: grainSeed)
        return Stages(graded: graded, optical: optical, final: final)
    }
}
