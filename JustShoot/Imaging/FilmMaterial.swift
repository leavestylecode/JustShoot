import Foundation
import CryptoKit
import CoreImage

/// Frozen, self-contained material data. Density tables are numeric data, never color images.
struct FilmMaterial: Sendable, Codable {
    static let revision = "#material-v1"
    static let spectralV1Revision = "#spek-material-v1"
    static let spectralRevision = "#spek-material-v2"
    static let maximumBytes = 24 * 1_024 * 1_024

    /// Transport domains are frozen with the table bytes. A developed camera
    /// image is not scene radiance, even after inverse transfer-function decoding.
    struct Contract: Sendable, Codable, Equatable {
        enum Input: String, Codable, Sendable { case developedSRGB = "developed_srgb" }
        enum Intermediate: String, Codable, Sendable { case cmyOpticalDensity = "cmy_optical_density" }
        enum Output: String, Codable, Sendable { case encodedSRGB = "encoded_srgb" }
        let input: Input
        let intermediate: Intermediate
        let output: Output

        static let spectralSDR = Self(input: .developedSRGB, intermediate: .cmyOpticalDensity, output: .encodedSRGB)
    }

    struct Table: Sendable, Codable {
        let data: Data
        let dimension: Int
        // Copies of a material share immutable tables. This process-local token avoids
        // hashing megabytes on each WB/curve selection and never enters frozen recipes.
        let textureIdentifier = UUID()
        private enum CodingKeys: String, CodingKey { case data, dimension }

        init(_ cube: CubeLUT) { data = cube.data; dimension = cube.dimension }
        var cube: CubeLUT { CubeLUT(data: data, dimension: dimension) }
        var isIdentity: Bool { dimension == 2 && data == FilmMaterial.identityTable.data }
        func validate() throws {
            guard (2...65).contains(dimension) else { throw CubeLUT.ParseError.malformed }
            _ = try CubeLUT.validated(data: data, dimension: dimension)
            guard data.withUnsafeBytes({ bytes in
                stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                    (0...1).contains(bytes.loadUnaligned(fromByteOffset: $0, as: Float.self))
                }
            }) else { throw CubeLUT.ParseError.malformed }
        }
        var image: CIImage {
            CIImage(bitmapData: data, bytesPerRow: dimension * 16,
                size: CGSize(width: dimension, height: dimension * dimension),
                format: .RGBAf, colorSpace: nil).samplingNearest()
        }
    }

    let version: Int
    let identifier: String
    var input: Table
    let density: Table
    let print: Table
    var finish: Table
    let densityMaximum: SIMD3<Float>
    let refinement: SIMD4<Float>
    var colorBalance: FilmColorBalanceParameters? = nil
    var calibration: FilmMaterialCalibration? = nil
    var contract: Contract? = nil
    // Optional only for schema-1 journals. Schema 2 requires an explicit range.
    var densityMinimum: SIMD3<Float>? = nil
    var densityFloor: SIMD3<Float> { densityMinimum ?? .zero }
    var exposureResponse: Float { version == 2 ? 1 : 0 }

    var byteCount: Int { input.data.count + density.data.count + print.data.count + finish.data.count }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CubeLUT.ParseError.malformed }
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func validate() throws {
        let knownModel = (version == 1 && identifier == "portra-endura-density-v1"
            && contract == nil && densityMinimum == nil && calibration == nil)
            || (version == 2 && identifier == "spek-portra-endura-density-v1"
                && contract == .spectralSDR && densityMinimum != nil)
        guard knownModel,
              byteCount <= Self.maximumBytes,
              (0..<3).allSatisfy({ densityMaximum[$0].isFinite && (0.01...8).contains(densityMaximum[$0]) }),
              (0..<3).allSatisfy({ densityFloor[$0].isFinite && (-1...0).contains(densityFloor[$0]) }),
              (0..<4).allSatisfy({ refinement[$0].isFinite && (0...0.6).contains(refinement[$0]) }),
              colorBalance?.isValid ?? true, calibration?.isValid ?? true else {
            throw CubeLUT.ParseError.malformed
        }
        for table in [input, density, print, finish] { try table.validate() }
    }

    private static let identityTable: Table = {
        var values: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { values += [Float(r), Float(g), Float(b), 1] } } }
        return Table(CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 2))
    }()

    static func identity() -> Table { identityTable }

    static func load(preset: FilmPreset, balanced: Bool = true) throws -> Self? {
        guard preset == .kodakPortra400 else { return nil }
        return try loadSpectralPortra(balanced: balanced)
    }

    /// Explicit historical loader for cache-key recovery and regression fixtures.
    static func loadLegacy(preset: FilmPreset, balanced: Bool = true) throws -> Self? {
        guard preset == .kodakPortra400 else { return nil }
        return try loadResource("PortraEndura-material-v1", balanced: balanced)
    }

    static func loadSpectralPortra(balanced: Bool = true) throws -> Self {
        var material = try loadSpectralPortraV1(balanced: balanced)
        material.calibration = balanced ? .portra : nil
        return material
    }

    /// Frozen first spectral rendering, before the product tone/grain calibration.
    static func loadSpectralPortraV1(balanced: Bool = true) throws -> Self {
        try loadResource("SpekPortraEndura-material-v1", balanced: balanced)
    }

    private static func loadResource(_ name: String, balanced: Bool) throws -> Self {
        struct Manifest: Decodable {
            struct Resource: Decodable { let file: String; let dimension: Int; let sha256: String }
            let version: Int
            let identifier: String
            let densityMaximum: [Float]
            let densityMinimum: [Float]?
            let contract: Contract?
            let tables: [String: Resource]
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CubeLUT.ParseError.malformed
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        func table(_ name: String) throws -> Table {
            guard let resource = manifest.tables[name], resource.dimension == 65,
                  let url = Bundle.main.url(forResource: resource.file, withExtension: nil) else { throw CubeLUT.ParseError.malformed }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard digest(data) == resource.sha256 else { throw CubeLUT.ParseError.malformed }
            return Table(try CubeLUT.validated(data: data, dimension: resource.dimension))
        }
        guard manifest.densityMaximum.count == 3,
              manifest.densityMinimum == nil || manifest.densityMinimum?.count == 3 else { throw CubeLUT.ParseError.malformed }
        let result = Self(version: manifest.version, identifier: manifest.identifier, input: identity(),
            density: try table("density"), print: try table("print"), finish: identity(),
            densityMaximum: SIMD3(manifest.densityMaximum),
            refinement: (manifest.version == 1 || balanced) ? try FilmLookRefinement.parameters(for: .kodakPortra400) : .zero,
            colorBalance: balanced ? .portra : nil, contract: manifest.contract,
            densityMinimum: manifest.densityMinimum.map { SIMD3($0) })
        try result.validate()
        return result
    }
}
