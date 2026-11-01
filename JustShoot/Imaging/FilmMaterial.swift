import Foundation
import CryptoKit
import CoreImage

/// Frozen, self-contained material data. Density tables are numeric data, never color images.
struct FilmMaterial: Sendable, Codable {
    static let revision = "#material-v1"
    static let maximumBytes = 24 * 1_024 * 1_024

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
        guard version == 1, identifier == "portra-endura-density-v1",
              byteCount <= Self.maximumBytes,
              (0..<3).allSatisfy({ densityMaximum[$0].isFinite && (0.01...8).contains(densityMaximum[$0]) }),
              (0..<4).allSatisfy({ refinement[$0].isFinite && (0...0.6).contains(refinement[$0]) }) else {
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

    static func load(preset: FilmPreset) throws -> Self? {
        guard preset == .kodakPortra400 else { return nil }
        struct Manifest: Decodable {
            struct Resource: Decodable { let file: String; let dimension: Int; let sha256: String }
            let version: Int
            let identifier: String
            let densityMaximum: [Float]
            let tables: [String: Resource]
        }
        guard let url = Bundle.main.url(forResource: "PortraEndura-material-v1", withExtension: "json") else {
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
        guard manifest.densityMaximum.count == 3 else { throw CubeLUT.ParseError.malformed }
        let result = Self(version: manifest.version, identifier: manifest.identifier, input: identity(),
            density: try table("density"), print: try table("print"), finish: identity(),
            densityMaximum: SIMD3(manifest.densityMaximum), refinement: try FilmLookRefinement.parameters(for: preset))
        try result.validate()
        return result
    }
}
