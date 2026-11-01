import Foundation

/// Serial preparation outside UI updates. New captures use the same prepared
/// WB → look → curve cube as the viewfinder and Live Photo frames.
actor FilmCapturePreparation {
    static let shared = FilmCapturePreparation()

    func prepareRendering() throws {
        try Task.checkCancellation()
        try FilmMaterialRenderer.prepare()
        try Task.checkCancellation()
    }

    func displayLUT(source: FilmSource, curve: FilmCurve) throws -> CubeLUT {
        try Task.checkCancellation()
        let lut = try FilmProcessor.shared.loadLUT(source: source, curve: curve)
        try prepareRendering()
        try Task.checkCancellation()
        return lut
    }
}
