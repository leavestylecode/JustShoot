import Foundation

/// Bounded display-space refinement of bundled looks. Baked off the UI thread
/// into the shared cube; no face detector, per-frame pass, or custom-LUT rewrite.
enum FilmLookRefinement {
    static let revision = "skin-shadow-v2"
    static let cacheSuffix = "#" + revision

    private struct Profile: Decodable, Sendable {
        let shadowRetention: Float
        let skinHue: Float
        let skinChroma: Float
        let skinLightness: Float

        let toeSeparation: Float?

        var hasPortraitAdjustment: Bool {
            shadowRetention > 0 || skinHue > 0 || skinChroma > 0 || skinLightness > 0
        }

        var isValid: Bool {
            [shadowRetention, skinHue, skinChroma, skinLightness, toeSeparation ?? 0].allSatisfy {
                $0.isFinite && (0...0.6).contains($0)
            }
        }
    }

    private struct Configuration: Decodable, Sendable {
        let revision: String
        let profiles: [String: Profile]
    }

    private static let configuration: Result<Configuration, any Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmLookRefinements", withExtension: "json") else {
            throw CubeLUT.ParseError.malformed
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard config.revision == revision,
              Set(config.profiles.keys) == Set(FilmPreset.allCases.map(\.rawValue)),
              config.profiles.values.allSatisfy(\.isValid) else { throw CubeLUT.ParseError.malformed }
        return config
    }

    static func parameters(for preset: FilmPreset) throws -> SIMD4<Float> {
        guard let profile = try configuration.get().profiles[preset.rawValue] else { throw CubeLUT.ParseError.malformed }
        return SIMD4(profile.shadowRetention, profile.skinHue, profile.skinChroma, profile.skinLightness)
    }

    static func applying(to original: CubeLUT, preset: FilmPreset) throws -> CubeLUT {
        let config = try configuration.get()
        guard let profile = config.profiles[preset.rawValue] else { throw CubeLUT.ParseError.malformed }
        guard profile.hasPortraitAdjustment || (profile.toeSeparation ?? 0) > 0 else { return original }
        let dimension = original.dimension
        let divisor = Float(dimension - 1)
        var data = original.data
        try data.withUnsafeMutableBytes { storage in
            let values = storage.bindMemory(to: Float.self)
            for blue in 0..<dimension {
                try Task.checkCancellation()
                for green in 0..<dimension { for red in 0..<dimension {
                    let offset = ((blue * dimension + green) * dimension + red) * 4
                    let input = SIMD3(Float(red), Float(green), Float(blue)) / divisor
                    let output = refine(input: input,
                        graded: SIMD3(values[offset], values[offset + 1], values[offset + 2]), profile: profile)
                    values[offset] = output.x
                    values[offset + 1] = output.y
                    values[offset + 2] = output.z
                } }
            }
        }
        return CubeLUT(data: data, dimension: dimension)
    }

    private static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let x = min(1, max(0, (value - low) / (high - low)))
        return x * x * (3 - 2 * x)
    }

    private static func luma(_ rgb: SIMD3<Float>) -> Float {
        rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
    }

    private static func length(_ value: SIMD2<Float>) -> Float {
        sqrt(value.x * value.x + value.y * value.y)
    }

    private static func refine(input: SIMD3<Float>, graded: SIMD3<Float>, profile: Profile) -> SIMD3<Float> {
        let y = luma(input)
        let separation = (profile.toeSeparation ?? 0) * y * (1 - smooth(0.05, 0.28, y))
        // Equal channel increments preserve chroma and the pure-black endpoint.
        let graded = graded + min(separation, 1 - max(graded.x, graded.y, graded.z))
        guard profile.hasPortraitAdjustment else { return graded }
        let outY = luma(graded)
        let uv = SIMD2((input.z - y) / 1.8556, (input.x - y) / 1.5748)
        let outUV = SIMD2((graded.z - outY) / 1.8556, (graded.x - outY) / 1.5748)
        let sourceChroma = length(uv), outputChroma = length(outUV)
        let ratio = -uv.x / max(uv.y, 0.000001)
        // Feathered input hue/chroma gate: may also include warm objects such as
        // wood or orange fabric. Never claim semantic skin identification.
        let hueGate = smooth(0.35, 0.55, ratio) * (1 - smooth(1.10, 1.40, ratio))
            * smooth(0.005, 0.025, uv.y) * (1 - smooth(-0.015, 0.005, uv.x))
        let chromaGate = smooth(0.015, 0.045, sourceChroma) * (1 - smooth(0.20, 0.28, sourceChroma))
        let skin = hueGate * chromaGate * smooth(0.025, 0.07, y) * (1 - smooth(0.80, 0.98, y))
        let shadow = max(0, y * profile.shadowRetention - outY) * (1 - smooth(0.15, 0.40, y))
        guard skin > 0 || shadow > 0 else { return graded }

        let direction = uv / max(sourceChroma, 0.000001)
        var pulled = outUV + skin * profile.skinHue * (direction * outputChroma - outUV)
        pulled *= outputChroma / max(length(pulled), 0.000001)
        let excess = max(0, outputChroma - sourceChroma * 1.35)
        let targetChroma = max(0, outputChroma - excess * skin * profile.skinChroma)
        pulled *= targetChroma / max(outputChroma, 0.000001)
        let skinLift = max(0, y - outY) * skin * profile.skinLightness
        // Add only missing shadow separation, keeping source black/white intact.
        let luminance = outY + max(shadow, skinLift)
        let red = luminance + 1.5748 * pulled.y
        let blue = luminance + 1.8556 * pulled.x
        let green = (luminance - 0.2126 * red - 0.0722 * blue) / 0.7152
        return SIMD3(min(1, max(0, red)), min(1, max(0, green)), min(1, max(0, blue)))
    }
}
