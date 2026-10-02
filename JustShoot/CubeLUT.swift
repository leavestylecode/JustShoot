import Foundation

struct CubeLUT: Sendable {
    let data: Data
    let dimension: Int

    enum ParseError: LocalizedError {
        case malformed
        case unsupportedDomain

        var errorDescription: String? {
            switch self {
            case .malformed: String(localized: "This LUT is invalid or unsupported.")
            case .unsupportedDomain: String(localized: "This LUT uses an unsupported input range.")
            }
        }
    }

    static let maximumDimension = 128
    static let maximumFileBytes = 128 * 1024 * 1024

    static func validated(data: Data, dimension: Int) throws -> CubeLUT {
        guard (2...maximumDimension).contains(dimension),
              data.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.stride else {
            throw ParseError.malformed
        }
        let finite = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                bytes.loadUnaligned(fromByteOffset: $0, as: Float.self).isFinite
            }
        }
        guard finite else { throw ParseError.malformed }
        return CubeLUT(data: data, dimension: dimension)
    }

    static func parse(_ text: String) throws -> CubeLUT {
        guard text.utf8.count <= maximumFileBytes else { throw ParseError.malformed }
        var dimension: Int?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        func vector(_ tokens: [Substring]) throws -> [Float] {
            let numbers = tokens.compactMap { Float($0) }
            guard tokens.count == 3, numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
                throw ParseError.malformed
            }
            return numbers
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let tokens = line.split { $0 == " " || $0 == "\t" }
            guard let first = tokens.first else { continue }
            switch first.uppercased() {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard dimension == nil, values.isEmpty, tokens.count == 2,
                      let size = Int(tokens[1]), (2...maximumDimension).contains(size) else {
                    throw ParseError.malformed
                }
                dimension = size
                values.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN": domainMin = try vector(Array(tokens.dropFirst()))
            case "DOMAIN_MAX": domainMax = try vector(Array(tokens.dropFirst()))
            default:
                guard let dimension, values.count < dimension * dimension * dimension * 4 else {
                    throw ParseError.malformed
                }
                values.append(contentsOf: try vector(tokens))
                values.append(1)
            }
        }

        guard let dimension, values.count == dimension * dimension * dimension * 4,
              (0..<3).allSatisfy({ domainMin[$0] < domainMax[$0] }) else {
            throw ParseError.malformed
        }

        // Core Image and the preview sample a unit-domain cube. Reject unsupported domains
        // explicitly rather than approximating them and silently changing the film's colors.
        guard domainMin == [0, 0, 0], domainMax == [1, 1, 1] else { throw ParseError.unsupportedDomain }
        return CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
    }
}
