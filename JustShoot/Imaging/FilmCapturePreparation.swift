import Foundation

/// Serial preparation outside UI updates. New captures use the same prepared
/// WB → look → curve cube as the viewfinder and Live Photo frames.
actor FilmCapturePreparation {
    static let shared = FilmCapturePreparation()

    func prepareRendering(for lut: CubeLUT) throws -> CubeLUT {
        try Task.checkCancellation()
        try FilmMaterialRenderer.prepare()
        var prepared = lut
        try prepared.prepareMaterialCheckpoint()
        try Task.checkCancellation()
        return prepared
    }

    func displayLUT(source: FilmSource, curve: FilmCurve) throws -> CubeLUT {
        try Task.checkCancellation()
        let lut = try FilmProcessor.shared.loadLUT(source: source, curve: curve)
        return try prepareRendering(for: lut)
    }
}
