import Foundation

/// The offline samples are sRGB responses to a neutral 256-step ramp through the film pipeline.
actor FilmToneCurveCatalog {
    static let shared = FilmToneCurveCatalog()
    private var ramps: [String: Data]?

    func preview(for preset: FilmPreset) throws -> CurvePreviewData {
        if ramps == nil {
            guard let url = Bundle.main.url(forResource: "FilmToneRamps", withExtension: "plist") else {
                throw CocoaError(.fileNoSuchFile)
            }
            ramps = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: url))
        }
        guard let bytes = ramps?[preset.id], bytes.count == CurveMath.sampleCount * 4 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func channel(_ offset: Int) -> [Float] {
            stride(from: offset, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 }
        }
        return CurvePreviewData(red: channel(0), green: channel(1), blue: channel(2))
    }
}
