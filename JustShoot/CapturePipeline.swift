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
    let filterName: String
    let thumbnail: UIImage?
}

@MainActor
final class CapturePipeline: ObservableObject {
    static let shared = CapturePipeline()
    @Published private(set) var pendingCount = 0
    @Published private(set) var retainedCount = 0
    @Published private(set) var lastCompletion: CaptureCompletion?
    @Published var lastError: String?

    private var worker: CaptureWorker?
    private let deletionGate = CaptureDeletionGate()
    @Published private var isReady = false
    private var reservedBytes: [UUID: Int64] = [:]
    private var activeIDs: Set<UUID> = []
    private(set) var pendingJobIDs: Set<UUID> = []

    var canCapture: Bool {
        isReady && worker != nil && activeIDs.union(pendingJobIDs).count < CaptureJournal.maximumJobs
    }

    func configure(container: ModelContainer) async {
        guard worker == nil else { return }
        let worker = CaptureWorker(container: container, deletionGate: deletionGate)
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
        activeIDs.insert(id)
        reservedBytes[id] = 128 * 1_024 * 1_024 + Int64(lutBytes)
        updateCounts()
        let hasSpace = await worker.hasRoom(for: reservedBytes.values.reduce(0, +))
        spaceCheck.end(hasSpace ? "ok" : "insufficient_space")
        guard hasSpace else {
            cancelReservation(id)
            lastError = String(localized: "Please wait for your photos to finish saving, or free up storage.")
            return nil
        }
        trace.event("capture_reserved", "pending=\(pendingCount) reserved_mb=\(reservedBytes.values.reduce(0, +) / 1_048_576)")
        return id
    }

    func cancelReservation(_ id: UUID) {
        reservedBytes[id] = nil
        activeIDs.remove(id)
        updateCounts()
    }

    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT) {
        guard let worker else { cancelReservation(recipe.id); return }
        Task {
            let activity = CaptureBackgroundActivity()
            do {
                try await worker.enqueue(result, recipe: recipe, lut: lut)
            } catch {
                cancelReservation(recipe.id)
                lastError = String(format: String(localized: "Save failed: %@"), error.localizedDescription)
            }
            activity.end()
        }
    }

    func retryPending() async {
        guard UIApplication.shared.applicationState != .background else { return }
        await worker?.resume()
    }
    func enterBackground() async { await worker?.pause() }

    func beginDeletion(_ ids: [UUID]) -> Bool {
        guard deletionGate.begin(Set(ids), active: activeIDs) else {
            lastError = String(localized: "Please wait for these photos to finish saving before deleting them.")
            return false
        }
        Diagnostics.emit("photo_delete_begin", fields: "count=\(ids.count)")
        return true
    }

    func endDeletion(_ ids: [UUID]) {
        deletionGate.end(Set(ids))
        Diagnostics.emit("photo_delete_end", fields: "count=\(ids.count)")
    }

    fileprivate func synchronizePending(_ ids: Set<UUID>) {
        activeIDs.subtract(pendingJobIDs.subtracting(ids))
        pendingJobIDs = ids
        updateCounts()
    }

    fileprivate func accepted(_ ids: Set<UUID>) {
        for id in ids { reservedBytes[id] = nil }
        pendingJobIDs.formUnion(ids)
        activeIDs.formUnion(ids)
        updateCounts()
    }

    fileprivate func finished(_ id: UUID, completion: CaptureCompletion?, error: String?, retained: Bool = true) {
        activeIDs.remove(id)
        if !retained { pendingJobIDs.remove(id) }
        if let completion {
            pendingJobIDs.remove(id)
            lastCompletion = completion
        }
        if let error { lastError = error }
        updateCounts()
    }

    private func updateCounts() {
        let previousPending = pendingCount
        let previousRetained = retainedCount
        pendingCount = activeIDs.count
        retainedCount = pendingJobIDs.subtracting(activeIDs).count
        if pendingCount != previousPending || retainedCount != previousRetained {
            Diagnostics.emit("capture_queue_state", fields: "active=\(pendingCount) retained=\(retainedCount) reserved=\(reservedBytes.count)")
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
    private let journal = CaptureJournal.application
    private var queue: [CaptureJob] = []
    private var scheduledIDs: Set<UUID> = []
    private var drainTask: Task<Void, Never>?
    private var suspended = false
    private var enqueuedAt: [UUID: TimeInterval] = [:]

    init(container: ModelContainer, deletionGate: CaptureDeletionGate) {
        self.container = container
        self.deletionGate = deletionGate
    }

    func hasRoom(for bytes: Int64) -> Bool {
        do { return try journal.hasRoom(for: bytes) }
        catch {
            Diagnostics.emit("capture_storage_check_error", fields: Diagnostics.errorFields(error))
            return false
        }
    }

    func enqueue(_ result: CaptureResult, recipe: CaptureRecipe, lut: CubeLUT) async throws {
        let trace = DiagnosticTrace(id: recipe.id.uuidString)
        let job = try trace.measure("capture_journal_stage") {
            try journal.stage(recipe: recipe, imageData: result.imageData,
                              movieURL: result.livePhotoMovieURL, lut: lut, reserved: true)
        }
        await schedule([job])
    }

    func resume(allowProcessing: Bool = true) async {
        suspended = !allowProcessing
        if let drainTask, drainTask.isCancelled { await drainTask.value }
        do {
            let jobs = try DiagnosticTrace(id: "recovery").measure("capture_recovery") { try journal.recover() }
            await CapturePipeline.shared.synchronizePending(Set(jobs.map(\.id)))
            await schedule(jobs)
        } catch {
            Log.save.error("capture_recovery_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func schedule(_ jobs: [CaptureJob]) async {
        let added = jobs.filter { scheduledIDs.insert($0.id).inserted }
        for job in added {
            enqueuedAt[job.id] = ProcessInfo.processInfo.systemUptime
            DiagnosticTrace(id: job.id.uuidString).event("capture_queued", "queue_depth=\(queue.count + added.count) rendered_checkpoint=\(job.rendered)")
        }
        // Publish admission before exposing jobs to the drain loop. Actor reentrancy must not
        // let processing start while the UI still considers that capture idle/deletable.
        await CapturePipeline.shared.accepted(Set(added.map(\.id)))
        queue.append(contentsOf: added)
        queue.sort { $0.recipe.captureDate < $1.recipe.captureDate }
        guard !suspended, drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task(priority: .utility) { await drain() }
    }

    func pause() {
        Diagnostics.emit("capture_worker_paused", fields: "queued=\(queue.count) scheduled=\(scheduledIDs.count)")
        suspended = true; drainTask?.cancel()
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let trace = DiagnosticTrace(id: job.id.uuidString)
            let queued = enqueuedAt.removeValue(forKey: job.id) ?? ProcessInfo.processInfo.systemUptime
            trace.event("capture_job_dequeued", "queue_wait_ms=\(Diagnostics.milliseconds(since: queued)) queued=\(queue.count) age_s=\(Int(max(0, Date().timeIntervalSince(job.recipe.captureDate))))")
            if Task.isCancelled {
                scheduledIDs.remove(job.id)
                await CapturePipeline.shared.finished(job.id, completion: nil, error: nil)
                continue
            }
            let activity = await CaptureBackgroundActivity { [weak self] in
                Task { await self?.pause() }
            }
            let processing = trace.span("capture_job")
            do {
                let result = try await process(job)
                processing.end()
                await CapturePipeline.shared.finished(job.id, completion: result, error: nil)
            } catch {
                processing.end(error is CancellationError ? "cancelled" : "error", Diagnostics.errorFields(error))
                Log.save.error("capture_deferred id=\(job.id) error=\(error.localizedDescription, privacy: .public)")
                await CapturePipeline.shared.finished(job.id, completion: nil,
                    error: error is CancellationError ? nil : String(localized: "Your photo is kept on this device. Saving will be retried when you return to the app."),
                    retained: FileManager.default.fileExists(atPath: journal.directory(for: job.id).path))
            }
            scheduledIDs.remove(job.id)
            await activity.end()
        }
        drainTask = nil
    }

    private func process(_ initialJob: CaptureJob) async throws -> CaptureCompletion {
        var job = initialJob
        let recipe = job.recipe
        let trace = DiagnosticTrace(id: job.id.uuidString)
        let timer = Log.perf("capture_job", logger: Log.capture)
        let saver = PhotoSaver(modelContainer: container)
        try checkPending(job.id)

        if !job.rendered {
            let lut = try journal.lut(for: job)
            var contentID: String?
            var stillSeed = recipe.grainSeed
            if job.hasSourceMovie {
                let displayTime = recipe.photoDisplayTime.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
                let video = trace.span("live_video_process")
                do {
                    let result = try await LivePhotoProcessor.process(
                        sourceURL: journal.file("source.mov", for: job.id), lutCacheKey: recipe.filterName,
                        capturedLUT: lut, grain: recipe.profile.grain, optics: recipe.profile.optics,
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
                    if !(error is CancellationError) {
                        let fallback = try await renderStill(job, lut: lut, contentID: nil, seed: recipe.grainSeed)
                        _ = try await saver.save(id: job.id, captureDate: recipe.captureDate,
                            assetLocalIdentifier: nil, imageData: fallback, filmPresetName: recipe.filterName,
                            filmDisplayLabel: recipe.displayLabel, latitude: recipe.location?.latitude,
                            longitude: recipe.location?.longitude, altitude: recipe.location?.altitude,
                            locationTimestamp: recipe.location?.timestamp)
                    }
                    throw error
                }
            }
            try checkPending(job.id)
            let image = try await renderStill(job, lut: lut, contentID: contentID, seed: stillSeed)
            try checkPending(job.id)
            try trace.measure("capture_render_checkpoint") { try journal.writeRenderedImage(image, for: job.id) }
            job.rendered = true
            try journal.update(job)
        }

        let image = try Data(contentsOf: journal.file("rendered.image", for: job.id))
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
        timer.end("id=\(job.id) live=\(job.hasRenderedMovie)")
        return CaptureCompletion(id: photoID, filterName: recipe.filterName, thumbnail: thumbnail)
    }

    private func renderStill(_ job: CaptureJob, lut: CubeLUT, contentID: String?, seed: UInt32) async throws -> Data {
        try checkPending(job.id)
        let recipe = job.recipe
        let trace = DiagnosticTrace(id: job.id.uuidString)
        let raw = try trace.measure("still_source_read") { try Data(contentsOf: journal.file("original.image", for: job.id)) }
        let rendering = trace.span("still_render")
        let image = await Task.detached(priority: .utility) {
            trace.measure("still_render_worker") { autoreleasepool {
                FilmProcessor.shared.applyLUTPreservingMetadata(
                    imageData: raw, lutCacheKey: recipe.filterName, capturedLUT: lut,
                    grain: recipe.profile.grain, grainSeed: seed, optics: recipe.profile.optics,
                    outputQuality: recipe.outputQuality, location: recipe.location?.location,
                    captureDate: recipe.captureDate, focalLengthIn35mm: recipe.focalLength,
                    contentIdentifier: contentID)
            } }
        }.value
        rendering.end(image == nil ? "failed" : "ok", "output_bytes=\(image?.count ?? 0)")
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
