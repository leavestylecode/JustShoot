import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
@testable import JustShoot

final class ColorTemperatureLUTTests: XCTestCase {
    private func identity(dimension: Int = 5) throws -> CubeLUT {
        let n = Float(dimension - 1)
        var floats: [Float] = []
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            floats.append(contentsOf: [Float(r) / n, Float(g) / n, Float(b) / n, 1])
        } } }
        return try CubeLUT.validated(data: floats.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dimension)
    }

    private func sample(_ lut: CubeLUT, red: Int = 2, green: Int = 2, blue: Int = 2) -> [Float] {
        let offset = (blue * lut.dimension * lut.dimension + green * lut.dimension + red) * 16
        return lut.data.withUnsafeBytes { bytes in
            (0..<4).map { bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Float.self) }
        }
    }

    func test5100KWorksWithoutAnyCaptureDevice() async throws {
        // Regression: the physical triple camera rejected hardware manual WB at this value.
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let result = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(5_100))
        XCTAssertEqual(result.dimension, base.dimension)
        XCTAssertEqual(result.data.count, base.data.count)
        XCTAssertNotEqual(result.data, base.data)
        XCTAssertEqual(sample(result)[3], 1, accuracy: 0.001)
    }

    func testAutoAndNeutralRestoreOriginalBytesExactly() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let automatic = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic)
        let neutral = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(6_500))
        XCTAssertEqual(automatic.data, base.data)
        XCTAssertEqual(neutral.data, base.data)
    }

    func testIncreasingKelvinWarmsAndDecreasingKelvinCools() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let warm = sample(try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(8_000)))
        let cool = sample(try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(3_000)))
        XCTAssertGreaterThan(warm[0], warm[2])
        XCTAssertLessThan(cool[0], cool[2])
    }

    func testBakedCubeKeepsRGBIndexOrder() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let result = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(5_100))
        let red = sample(result, red: 4, green: 0, blue: 0)
        let green = sample(result, red: 0, green: 4, blue: 0)
        let blue = sample(result, red: 0, green: 0, blue: 4)
        XCTAssertGreaterThan(red[0], max(red[1], red[2]))
        XCTAssertGreaterThan(green[1], max(green[0], green[2]))
        XCTAssertGreaterThan(blue[2], max(blue[0], blue[1]))
    }

    func testCaptureSnapshotIsUnchangedByLaterTemperatureSelection() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let captured = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(5_100))
        let originalBytes = captured.data
        _ = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(9_000))
        _ = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic)
        XCTAssertEqual(captured.data, originalBytes)
    }

    func testCacheHasByteAndEntryBounds() async throws {
        let base = try identity(dimension: 3)
        let builder = ColorTemperatureLUT(maximumCacheBytes: base.data.count * 2)
        for kelvin: Float in [3_000, 4_000, 5_000, 6_000] {
            _ = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(kelvin))
        }
        let count = await builder.cachedCount
        let bytes = await builder.cachedBytes
        XCTAssertEqual(count, 2)
        XCTAssertLessThanOrEqual(bytes, base.data.count * 2)
    }

    func testInvalidTemperatureFailsWithoutTouchingHardware() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        do {
            _ = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(.nan))
            XCTFail("Non-finite temperature must be rejected")
        } catch { XCTAssertTrue(error is CubeLUT.ParseError) }
    }

    func testRealFujiC200At5100KPreservesTableResolution() async throws {
        let builder = ColorTemperatureLUT()
        let source = FilmSource.preset(.fujiC200)
        let base = try await builder.prepare(source: source, curve: .builtIn(.none), selection: .automatic)
        let adjusted = try await builder.prepare(source: source, curve: .builtIn(.none), selection: .temperature(5_100))
        XCTAssertEqual(adjusted.dimension, base.dimension)
        XCTAssertEqual(adjusted.data.count, base.data.count)
        XCTAssertNotEqual(adjusted.data, base.data)
    }

    func testTemperatureIsAppliedBeforeTheFilmTransform() async throws {
        let identity = try identity()
        var invertedData = identity.data
        invertedData.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 16) {
                for channel in 0..<3 {
                    let position = offset + channel * 4
                    let value = bytes.loadUnaligned(fromByteOffset: position, as: Float.self)
                    bytes.storeBytes(of: Float(1) - value, toByteOffset: position, as: Float.self)
                }
            }
        }
        let inverted = try CubeLUT.validated(data: invertedData, dimension: identity.dimension)
        let result = try await ColorTemperatureLUT().prepare(base: inverted, baseKey: "invert", selection: .temperature(8_000))
        let gray = sample(result)
        // Warm neutral has R > B; a following inverting film must reverse that relation.
        XCTAssertLessThan(gray[0], gray[2])
    }

    @MainActor
    func testStillExportUsesThePreparedTemperatureSnapshot() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let input = try XCTUnwrap(renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.jpegData(compressionQuality: 1))
        let lut = try await ColorTemperatureLUT().prepare(base: identity(), baseKey: "gray", selection: .temperature(8_000))
        let data = await Task.detached {
            FilmProcessor.shared.applyLUTPreservingMetadata(imageData: input, lutCacheKey: "uncached-temperature-snapshot", capturedLUT: lut)
        }.value
        let image = try XCTUnwrap(CIImage(data: try XCTUnwrap(data)))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 12, y: 12, width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
        XCTAssertGreaterThan(pixel[0], pixel[2])
    }

    func testMalformedTableFailsBeforeCallingCoreImage() async throws {
        let invalid = CubeLUT(data: Data([0]), dimension: 5)
        do {
            _ = try await ColorTemperatureLUT().prepare(base: invalid, baseKey: "invalid", selection: .temperature(5_100))
            XCTFail("Malformed table must be rejected before setting CIFilter parameters")
        } catch { XCTAssertTrue(error is CubeLUT.ParseError) }
    }

    func testTintWorksWithAutomaticTemperatureAndHasTheExpectedDirection() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let green = sample(try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .value(-20)))
        let magenta = sample(try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .value(20)))
        XCTAssertGreaterThan(green[1], (green[0] + green[2]) / 2)
        XCTAssertLessThan(magenta[1], (magenta[0] + magenta[2]) / 2)
    }

    func testTemperatureAndTintHaveIndependentCacheKeysAndComposeTogether() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let temperature = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(5_100))
        let combined = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(5_100), tint: .value(25))
        let tintOnly = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .value(25))
        XCTAssertNotEqual(combined.data, temperature.data)
        XCTAssertNotEqual(combined.data, tintOnly.data)
        XCTAssertNotEqual(ColorTemperatureLUT.cacheKey(baseKey: "identity", selection: .automatic, tint: .value(-25)),
            ColorTemperatureLUT.cacheKey(baseKey: "identity", selection: .automatic, tint: .value(25)))
        let restored = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .automatic)
        XCTAssertEqual(restored.data, base.data)
    }

    func testInvalidTintIsRejectedEvenWithAutomaticTemperature() async throws {
        do {
            _ = try await ColorTemperatureLUT().prepare(base: identity(), baseKey: "identity", selection: .automatic, tint: .value(.nan))
            XCTFail("Invalid tint must not bypass validation through Auto temperature")
        } catch { XCTAssertTrue(error is CubeLUT.ParseError) }
    }

    func testBothAutomaticAxesUseOriginalLUTAsTheReadingChanges() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        for reading in [CameraWhiteBalanceReading(temperature: 3_400, tint: 8), CameraWhiteBalanceReading(temperature: 7_200, tint: -12)] {
            let output = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic,
                tint: .automatic, reference: reading)
            XCTAssertEqual(output.data, base.data)
            XCTAssertEqual(ColorTemperatureLUT.cacheKey(baseKey: "identity", selection: .automatic, tint: .automatic, reference: reading), "identity")
        }
    }

    func testSwitchingFromAutoToItsDisplayedValueDoesNotChangeTheImage() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let reading = try XCTUnwrap(CameraWhiteBalanceReading(temperature: 4_800, tint: 12))
        let manualTemperature = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(4_800), tint: .automatic, reference: reading)
        let manualTint = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .value(12), reference: reading)
        XCTAssertEqual(manualTemperature.data, base.data)
        XCTAssertEqual(manualTint.data, base.data)
    }

    func testManualAdjustmentIsRelativeToTheMeasuredCameraWhitePoint() async throws {
        let builder = ColorTemperatureLUT()
        let base = try identity()
        let reading = try XCTUnwrap(CameraWhiteBalanceReading(temperature: 4_800, tint: 12))
        let warmer = try await builder.prepare(base: base, baseKey: "identity", selection: .temperature(6_000), tint: .automatic, reference: reading)
        let magenta = try await builder.prepare(base: base, baseKey: "identity", selection: .automatic, tint: .value(25), reference: reading)
        XCTAssertGreaterThan(sample(warmer)[0], sample(warmer)[2])
        let pixel = sample(magenta)
        XCTAssertLessThan(pixel[1], (pixel[0] + pixel[2]) / 2)
        XCTAssertNotEqual(ColorTemperatureLUT.cacheKey(baseKey: "identity", selection: .temperature(6_000), reference: reading),
            ColorTemperatureLUT.cacheKey(baseKey: "identity", selection: .temperature(6_000), reference: .neutral))
    }
}
