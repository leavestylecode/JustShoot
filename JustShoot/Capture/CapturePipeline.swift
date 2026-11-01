import SwiftUI
import SwiftData
import AVFoundation
import os

/// MainActor admits a deletion only while its captures are idle. The worker reads this gate
/// before processing recovered jobs, including while a system deletion confirmation is open.
final class CaptureDeletionGate: Sendable {
    private let deleting = OSAllocatedUnfairLock(initialState: Set<UUID>())

    func begin(_ ids: Set<UUID>, active: Set<UUID>) -> Bool {
        guard ids.isDisjoint(with: active) else { return false }
        return deleting.withLock {
            guard $0.isDisjoint(with: ids) else { return false }
            $0.formUnion(ids)
            return true
        }
    }

    func end(_ ids: Set<UUID>) { deleting.withLock { $0.subtract(ids) } }
    func contains(_ id: UUID) -> Bool { deleting.withLock { $0.contains(id) } }
}

struct CaptureCompletion: Identifiable, Sendable {
    let id: UUID
    let captureID: UUID
    let filterName: String
    let thumbnail: UIImage?
    let captureDate: Date
}

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()
    @Published private(set) var pendingCount = 0
    @Published private(set) var retainedCount = 0
    @Published private(set) var recoveryIssues: [CaptureRecoveryIssue] = []
    @Published private(set) var lastCompletion: CaptureCompletion?
    @Published private(set) var lastPreview: CapturePreview?
    @Published var lastError: String?

    private var worker: CaptureWorker?
    private let journal: CaptureJournal
    private let storeDeferredProxy: @Sendable (Data, CaptureRecipe) async throws -> String
    private let finalizeDeferredPhoto: @Sendable (String, DeferredPhotoState) async throws -> Data

    init(journal: CaptureJournal = .application,
         storeDeferredProxy: @escaping @Sendable (Data, CaptureRecipe) async throws -> String = {
             try await PhotoLibrary.saveDeferredProxy($0, recipe: $1)
         },
         finalizeDeferredPhoto: @escaping @Sendable (String, DeferredPhotoState) async throws -> Data = {
             try await PhotoLibrary.finalizedDeferredPhoto(id: $0, expected: $1)
         }) {
        self.journal = journal
        self.storeDeferredProxy = storeDeferredProxy
        self.finalizeDeferredPhoto = finalizeDeferredPhoto
    }

    fileprivate func recordFailure(_ message: String) { lastError = message }
    private let deletionGate = CaptureDeletionGate()
    @Published private var isReady = false
    private var queueState = CaptureQueueState()
    private var previewTask: Task<Void, Never>?
    private var previewCaptureID: UUID?
    var pendingJobIDs: Set<UUID> { queueState.pendingJobIDs }
    func isProcessing(_ id: UUID) -> Bool { queueState.activeIDs.contains(id) }

    var canCapture: Bool {
        isReady && worker != nil && queueState.occupiedCount < CaptureJournal.maximumJobs
    }

    /// Entry preparation needs a configured worker, independently of queue capacity.
    var isPrepared: Bool { isReady && worker != nil }

    func configure(container: ModelContainer) async {
        guard worker == nil else { return }
        let worker = CaptureWorker(container: container, deletionGate: deletionGate, journal: journal,
            storeDeferredProxy: storeDeferredProxy, finalizeDeferredPhoto: finalizeDeferredPhoto, owner: self)
        self.worker = worker
        await worker.resume(allowProcessing: UIApplication.shared.applicationState != .background)
        isReady = true
    }

    func reserve(lutBytes: Int, id: UUID = UUID()) async -> UUID? {
        let trace = DiagnosticTrace(id: id.uuidString)
        guard canCapture, let worker else {
            trace.event("capture_reservation_rejected", "reason=capacity pending=\(pendingCount) retained=\(retainedCount)")
            lastError = String(localized: "Please wait for your photos to finish saving.")
            return nil
        }
        let spaceCheck = trace.span("capture_storage_check")
        guard queueState.reserve(id, bytes: 128 * 1_024 * 1_024 + Int64(lutBytes), maximumJobs: CaptureJournal.maximumJobs) else { return nil }
        updateCounts()
        let hasSpace = await worker.hasRoom(for: queueState.reservedBytes, trace: trace)
        spaceCheck.end(hasSpace ? "ok" : "insufficient_space")
        guard hasSpace else {
            cancelReservation(id)
            lastError = String(localized: "Please wait for your photos to finish saving, or free up storage.")
            return nil
        }
        trace.event("capture_reserved", "pending=\(pendingCount) reserved_mb=\(queueState.reservedBytes / 1_048_576)")
        return id
    }

    func cancelReservation(_ id: UUID) {
        queueState.cancelReservation(id)
        if !isProcessing(id), !pendingJobIDs.contains(id) { clearPreview(id) }
        updateCounts()
    }

    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT? = nil) {
        guard let worker else { cancelReservation(recipe.id); return }
        if let warning = result.warning { lastError = warning.message }
        Task(priority: .utility) {
            let activity = CaptureBackgroundActivity()
            do {
                try await worker.enqueue(result, recipe: recipe, lut: lut, rawLUT: rawLUT)
            } catch {
                cancelReservation(recipe.id)
                lastError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
                await worker.refreshRecoveryState(reconcileStorage: true)
            }
            activity.end()
        }
    }

    /// Persist before the camera releases the shutter; video delivery can arrive later.
    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT? = nil) async {
        guard let worker else { return }
        let activity = CaptureBackgroundActivity()
        defer { activity.end() }
        do {
            try await worker.checkpointStill(still, recipe: recipe, lut: lut, rawLUT: rawLUT)
        } catch {
            // Keep the reservation and native bytes. Final delivery retries staging the complete
            // capture, and a staging directory with a committed manifest remains recoverable.
            lastError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
        }
    }

    func preparePreview(_ frame: CameraPreviewFrame, recipe: CaptureRecipe, lut: CubeLUT) {
        previewTask?.cancel()
        previewCaptureID = recipe.id
        previewTask = Task(priority: .utility) { [weak self] in
            let trace = DiagnosticTrace(id: recipe.id.uuidString)
            let preview = trace.span("capture_quick_preview")
            let image = await CapturePreviewRenderer.image(frame: frame, lut: lut, recipe: recipe)
            preview.end(Task.isCancelled ? "cancelled" : image == nil ? "missing" : "ok")
            guard !Task.isCancelled, let self, self.previewCaptureID == recipe.id else { return }
            self.previewTask = nil
            guard self.isProcessing(recipe.id) || self.pendingJobIDs.contains(recipe.id), let image else { return }
            self.lastPreview = CapturePreview(id: recipe.id, filterName: recipe.filterName, image: image)
        }
    }

    private func clearPreview(_ id: UUID) {
        if previewCaptureID == id {
            previewTask?.cancel()
            previewTask = nil
            previewCaptureID = nil
        }
        if lastPreview?.id == id { lastPreview = nil }
    }

    func retryPending() async {
        guard UIApplication.shared.applicationState != .background else { return }
        await worker?.resume()
    }
    func enterBackground() async {
        previewTask?.cancel()
        previewTask = nil
        await worker?.pause()
    }

    func beginDeletion(_ ids: [UUID]) -> Bool {
        guard deletionGate.begin(Set(ids), active: queueState.activeIDs) else {
            lastError = String(localized: "Please wait for these photos to finish saving before deleting them.")
            return false
        }
        Diagnostics.emit("photo_delete_begin", fields: "count=\(ids.count)")
        return true
    }

    /// A recovered/upserted row can keep a different UUID from the journal's capture.
    /// Protect both identities, including an asset saved before its identifier was checkpointed.
    func beginDeletion(rowIDs: [UUID], assetIDs: [String]) async -> [UUID]? {
        do {
            let ids = try await worker?.deletionCaptureIDs(rowIDs: Set(rowIDs), assetIDs: Set(assetIDs)) ?? Set(rowIDs)
            let allIDs = ids.sorted { $0.uuidString < $1.uuidString }
            return beginDeletion(allIDs) ? allIDs : nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func endDeletion(_ ids: [UUID]) {
        deletionGate.end(Set(ids))
        Diagnostics.emit("photo_delete_end", fields: "count=\(ids.count)")
    }

    /// Call while the deletion gate is still held, after the index transaction commits.
    func completeDeletion(_ ids: Set<UUID>) async {
        for id in ids { clearPreview(id) }
        queueState.remove(ids)
        updateCounts()
        await worker?.completeDeletion(ids)
    }

    func exportRecoveryOriginal(_ issue: CaptureRecoveryIssue) async -> URL? {
        do { return try await worker?.exportRecoveryOriginal(issue) }
        catch { lastError = error.localizedDescription; return nil }
    }

    func discardRecoveryFiles(_ issue: CaptureRecoveryIssue) async {
        guard let worker, beginDeletion([issue.captureID]) else { return }
        defer { endDeletion([issue.captureID]) }
        do {
            try await worker.discardRecoveryFiles(issue)
            await completeDeletion([issue.captureID])
        } catch {
            lastError = error.localizedDescription
            await worker.refreshRecoveryState()
        }
    }

    fileprivate func synchronizeRecovery(_ inventory: CaptureRecoveryInventory, revision: UInt64) {
        guard queueState.synchronize(pendingIDs: Set(inventory.jobs.map(\.id)),
            issueIDs: Set(inventory.issues.map(\.captureID)), revision: revision) else { return }
        recoveryIssues = inventory.issues
        updateCounts()
    }

    @discardableResult
    fileprivate func accepted(_ ids: Set<UUID>) -> Set<UUID> {
        let admitted = queueState.activate(Set(ids.filter { !deletionGate.contains($0) }))
        updateCounts()
        return admitted
    }

    fileprivate func finished(_ id: UUID, completion: CaptureCompletion?, error: String?, retained: Bool, revision: UInt64) {
        queueState.finish(id, retained: retained && completion == nil, revision: revision)
        if let completion {
            lastCompletion = completion
        }
        if completion != nil || !retained { clearPreview(id) }
        if let error { lastError = error }
        updateCounts()
    }

    private func updateCounts() {
        let previousPending = pendingCount
        let previousRetained = retainedCount
        if pendingCount != queueState.pendingCount { pendingCount = queueState.pendingCount }
        if retainedCount != queueState.retainedCount { retainedCount = queueState.retainedCount }
        if pendingCount != previousPending || retainedCount != previousRetained {
            Diagnostics.emit("capture_queue_state", fields: "active=\(pendingCount) retained=\(retainedCount) reserved=\(queueState.reservationCount) recovery_issues=\(recoveryIssues.count)")
        }
    }
}

/// A finite background assertion supplements the on-disk journal; recovery does not depend on it.
@MainActor
private final class CaptureBackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(expiration: (@Sendable () -> Void)? = nil) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save captured photo") { [weak self] in
            expiration?()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One worker serves all camera views/windows. Await points allow new captures to be journaled
/// while one heavy render runs off this actor; a single drain task bounds rendering concurrency.
private actor CaptureWorker {
    private let container: ModelContainer
    private let deletionGate: CaptureDeletionGate
    private let journal: CaptureJournal
    private let storageWork = BlockingImageWork(maximumConcurrentOperations: 1,
        label: "com.justshoot.capture-storage")
    private let storeDeferredProxy: @Sendable (Data, CaptureRecipe) async throws -> String
    private let finalizeDeferredPhoto: @Sendable (String, DeferredPhotoState) async throws -> Data
    private weak var owner: CapturePipeline?
    private var queue: [CaptureJob] = []
    private var preparationQueue: [CaptureJob] = []
    private var preparationTasks: [UUID: Task<Void, Never>] = [:]
    private var preparedInputs: [UUID: DeferredEditingInput] = [:]
    private static let maximumPreparations = 2
    private var scheduledIDs: Set<UUID> = []
    private var inFlightNativeIDs: Set<UUID> = []
    private var drainTask: Task<Void, Never>?
    private var suspended = false
    private var enqueuedAt: [UUID: TimeInterval] = [:]
    private var recoveryRevision: UInt64 = 0

    init(container: ModelContainer, deletionGate: CaptureDeletionGate, journal: CaptureJournal,
         storeDeferredProxy: @escaping @Sendable (Data, CaptureRecipe) async throws -> String,
         finalizeDeferredPhoto: @escaping @Sendable (String, DeferredPhotoState) async throws -> Data, owner: CapturePipeline) {
        self.container = container
        self.deletionGate = deletionGate
        self.journal = journal
        self.storeDeferredProxy = storeDeferredProxy
        self.finalizeDeferredPhoto = finalizeDeferredPhoto
        self.owner = owner
    }

    func hasRoom(for bytes: Int64, trace: DiagnosticTrace) async -> Bool {
        do {
            guard try trace.measure("capture_storage_budget", { try journal.hasJournalRoom(for: bytes) }) else { return false }
        }
        catch {
            Diagnostics.emit("capture_storage_check_error", fields: Diagnostics.errorFields(error))
            return false
        }
        let journal = journal
        let queuedAt = ProcessInfo.processInfo.systemUptime
        // Capacity APIs can synchronously wait for a system service. Give them a bounded
        // queue of their own, away from MainActor, the cooperative executor and image decodes.
        return await storageWork.run {
            let probe = trace.span("capture_storage_probe",
                "queue_wait_ms=\((ProcessInfo.processInfo.systemUptime - queuedAt) * 1_000) main_thread=\(Thread.isMainThread)")
            do {
                let available = try journal.hasVolumeRoom(for: bytes)
                probe.end(available ? "ok" : "insufficient_space")
                return available
            } catch {
                probe.end("error", Diagnostics.errorFields(error))
                return false
            }
        } ?? false
    }

    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT? = nil) async throws {
        let trace = DiagnosticTrace(id: recipe.id.uuidString)
        inFlightNativeIDs.insert(recipe.id)
        defer { inFlightNativeIDs.remove(recipe.id) }
        var job = try trace.measure("capture_journal_stage") {
            // Promote a complete staging directory if an earlier rename failed.
            if !FileManager.default.fileExists(atPath: journal.file("manifest.json", for: recipe.id).path),
               FileManager.default.fileExists(atPath: journal.root.appendingPathComponent("staging-\(recipe.id.uuidString)").path) {
                _ = try journal.recover(excludingInFlight: inFlightNativeIDs)
            }
            if FileManager.default.fileExists(atPath: journal.file("manifest.json", for: recipe.id).path) {
                return try journal.job(for: recipe.id)
            }
            return try journal.stage(recipe: recipe, imageData: result.imageData,
                movieURL: result.livePhotoMovieURL, lut: lut, rawLUT: rawLUT, reserved: true,
                awaitingCaptureCompletion: true,
                deferredPhoto: result.deferredPhoto)
        }
        // The shutter is already released after the durable checkpoint. Import proxies
        // promptly here, without making the next exposure wait for a Photos transaction.
        // Keep awaitingCaptureCompletion set across this await so resume cannot import
        // or process a second copy of this native capture.
        if var deferred = job.deferredPhoto, deferred.assetIdentifier == nil {
            deferred.assetIdentifier = try await storeDeferredProxy(result.imageData, recipe)
            job.deferredPhoto = deferred
            try journal.update(job)
        }
        job = try journal.completeCapture(id: recipe.id, photoDisplayTime: recipe.photoDisplayTime,
            movieURL: result.livePhotoMovieURL)
        await schedule([job])
    }

    func checkpointStill(_ still: CaptureStill, recipe: CaptureRecipe, lut: CubeLUT, rawLUT: RawFilmLUT? = nil) async throws {
        inFlightNativeIDs.insert(recipe.id)
        let job = try DiagnosticTrace(id: recipe.id.uuidString).measure("capture_still_checkpoint") {
            try journal.stage(recipe: recipe, imageData: still.imageData, movieURL: nil, lut: lut, rawLUT: rawLUT, reserved: true,
                awaitingCaptureCompletion: true, pendingMovieURL: still.pendingLivePhotoMovieURL,
                deferredPhoto: still.deferredPhoto)
        }
        await owner?.accepted([job.id])
    }

    func resume(allowProcessing: Bool = true) async {
        suspended = true
        if let drainTask, drainTask.isCancelled { await drainTask.value }
        for task in Array(preparationTasks.values) where task.isCancelled { await task.value }
        suspended = !allowProcessing
        do {
            let inventory = try DiagnosticTrace(id: "recovery").measure("capture_recovery") {
                try journal.recoverInventory(excludingInFlight: inFlightNativeIDs)
            }
            await publishRecovery(inventory)
            await schedule(inventory.jobs)
            startWork()
        } catch {
            Log.save.error("capture_recovery_failed error=\(error.localizedDescription, privacy: .public)")
            await owner?.recordFailure(error.localizedDescription)
        }
    }

    func refreshRecoveryState(reconcileStorage: Bool = false) async {
        do {
            if reconcileStorage { _ = try journal.diskUsage() }
            await publishRecovery(try journal.inventory())
        }
        catch { await owner?.recordFailure(error.localizedDescription) }
    }

    private func publishRecovery(_ inventory: CaptureRecoveryInventory) async {
        recoveryRevision += 1
        let revision = recoveryRevision
        await owner?.synchronizeRecovery(inventory, revision: revision)
    }

    private func publishFinished(_ id: UUID, completion: CaptureCompletion?, error: String?, retained: Bool = true) async {
        recoveryRevision += 1
        let revision = recoveryRevision
        await owner?.finished(id, completion: completion, error: error, retained: retained, revision: revision)
        if completion != nil || !retained { await refreshRecoveryState() }
    }

    func deletionCaptureIDs(rowIDs: Set<UUID>, assetIDs: Set<String>) throws -> Set<UUID> {
        CaptureDeletionSelection.captureIDs(rowIDs: rowIDs, assetIDs: assetIDs, jobs: try journal.jobs(),
            libraryCaptureIDs: PhotoLibrary.captureIdentifiers(from: Array(assetIDs)))
    }

    func completeDeletion(_ ids: Set<UUID>) async {
        queue.removeAll { ids.contains($0.id) }
        preparationQueue.removeAll { ids.contains($0.id) }
        for id in ids { preparationTasks.removeValue(forKey: id)?.cancel(); preparedInputs[id] = nil }
        scheduledIDs.subtract(ids)
        for id in ids { enqueuedAt[id] = nil }
        // Gallery deletion can use another journal instance; reconcile its filesystem writes.
        await refreshRecoveryState(reconcileStorage: true)
    }

    func exportRecoveryOriginal(_ issue: CaptureRecoveryIssue) throws -> URL {
        try journal.exportOriginal(for: issue)
    }

    func discardRecoveryFiles(_ issue: CaptureRecoveryIssue) throws {
        guard !inFlightNativeIDs.contains(issue.captureID) else { throw CaptureJournal.JournalError.recoveryChanged }
        try journal.discardRecoveryFiles(for: issue)
    }

    private func schedule(_ jobs: [CaptureJob]) async {
        let added = jobs.filter {
            $0.awaitingCaptureCompletion != true && !deletionGate.contains($0.id)
                && FileManager.default.fileExists(atPath: journal.file("manifest.json", for: $0.id).path)
                && scheduledIDs.insert($0.id).inserted
        }
        for job in added {
            enqueuedAt[job.id] = ProcessInfo.processInfo.systemUptime
            DiagnosticTrace(id: job.id.uuidString).event("capture_queued", "queue_depth=\(queue.count + added.count) rendered_checkpoint=\(job.rendered)")
        }
        // Publish admission before exposing jobs to the drain loop. Actor reentrancy must not
        // let processing start while the UI still considers that capture idle/deletable.
        let admitted = await owner?.accepted(Set(added.map(\.id))) ?? []
        // A deletion may commit while admission crosses actors. Do not resurrect its queued copy.
        let ready = added.filter {
            admitted.contains($0.id) && scheduledIDs.contains($0.id)
                && !deletionGate.contains($0.id)
                && FileManager.default.fileExists(atPath: journal.file("manifest.json", for: $0.id).path)
        }
        scheduledIDs.subtract(Set(added.map(\.id)).subtracting(ready.map(\.id)))
        for job in ready {
            if job.deferredPhoto != nil && job.assetIdentifier == nil { preparationQueue.append(job) }
            else { queue.append(job) }
        }
        queue.sort { $0.recipe.captureDate < $1.recipe.captureDate }
        preparationQueue.sort { $0.recipe.captureDate < $1.recipe.captureDate }
        startWork()
    }

    func pause() {
        Diagnostics.emit("capture_worker_paused", fields: "queued=\(queue.count) scheduled=\(scheduledIDs.count)")
        suspended = true
        drainTask?.cancel()
        for task in preparationTasks.values { task.cancel() }
    }

    /// PhotoKit waits have their own bounded lane; they never occupy the single render lane.
    private func startWork() {
        guard !suspended else { return }
        while preparationTasks.count < Self.maximumPreparations, !preparationQueue.isEmpty {
            let job = preparationQueue.removeFirst()
            preparationTasks[job.id] = Task(priority: .utility) { await prepareDeferred(job) }
        }
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task(priority: .utility) { await drain() }
    }

    private func prepareDeferred(_ initial: CaptureJob) async {
        let activity = await CaptureBackgroundActivity { [weak self] in Task { await self?.pause() } }
        let trace = DiagnosticTrace(id: initial.id.uuidString)
        let preparing = trace.span("capture_system_prepare", "waiting=\(preparationTasks.count)")
        do {
            var job = initial
            try checkPending(job.id)
            if var deferred = job.deferredPhoto, !deferred.finalized {
                if deferred.assetIdentifier == nil {
                    let proxy = try Data(contentsOf: journal.file("original.image", for: job.id))
                    deferred.assetIdentifier = try await storeDeferredProxy(proxy, job.recipe)
                    try checkPending(job.id)
                    job.deferredPhoto = deferred
                    try journal.update(job)
                }
                guard let sourceID = deferred.assetIdentifier else { throw PhotoLibraryError.saveFailed }
                let original = try await finalizeDeferredPhoto(sourceID, deferred)
                try checkPending(job.id)
                trace.event("native_photo_metadata", CameraPhotoDiagnostics.fields(imageData: original,
                    resolvedDimensions: CMVideoDimensions(width: Int32(clamping: deferred.width), height: Int32(clamping: deferred.height))))
                job = try journal.finalizeDeferredPhoto(original, for: job.id)
            }
            guard let sourceID = job.deferredPhoto?.assetIdentifier else { throw PhotoLibraryError.saveFailed }
            let input = try await PhotoLibrary.prepareDeferredAdjustment(id: sourceID)
            try checkPending(job.id)
            preparedInputs[job.id] = input
            queue.append(job)
            queue.sort { $0.recipe.captureDate < $1.recipe.captureDate }
            preparing.end("ready")
        } catch {
            preparing.end(error is CancellationError ? "cancelled" : "error", Diagnostics.errorFields(error))
            await recordFailure(initial, error: error)
            scheduledIDs.remove(initial.id)
            enqueuedAt[initial.id] = nil
        }
        preparationTasks[initial.id] = nil
        await activity.end()
        startWork()
    }

    private func recordFailure(_ job: CaptureJob, error: any Error) async {
        if !(error is CancellationError) {
            do { try journal.markNeedsAttention(job.id) }
            catch { Diagnostics.emit("capture_attention_marker_failed", id: job.id.uuidString, fields: Diagnostics.errorFields(error)) }
        }
        await publishFinished(job.id, completion: nil,
            error: error is CancellationError ? nil : String(localized: "Your photo is kept on this device. Saving will be retried when you return to the app."),
            retained: FileManager.default.fileExists(atPath: journal.directory(for: job.id).path))
        if !(error is CancellationError) { await refreshRecoveryState(reconcileStorage: true) }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let trace = DiagnosticTrace(id: job.id.uuidString)
            let queued = enqueuedAt.removeValue(forKey: job.id) ?? ProcessInfo.processInfo.systemUptime
            trace.event("capture_job_dequeued", "queue_wait_ms=\(Diagnostics.milliseconds(since: queued)) queued=\(queue.count) age_s=\(Int(max(0, Date().timeIntervalSince(job.recipe.captureDate))))")
            if Task.isCancelled {
                preparedInputs[job.id] = nil
                scheduledIDs.remove(job.id)
                await publishFinished(job.id, completion: nil, error: nil)
                continue
            }
            let activity = await CaptureBackgroundActivity { [weak self] in
                Task { await self?.pause() }
            }
            let processing = trace.span("capture_job")
            do {
                let result = try await process(job, preparedInput: preparedInputs.removeValue(forKey: job.id))
                processing.end()
                await publishFinished(job.id, completion: result, error: nil)
            } catch {
                processing.end(error is CancellationError ? "cancelled" : "error", Diagnostics.errorFields(error))
                Log.save.error("capture_deferred id=\(job.id) error=\(error.localizedDescription, privacy: .public)")
                await recordFailure(job, error: error)
            }
            scheduledIDs.remove(job.id)
            await activity.end()
        }
        drainTask = nil
    }

    private func process(_ initialJob: CaptureJob, preparedInput: DeferredEditingInput?) async throws -> CaptureCompletion {
        var job = initialJob
        let recipe = job.recipe
        let trace = DiagnosticTrace(id: job.id.uuidString)
        let timer = Log.perf("capture_job", logger: Log.capture)
        let saver = PhotoSaver(modelContainer: container)
        try checkPending(job.id)

        guard job.deferredPhoto?.finalized != false else { throw CaptureJournal.JournalError.invalidJob }

        let image: Data
        if !job.rendered {
            let lut = try journal.lut(for: job)
            var contentID: String?
            var stillSeed = recipe.grainSeed
            if job.hasSourceMovie {
                if job.recoveredIncompleteCapture == true,
                   try await LivePhotoProcessor.isReadableSource(at: journal.file("source.mov", for: job.id)) {
                    job.recoveredIncompleteCapture = nil
                    try journal.update(job)
                }
                let displayTime = recipe.photoDisplayTime.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
                let video = trace.span("live_video_process")
                do {
                    let result = try await LivePhotoProcessor.process(
                        sourceURL: journal.file("source.mov", for: job.id), lutCacheKey: recipe.filterName,
                        capturedLUT: lut, grain: recipe.profile.grain, optics: recipe.profile.optics,
                        chromatic: recipe.profile.effectiveChromatic,
                        chromaticSceneCCT: recipe.chromaticSceneCCT,
                        chromaticGainOverride: recipe.frozenChromaticGain,
                        grainBaseSeed: recipe.grainSeed, photoDisplayTime: displayTime,
                        outputURL: journal.file("rendered.mov", for: job.id), trace: trace)
                    video.end()
                    contentID = result.contentIdentifier
                    stillSeed = result.stillGrainSeed
                    job.hasRenderedMovie = true
                } catch {
                    video.end(error is CancellationError ? "cancelled" : "error", Diagnostics.errorFields(error))
                    // A failed movie must not hide the usable still. Keep the complete journal for
                    // retry, and expose a static fallback in the gallery without discarding the video.
                    if error is CancellationError { throw error }
                    if job.recoveredIncompleteCapture == true {
                        // The process ended while AVFoundation was writing this movie. A partial
                        // movie must not trap a durable still in a permanently failing retry loop.
                        job.hasRenderedMovie = false
                        trace.event("capture_recovered_as_still", "reason=incomplete_movie")
                    } else {
                        let fallback = try await renderStill(job, lut: lut, contentID: nil, seed: recipe.grainSeed)
                        _ = try await saver.save(id: job.id, captureDate: recipe.captureDate,
                            assetLocalIdentifier: nil, imageData: fallback, filmPresetName: recipe.filterName,
                            filmDisplayLabel: recipe.displayLabel, latitude: recipe.location?.latitude,
                            longitude: recipe.location?.longitude, altitude: recipe.location?.altitude,
                            locationTimestamp: recipe.location?.timestamp)
                        throw error
                    }
                }
            }
            try checkPending(job.id)
            image = try await renderStill(job, lut: lut, contentID: contentID, seed: stillSeed)
            try checkPending(job.id)
            try trace.measure("capture_render_checkpoint") { try journal.writeRenderedImage(image, for: job.id) }
            job.rendered = true
            try journal.update(job)
        } else {
            image = try trace.measure("capture_rendered_read") {
                try Data(contentsOf: journal.file("rendered.image", for: job.id))
            }
        }

        if job.assetIdentifier == nil, let deferredID = job.deferredPhoto?.assetIdentifier {
            // Update the same asset: no unfiltered duplicate and no deletion prompt.
            try await PhotoLibrary.saveDeferredAdjustment(imageData: image, id: deferredID, recipe: recipe, preparedInput: preparedInput)
            job.assetIdentifier = deferredID
            try journal.update(job)
        }
        if job.assetIdentifier == nil {
            job.assetIdentifier = trace.measure("photos_retry_lookup") { PhotoLibrary.findCapture(id: job.id, creationDate: recipe.captureDate) }
        }
        if job.assetIdentifier == nil {
            let saving = trace.span("photos_save")
            do {
                try checkPending(job.id)
                if job.hasRenderedMovie {
                    job.assetIdentifier = try await PhotoLibrary.saveLivePhoto(
                        imageData: image, videoURL: journal.file("rendered.mov", for: job.id),
                        creationDate: recipe.captureDate, latitude: recipe.location?.latitude,
                        longitude: recipe.location?.longitude, altitude: recipe.location?.altitude,
                        locationTimestamp: recipe.location?.timestamp, captureID: job.id,
                        moveVideo: false)
                } else {
                    job.assetIdentifier = try await PhotoLibrary.save(
                        imageData: image, creationDate: recipe.captureDate,
                        latitude: recipe.location?.latitude, longitude: recipe.location?.longitude,
                        altitude: recipe.location?.altitude, locationTimestamp: recipe.location?.timestamp,
                        captureID: job.id)
                }
                saving.end()
            } catch {
                saving.end("error", Diagnostics.errorFields(error))
                // The journal retains BOTH original and rendered Live Photo resources for a later retry.
                _ = try await saver.save(id: job.id, captureDate: recipe.captureDate,
                    assetLocalIdentifier: nil, imageData: image, filmPresetName: recipe.filterName,
                    filmDisplayLabel: recipe.displayLabel, isLivePhoto: false,
                    latitude: recipe.location?.latitude, longitude: recipe.location?.longitude,
                    altitude: recipe.location?.altitude, locationTimestamp: recipe.location?.timestamp)
                throw error
            }
        }
        try journal.update(job)
        let indexing = trace.span("capture_index_save")
        let photoID = try await saver.save(id: job.id, captureDate: recipe.captureDate,
            assetLocalIdentifier: job.assetIdentifier, imageData: nil, filmPresetName: recipe.filterName,
            filmDisplayLabel: recipe.displayLabel, isLivePhoto: job.hasRenderedMovie,
            latitude: recipe.location?.latitude, longitude: recipe.location?.longitude,
            altitude: recipe.location?.altitude, locationTimestamp: recipe.location?.timestamp)
        indexing.end()
        try trace.measure("capture_journal_cleanup") { try journal.finish(job.id) }
        let thumbnailLoad = trace.span("capture_thumbnail")
        let thumbnail = await ImageLoader.shared.loadThumbnail(imageData: image, photoId: photoID, maxPixel: 88)
        thumbnailLoad.end(thumbnail == nil ? "missing" : "ok")
        if FilmProcessor.stageDiagnosticsEnabled, let assetID = job.assetIdentifier,
           let libraryData = await AssetImageLoader.shared.imageData(id: assetID, timeout: 4) {
            await CaptureComparisonDiagnostics.recordLibraryImage(libraryData, id: job.id)
        }
        timer.end("id=\(job.id) live=\(job.hasRenderedMovie)")
        return CaptureCompletion(id: photoID, captureID: job.id, filterName: recipe.filterName, thumbnail: thumbnail, captureDate: recipe.captureDate)
    }

    private func renderStill(_ job: CaptureJob, lut: CubeLUT, contentID: String?, seed: UInt32) async throws -> Data {
        try checkPending(job.id)
        guard job.deferredPhoto?.finalized != false else { throw CaptureJournal.JournalError.invalidJob }
        let recipe = job.recipe
        let trace = DiagnosticTrace(id: job.id.uuidString)
        let raw = try trace.measure("still_source_read") { try Data(contentsOf: journal.file("original.image", for: job.id)) }
        let rawLUT = try journal.rawLUT(for: job)
        let rendering = trace.span("still_render")
        let cancellation = CaptureRenderCancellation()
        let image = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                trace.measure("still_render_worker") { autoreleasepool {
                    CapturePhotoRenderer.render(source: raw, recipe: recipe, lut: lut, rawLUT: rawLUT,
                        contentIdentifier: contentID, grainSeed: seed, cancellation: cancellation)
                } }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
        rendering.end(cancellation.isCancelled ? "cancelled" : image == nil ? "failed" : "ok", "output_bytes=\(image?.count ?? 0)")
        try cancellation.checkCancellation()
        try checkPending(job.id)
        guard let image else { throw CaptureJournal.JournalError.invalidJob }
        return image
    }

    private func checkPending(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !deletionGate.contains(id),
              FileManager.default.fileExists(atPath: journal.file("manifest.json", for: id).path),
              !FileManager.default.fileExists(atPath: journal.file("discarded", for: id).path) else {
            throw CancellationError()
        }
    }
}
