import XCTest
import SwiftData
import CoreImage
@testable import JustShoot

private actor FinalPhotoGate {
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private(set) var calls = 0
    private(set) var peak = 0
    var active: Int { pending.count }

    func wait(_ id: String) async throws -> Data {
        calls += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                peak = max(peak, pending.count)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

@MainActor
final class CaptureSchedulingTests: XCTestCase {
    func testSlowFinalizationDoesNotBlockReadyPhotoAndWaitersStayBounded() async throws {
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let image = CIImage(color: CIColor(red: 0.5, green: 0.3, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 36))
        let data = try XCTUnwrap(CIContext().jpegRepresentation(of: image, colorSpace: FilmImagePipeline.colorSpace))
        var slowIDs: [UUID] = []
        for index in 0..<3 {
            let recipe = recipe(lut: lut, date: Date(timeIntervalSince1970: Double(index)))
            let state = DeferredPhotoState(width: 48, height: 36, assetIdentifier: recipe.id.uuidString)
            _ = try journal.stage(recipe: recipe, imageData: data, movieURL: nil, lut: lut, deferredPhoto: state)
            slowIDs.append(recipe.id)
        }
        let readyRecipe = recipe(lut: lut, date: Date())
        var ready = try journal.stage(recipe: readyRecipe, imageData: data, movieURL: nil, lut: lut)
        // This fixture was already exported: exercise real rendering/indexing without touching Photos.
        ready.assetIdentifier = "fixture-asset"
        try journal.update(ready)
        let gate = FinalPhotoGate()
        let pipeline = CapturePipeline(journal: journal, finalizeDeferredPhoto: { id, _ in try await gate.wait(id) })
        await pipeline.configure(container: container)
        let deadline = Date().addingTimeInterval(8)
        while pipeline.lastCompletion?.captureID != ready.id && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pipeline.lastCompletion?.captureID, ready.id, "A waiting 24 MP job must yield the render lane")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Photo>()), 1)
        let active = await gate.active
        let peak = await gate.peak
        let calls = await gate.calls
        XCTAssertEqual(active, 2)
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(calls, 2)
        await pipeline.retryPending()
        let afterRetry = await gate.calls
        XCTAssertEqual(afterRetry, calls, "Recovery must not duplicate a suspended system request")
        await pipeline.enterBackground()
        let cancelledDeadline = Date().addingTimeInterval(3)
        while await gate.active != 0 && Date() < cancelledDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let remaining = await gate.active
        XCTAssertEqual(remaining, 0, "Backgrounding cancels outstanding PhotoKit waits")
        XCTAssertEqual(try journal.jobs().count, 3)
        for id in slowIDs { XCTAssertEqual(try Data(contentsOf: journal.file("original.image", for: id)), data) }
        await pipeline.retryPending()
        let resumedDeadline = Date().addingTimeInterval(3)
        while await gate.calls < 4 && Date() < resumedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let resumedCalls = await gate.calls
        let resumedActive = await gate.active
        let resumedPeak = await gate.peak
        XCTAssertEqual(resumedCalls, 4)
        XCTAssertEqual(resumedActive, 2)
        XCTAssertEqual(resumedPeak, 2, "Foreground recovery must keep the same concurrency limit")
        await pipeline.enterBackground()
    }

    private func recipe(lut: CubeLUT, date: Date) -> CaptureRecipe {
        CaptureRecipe(id: UUID(), captureDate: date, filterName: "scheduling", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil, photoDisplayTime: nil,
            plan: .resolve(mode: .quality, rawFormat: nil, prefersProcessedPhoto: true))
    }
}
