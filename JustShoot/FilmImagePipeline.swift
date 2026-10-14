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

    static func stages(
        for image: CIImage,
        lut: CubeLUT?,
        chromaticGain: SIMD3<Float>,
        optics: FilmOpticsParameters,
        grain: FilmGrainParameters,
        grainSeed: UInt32,
        cancellation: CaptureRenderCancellation? = nil
    ) -> Stages? {
        guard cancellation?.isCancelled != true else { return nil }
        let responded = FilmChromaticRenderer.applying(to: image, gain: chromaticGain)
        let graded: CIImage
        if let lut {
            // Filter instances are local to this graph, never shared between render jobs.
            guard let cube = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
            cube.setValue(responded, forKey: kCIInputImageKey)
            cube.setValue(lut.dimension, forKey: "inputCubeDimension")
            cube.setValue(lut.data, forKey: "inputCubeData")
            cube.setValue(colorSpace, forKey: "inputColorSpace")
            guard let output = cube.outputImage else { return nil }
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
