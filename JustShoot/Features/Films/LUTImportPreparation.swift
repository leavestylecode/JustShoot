import Foundation

/// The .cube format does not identify gamma or primaries. These are complete
/// SDR input/output contracts, chosen explicitly rather than guessed from a title.
enum LUTColorEncoding: String, CaseIterable, Sendable, Identifiable {
    case sRGB
    case rec709Gamma24

    var id: String { rawValue }
}

actor LUTImportPreparation {
    static let shared = LUTImportPreparation()

    func read(_ url: URL) throws -> CubeLUT {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let cube = try CubeLUT.parse(FilmProcessor.readCubeText(from: url))
        try Task.checkCancellation()
        return cube
    }

    /// Convert once, before indexing. Camera entry never parses the source again.
    /// Failed or cancelled writes cannot leave a partially readable table.
    func save(_ cube: CubeLUT, encoding: LUTColorEncoding, to url: URL) throws -> Int {
        let canonical = try Self.canonicalCube(cube, encoding: encoding)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Self.compiledData(canonical).write(to: url, options: .atomic)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return canonical.dimension
    }

    static func compiledData(_ cube: CubeLUT) -> Data {
        var data = Data("JSLUT001".utf8)
        var dimension = UInt32(cube.dimension).littleEndian
        var count = UInt32(cube.data.count / 4).littleEndian
        withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(cube.data)
        return data
    }

    /// sRGB is lossless. Gamma 2.4 uses the same D65/709 primaries and is
    /// conjugated on both sides of the original cube, with at least 65³ samples.
    /// This is a display transform, not an inverse of camera tone mapping.
    static func canonicalCube(_ cube: CubeLUT, encoding: LUTColorEncoding) throws -> CubeLUT {
        guard encoding != .sRGB else { return cube }
        let dimension = max(65, cube.dimension)
        let sourceDimension = cube.dimension
        let levels = (0..<dimension).map { i -> Float in
            let v = Float(i) / Float(dimension - 1)
            let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            return pow(linear, 1 / 2.4) * Float(sourceDimension - 1)
        }
        var output = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        try cube.data.withUnsafeBytes { bytes in
            func sample(_ r: Int, _ g: Int, _ b: Int, _ channel: Int) -> Float {
                bytes.loadUnaligned(fromByteOffset: ((b * sourceDimension + g) * sourceDimension + r) * 16 + channel * 4,
                                    as: Float.self)
            }
            for b in 0..<dimension {
                try Task.checkCancellation()
                let bz = levels[b], b0 = Int(bz), b1 = min(b0 + 1, sourceDimension - 1), bf = bz - Float(b0)
                for g in 0..<dimension {
                    let gy = levels[g], g0 = Int(gy), g1 = min(g0 + 1, sourceDimension - 1), gf = gy - Float(g0)
                    for r in 0..<dimension {
                        let rx = levels[r], r0 = Int(rx), r1 = min(r0 + 1, sourceDimension - 1), rf = rx - Float(r0)
                        for channel in 0..<3 {
                            func row(_ g: Int, _ b: Int) -> Float {
                                let a = sample(r0, g, b, channel)
                                return a + (sample(r1, g, b, channel) - a) * rf
                            }
                            let low = row(g0, b0) * (1 - gf) + row(g1, b0) * gf
                            let high = row(g0, b1) * (1 - gf) + row(g1, b1) * gf
                            let value = low * (1 - bf) + high * bf
                            let linear = copysign(pow(abs(value), 2.4), value)
                            output[((b * dimension + g) * dimension + r) * 4 + channel] = linear <= 0.0031308
                                ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return try CubeLUT.validated(data: output.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
    }
}
