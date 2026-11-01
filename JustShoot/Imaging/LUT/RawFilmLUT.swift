import Foundation
import CryptoKit
import CoreImage

enum FujifilmSimulation: String, CaseIterable, Codable, Sendable {
    case provia = "PROVIA", velvia = "Velvia", astia = "ASTIA"
    case classicChrome = "CLASSIC-CHROME", classicNeg = "CLASSIC-Neg.", acros = "ACROS"

    var displayName: String {
        rawValue.replacingOccurrences(of: "-", with: " ")
    }

    /// Dedicated capture covers adapted from the stocks' packaging and official mode artwork.
    var libraryCardImage: String? {
        switch self {
        case .provia: return "cover_fuji_provia_100f.heic"
        case .velvia: return "cover_fuji_velvia.heic"
        case .acros: return "cover_fuji_acros.heic"
        case .astia: return "cover_fuji_astia_100f.heic"
        case .classicChrome: return "cover_fuji_classic_chrome.heic"
        case .classicNeg: return "cover_fuji_classic_neg.heic"
        }
    }

    var resourceName: String {
        "FujiRaw" + rawValue.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
    }
}

/// Frozen at shutter time. Nil axes use the captured DNG's own neutral white point.
struct RawCaptureRecipe: Codable, Sendable, Equatable {
    var version = 1
    /// Missing on version 1 jobs: those always used the scene-linear official look.
    var inputSpace: FilmInputSpace? = nil
    let lutSHA256: String
    let temperature: Float?
    let tint: Float?
    let redCurve: [Float]
    let greenCurve: [Float]
    let blueCurve: [Float]

    var resolvedInputSpace: FilmInputSpace { inputSpace ?? .sceneLinearRec2020 }
    var requiresRawLUT: Bool { resolvedInputSpace == .sceneLinearRec2020 }

    init(lut: RawFilmLUT, curve: FilmCurve = .builtIn(.none),
         temperature: CameraWhiteBalanceSelection = .automatic, tint: CameraTintSelection = .automatic) {
        // Retain ProRAW's per-image local gain map before the film's global curve.
        // Version 1 journals remain readable with their original linear-only policy.
        version = 3
        inputSpace = .sceneLinearRec2020
        lutSHA256 = lut.sha256
        self.temperature = temperature.isAutomatic ? nil : temperature.kelvin
        if case .value(let value) = tint { self.tint = value } else { self.tint = nil }
        redCurve = curve.previewData.red
        greenCurve = curve.previewData.green
        blueCurve = curve.previewData.blue
    }

    init(displayLUT: CubeLUT, temperature: CameraWhiteBalanceSelection = .automatic,
         tint: CameraTintSelection = .automatic) {
        version = 2
        inputSpace = .displaySRGB
        lutSHA256 = Self.digest(displayLUT.data)
        self.temperature = temperature.isAutomatic ? nil : temperature.kelvin
        if case .value(let value) = tint { self.tint = value } else { self.tint = nil }
        // The frozen display cube already contains the user's curve, never their WB.
        let identity = FilmCurve.builtIn(.none).previewData
        redCurve = identity.red
        greenCurve = identity.green
        blueCurve = identity.blue
    }

    /// Version 4 freezes the exact viewfinder cube, including WB and the user
    /// curve. RAW decoding keeps the DNG neutral; applying manual WB here as well
    /// would adjust the photograph twice and diverge from preview/Live Photo.
    init(unifiedLUT: CubeLUT) {
        version = 4
        inputSpace = .displaySRGB
        lutSHA256 = Self.digest(unifiedLUT.data)
        temperature = nil
        tint = nil
        let identity = FilmCurve.builtIn(.none).previewData
        redCurve = identity.red
        greenCurve = identity.green
        blueCurve = identity.blue
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        ((version == 1 && inputSpace == nil)
            || (version == 2 && inputSpace == .displaySRGB)
            || (version == 3 && inputSpace == .sceneLinearRec2020)
            || (version == 4 && inputSpace == .displaySRGB && temperature == nil && tint == nil)) && lutSHA256.count == 64
            && (temperature.map { $0.isFinite && (2_000...50_000).contains($0) } ?? true)
            && (tint.map { $0.isFinite && (-150...150).contains($0) } ?? true)
            && [redCurve, greenCurve, blueCurve].allSatisfy {
                $0.count == 256 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
    }

    func validate(lut: RawFilmLUT) throws {
        guard isValid, requiresRawLUT, lut.sha256 == lutSHA256,
              tint.map({ $0.isFinite && (-150...150).contains($0) }) ?? true,
              [redCurve, greenCurve, blueCurve].allSatisfy({
                  $0.count == 256 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) }
              }) else { throw CubeLUT.ParseError.malformed }
    }

    func validate(displayLUT: CubeLUT) throws {
        guard isValid, !requiresRawLUT, Self.digest(displayLUT.data) == lutSHA256 else {
            throw CubeLUT.ParseError.malformed
        }
    }
}

/// Exact Float32 tables extracted from the verified CLF. Only the on-disk encoding changes.
struct RawFilmLUT: Sendable {
    static let dimension = 65
    static let tableBytes = 65_536 * MemoryLayout<Float>.stride
    static let cubeBytes = dimension * dimension * dimension * 4 * MemoryLayout<Float>.stride
    static let byteCount = 16 + tableBytes * 2 + cubeBytes
    let data: Data
    let sha256: String

    init(data: Data) throws {
        guard data.count == Self.byteCount, Array(data.prefix(8)) == Array("JSRAW001".utf8) else {
            throw CubeLUT.ParseError.malformed
        }
        try data.withUnsafeBytes { bytes in
            guard UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == 65,
                  UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) == 65_536 else {
                throw CubeLUT.ParseError.malformed
            }
            for offset in stride(from: 16, to: bytes.count, by: 4) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                guard value.isFinite, (0...1).contains(value) else { throw CubeLUT.ParseError.malformed }
            }
        }
        self.data = data
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func images() -> [CIImage] {
        let cubeStart = 16 + Self.tableBytes
        let outputStart = cubeStart + Self.cubeBytes
        return [
            CIImage(bitmapData: data.subdata(in: 16..<cubeStart), bytesPerRow: 256 * 4,
                    size: CGSize(width: 256, height: 256), format: .Rf, colorSpace: nil).samplingNearest(),
            CIImage(bitmapData: data.subdata(in: cubeStart..<outputStart), bytesPerRow: 65 * 16,
                    size: CGSize(width: 65, height: 65 * 65), format: .RGBAf, colorSpace: nil).samplingNearest(),
            CIImage(bitmapData: data.subdata(in: outputStart..<data.count), bytesPerRow: 256 * 4,
                    size: CGSize(width: 256, height: 256), format: .Rf, colorSpace: nil).samplingNearest()
        ]
    }
}

/// Serial, bounded preparation; no RAW table IO or validation runs in a SwiftUI update.
actor RawFilmLUTStore {
    static let shared = RawFilmLUTStore()
    private var cache = ByteBudgetLRU<String, RawFilmLUT>(maximumBytes: RawFilmLUT.byteCount * 2, maximumEntries: 2)

    func prepare(_ simulation: FujifilmSimulation) throws -> RawFilmLUT {
        try Task.checkCancellation()
        if let cached = cache.value(forKey: simulation.rawValue) { return cached }
        guard let url = Bundle.main.url(forResource: simulation.resourceName, withExtension: "jsraw") else {
            throw CubeLUT.ParseError.malformed
        }
        let lut = try RawFilmLUT(data: Data(contentsOf: url, options: .mappedIfSafe))
        try FilmProcessor.shared.prepareRawRendering()
        try Task.checkCancellation()
        cache.insert(lut, forKey: simulation.rawValue, cost: lut.data.count)
        return lut
    }
}
