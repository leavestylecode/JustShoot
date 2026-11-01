import CoreImage
import CoreImage.CIFilterBuiltins

/// Stills and Live Photo frames build the same lazy Core Image graph.
/// The preview uses the same LUT bytes, parameters and shared Metal math.
enum FilmImagePipeline {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Display LUTs consume SDR. An HDR-tagged input needs tone mapping before
    /// cube sampling; an auxiliary gain map must not silently expand it again.
    static func decodePhoto(_ data: Data, applyOrientation: Bool = false) -> CIImage? {
        PhotoInputDecoder.decode(data, applyOrientation: applyOrientation)
    }

    struct Stages {
        let graded: CIImage
        let optical: CIImage
        let final: CIImage
    }

    /// Mutable and intentionally not Sendable. One transcode owns one instance, used only
    /// on its serial video queue. The cube and color space stay fixed across every frame.
    final class LUTFilter {
        private let filter: CIFilter?
        private let largeCube: FilmMaterialRenderer.PreparedCube?
        let preparedMaterial: FilmMaterialRenderer.Prepared?

        init?(lut: CubeLUT) {
            preparedMaterial = lut.material.map(FilmMaterialRenderer.Prepared.init)
            if lut.dimension > 64 {
                filter = nil
                largeCube = FilmMaterialRenderer.PreparedCube(lut)
                return
            }
            largeCube = nil
            guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
            filter.setValue(lut.dimension, forKey: "inputCubeDimension")
            filter.setValue(lut.data, forKey: "inputCubeData")
            filter.setValue(colorSpace, forKey: "inputColorSpace")
            filter.setValue(false, forKey: "inputExtrapolate")
            self.filter = filter
        }

        func applying(to image: CIImage) -> CIImage? {
            if let largeCube {
                return FilmMaterialRenderer.applyingCube(to: image, prepared: largeCube)
            }
            guard let filter else { return nil }
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
        if let material = lut?.material.map(FilmMaterialRenderer.Prepared.init) ?? lutFilter?.preparedMaterial {
            return FilmMaterialRenderer.stages(image: responded, prepared: material,
                optics: optics, grain: grain, seed: grainSeed, cancellation: cancellation)
        }
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
