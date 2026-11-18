import XCTest
import SwiftData
import CoreImage
@testable import JustShoot

/// Keeps the injected PhotoKit re-read parked until the test decides its outcome,
/// mirroring the gate pattern from CaptureSchedulingTests.
private actor FinalPhotoGate {
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private(set) var calls = 0
    private(set) var cancellations = 0

    func wait(_ id: String, onRegistration: @Sendable () -> Void = {}) async throws -> Data {
        calls += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                onRegistration()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func resolve(_ id: String, with data: Data) {
        pending.removeValue(forKey: id)?.resume(returning: data)
    }

    func fail(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: PhotoLibraryError.saveFailed)
    }

    private func cancel(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }
}

private actor AdjustmentRecorder {
    private(set) var committed: [(data: Data, id: String)] = []
    func record(_ data: Data, id: String) { committed.append((data, id)) }
}

@MainActor
final class CaptureFinalStillRaceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private struct Fixture {
        let journal: CaptureJournal
        let container: ModelContainer
        let recipe: CaptureRecipe
        let final: Data
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let journal = CaptureJournal(root: root)
        let container = try ModelContainer(for: Photo.self, CustomLUT.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let lut = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let image = CIImage(color: CIColor(red: 0.5, green: 0.3, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 36))
        let data = try XCTUnwrap(CIContext().jpegRepresentation(of: image, colorSpace: FilmImagePipeline.colorSpace))
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "race", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmPreset.fujiC200.renderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, plan: .resolve(mode: .quality))
        let state = DeferredPhotoState(width: 48, height: 36, assetIdentifier: recipe.id.uuidString)
        _ = try journal.stage(recipe: recipe, imageData: data, movieURL: nil, lut: lut, deferredPhoto: state)
        return Fixture(journal: journal, container: container, recipe: recipe, final: data)
    }

    private func makePipeline(fixture: Fixture, gate: FinalPhotoGate, recorder: AdjustmentRecorder,
                              finalStillTimeout: TimeInterval = 60) -> CapturePipeline {
        CapturePipeline(journal: fixture.journal,
            finalizeDeferredPhoto: { id, _ in try await gate.wait(id) },
            prepareDeferredEditingInput: { _ in nil },
            saveDeferredAdjustment: { data, id, _, _ in await recorder.record(data, id: id) },
            finalStillTimeout: finalStillTimeout)
    }

    private func waitForReRead(gate: FinalPhotoGate) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await gate.calls < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let calls = await gate.calls
        XCTAssertGreaterThanOrEqual(calls, 1, "The PhotoKit re-read must be racing")
    }

    private func waitForCompletion(_ pipeline: CapturePipeline, captureID: UUID) async throws {
        let deadline = Date().addingTimeInterval(15)
        while pipeline.lastCompletion?.captureID != captureID, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pipeline.lastCompletion?.captureID, captureID)
    }

    func testProxyReceiptProtectsAnActiveCaptureBeforeItsAssetIsInTheManifest() async throws {
        let fixture = try fixture()
        let journal = fixture.journal
        var job = try journal.job(for: fixture.recipe.id)
        job.deferredPhoto?.assetIdentifier = nil
        try journal.update(job)
        let gate = FinalPhotoGate()
        let final = fixture.final
        let receipt = UUID().uuidString
        let pipeline = CapturePipeline(journal: journal, storeDeferredProxy: { _, recipe in
            try journal.recordProxyPlaceholder(receipt, for: recipe.id)
            _ = try await gate.wait(receipt)
            return receipt
        }, finalizeDeferredPhoto: { _, _ in final }, prepareDeferredEditingInput: { _ in nil },
            saveDeferredAdjustment: { _, _, _, _ in })
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)
        let deletion = await pipeline.beginDeletion(rowIDs: [UUID()], assetIDs: [receipt])
        XCTAssertNil(deletion, "A renamed proxy must not bypass capture deletion protection")
        await gate.resolve(receipt, with: final)
        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
    }

    func testNativeFinalWinsWhilePhotoKitReReadStaysParked() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)

        pipeline.deliverFinalStill(fixture.final, id: fixture.recipe.id)

        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
        let committed = await recorder.committed
        XCTAssertEqual(committed.map(\.id), [fixture.recipe.id.uuidString],
            "The film adjustment must commit the delegate-delivered final")
        let cancellations = await gate.cancellations
        XCTAssertGreaterThanOrEqual(cancellations, 1, "Winning via the delegate must cancel the re-read")
        XCTAssertEqual(try fixture.container.mainContext.fetchCount(FetchDescriptor<Photo>()), 1)
        XCTAssertTrue(try fixture.journal.jobs().isEmpty)
    }

    func testPhotoKitReReadStillCompletesTheChainWithoutNativeDelivery() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)

        await gate.resolve(fixture.recipe.id.uuidString, with: fixture.final)

        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
        let committed = await recorder.committed
        XCTAssertEqual(committed.map(\.id), [fixture.recipe.id.uuidString])
    }

    func testDeferredRenderIsCheckpointedWhileEditingInputIsPending() async throws {
        let fixture = try fixture()
        let editing = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let bytes = fixture.final
        let pipeline = CapturePipeline(journal: fixture.journal,
            finalizeDeferredPhoto: { _, _ in bytes },
            prepareDeferredEditingInput: { id in _ = try await editing.wait(id); return nil },
            saveDeferredAdjustment: { data, id, _, _ in await recorder.record(data, id: id) })
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: editing)
        let id = fixture.recipe.id
        let deadline = Date().addingTimeInterval(10)
        while try !fixture.journal.job(for: id).rendered, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try fixture.journal.job(for: id).rendered)
        let checkpoint = try Data(contentsOf: fixture.journal.file("rendered.image", for: id))
        XCTAssertNil(pipeline.lastCompletion)
        await pipeline.enterBackground()
        await editing.resolve(id.uuidString, with: Data())
        try await waitForCompletion(pipeline, captureID: id)
        let committed = await recorder.committed
        XCTAssertEqual(committed.map(\.data), [checkpoint])
    }

    func testBackgroundLetsReadyPhotoCommitToTheSameAssetWithoutResume() async throws {
        let fixture = try fixture()
        let saving = FinalPhotoGate()
        let saveStarted = expectation(description: "The rendered adjustment reached the Photos save")
        let bytes = fixture.final
        let pipeline = CapturePipeline(journal: fixture.journal,
            finalizeDeferredPhoto: { _, _ in bytes },
            prepareDeferredEditingInput: { _ in nil },
            saveDeferredAdjustment: { _, id, _, _ in
                _ = try await saving.wait(id) { saveStarted.fulfill() }
                try Task.checkCancellation()
            })
        await pipeline.configure(container: fixture.container)
        await fulfillment(of: [saveStarted], timeout: 30)
        await pipeline.enterBackground()
        await saving.resolve(fixture.recipe.id.uuidString, with: Data())
        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
        let rows = try fixture.container.mainContext.fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(rows.map(\.assetLocalIdentifier), [fixture.recipe.id.uuidString])
        XCTAssertTrue(try fixture.journal.jobs().isEmpty)
    }

    func testMismatchedNativeFinalIsIgnoredAndPhotoKitRecovers() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)

        pipeline.deliverFinalStill(Data([1, 2, 3]), id: fixture.recipe.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(pipeline.lastCompletion, "Invalid native bytes must not complete the chain")

        await gate.resolve(fixture.recipe.id.uuidString, with: fixture.final)
        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
    }

    func testLateNativeFinalAfterCompletionIsDropped() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)
        await gate.resolve(fixture.recipe.id.uuidString, with: fixture.final)
        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)

        pipeline.deliverFinalStill(fixture.final, id: fixture.recipe.id)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(try fixture.container.mainContext.fetchCount(FetchDescriptor<Photo>()), 1,
            "A late native final must not resurrect the finished capture")
        XCTAssertTrue(try fixture.journal.jobs().isEmpty)
        XCTAssertEqual(pipeline.lastCompletion?.captureID, fixture.recipe.id)
    }

    func testPhasePublishesPreparingAndClearsOnCompletion() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)
        XCTAssertEqual(pipeline.phases[fixture.recipe.id], .preparing,
            "A parked final race must publish the preparing phase for the saving UI")
        await gate.resolve(fixture.recipe.id.uuidString, with: fixture.final)
        try await waitForCompletion(pipeline, captureID: fixture.recipe.id)
        XCTAssertNil(pipeline.phases[fixture.recipe.id], "Completion must clear the published phase")
    }

    func testFailedDeferredCaptureUnderDeletionIgnoresNativeFinal() async throws {
        let fixture = try fixture()
        let gate = FinalPhotoGate()
        let recorder = AdjustmentRecorder()
        let pipeline = makePipeline(fixture: fixture, gate: gate, recorder: recorder, finalStillTimeout: 0.3)
        await pipeline.configure(container: fixture.container)
        try await waitForReRead(gate: gate)

        await gate.fail(fixture.recipe.id.uuidString)
        let deadline = Date().addingTimeInterval(5)
        while pipeline.recoveryIssues.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(pipeline.recoveryIssues.isEmpty, "Both sources failing must surface a recovery issue")

        XCTAssertTrue(pipeline.beginDeletion([fixture.recipe.id]))
        pipeline.deliverFinalStill(fixture.final, id: fixture.recipe.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try fixture.journal.jobs().first?.deferredPhoto?.finalized, false,
            "A native final under deletion must not leak into the retained journal job")
        pipeline.endDeletion([fixture.recipe.id])
    }
}
