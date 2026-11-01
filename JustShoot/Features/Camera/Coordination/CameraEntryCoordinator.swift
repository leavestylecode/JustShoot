import Foundation

/// Session-scoped preparation, independent of SwiftUI redraws and native session mutation.
@MainActor
final class CameraEntryCoordinator {
    struct Readiness {
        var session = false
        var preview = false
        var capture = false
        var countsTime = false
    }

    private(set) var entryPreparation = CameraEntryPreparation()
    private var entryPreparationTask: Task<Void, Never>?
    private var entryResourcesTask: Task<Void, Never>?
    private var entryTimer = CameraEntryPreparation.ActiveTimer()
    private var entrySceneIsActive = true
    private var entryPipelineIsReady = false
    private var previewRendererIsUnavailable = false
    private var entryFailedLUTKey: String?
    private let diagnostics: DiagnosticTrace
    private let isCurrentGeneration: (UInt64) -> Bool
    private let readinessSnapshot: () -> Readiness
    private let stateChanged: (CameraEntryPreparation) -> Void
    private let prepareResources: @Sendable () async throws -> Void

    init(diagnostics: DiagnosticTrace, isCurrentGeneration: @escaping (UInt64) -> Bool,
         readinessSnapshot: @escaping () -> Readiness,
         stateChanged: @escaping (CameraEntryPreparation) -> Void,
         prepareResources: @escaping @Sendable () async throws -> Void = CameraEntryResources.prepare) {
        self.diagnostics = diagnostics
        self.isCurrentGeneration = isCurrentGeneration
        self.readinessSnapshot = readinessSnapshot
        self.stateChanged = stateChanged
        self.prepareResources = prepareResources
    }

    // MARK: - Entry preparation

    func updateEntryLUT(expectedKey: String, preparedKey: String?) {
        if preparedKey == expectedKey || entryFailedLUTKey != expectedKey { entryFailedLUTKey = nil }
        var next = entryPreparation
        next.updateLUT(expectedKey: expectedKey, preparedKey: preparedKey)
        publishEntry(next)
        refreshEntryReadiness()
    }

    func updateEntryPipelineReady(_ ready: Bool) {
        entryPipelineIsReady = ready
        refreshEntryReadiness()
    }

    private func entryResourcesPrepared(generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }
        var next = entryPreparation
        next.preparedResources(generation: generation)
        publishEntry(next)
        refreshEntryReadiness()
    }

    func setEntrySceneActive(_ active: Bool) {
        entrySceneIsActive = active
        updateEntryClock()
    }

    func needsPreviewRender(lutKey: String, capturedAt: TimeInterval) -> Bool {
        guard let generation = entryPreparation.generation,
              isCurrentGeneration(generation) else { return false }
        return entryPreparation.needsRender(generation: generation, lutKey: lutKey, capturedAt: capturedAt)
    }

    func previewDidRender(generation: UInt64, lutKey: String, capturedAt: TimeInterval) {
        guard isCurrentGeneration(generation),
              entryPreparation.needsRender(generation: generation, lutKey: lutKey, capturedAt: capturedAt) else { return }
        previewRendererIsUnavailable = false
        var next = entryPreparation
        next.rendered(generation: generation, lutKey: lutKey, capturedAt: capturedAt)
        publishEntry(next)
        refreshEntryReadiness()
    }

    func entryDeviceConfigurationFinished(generation: UInt64, completedAt: TimeInterval, status: String) {
        guard isCurrentGeneration(generation) else { return }
        diagnostics.event("camera_entry_device_settled", "generation=\(generation) status=\(status)")
        var next = entryPreparation
        next.preparedDevice(generation: generation, completedAt: completedAt)
        publishEntry(next)
        refreshEntryReadiness()
    }

    /// Synchronous renderer setup failures can precede the view's onAppear/session request.
    func previewRendererUnavailable() {
        previewRendererIsUnavailable = true
        failEntry(.previewUnavailable)
    }

    func previewDidFail(generation: UInt64, lutKey: String) {
        guard isCurrentGeneration(generation),
              entryPreparation.expectedLUTKey == lutKey else { return }
        previewRendererIsUnavailable = true
        failEntry(.previewUnavailable)
    }

    @discardableResult
    func entryLUTPreparationFailed(key: String) -> Bool {
        guard entryPreparation.expectedLUTKey == key else { return false }
        entryFailedLUTKey = key
        failEntry(.filmUnavailable)
        return !entryPreparation.isRevealed
    }

    func resetFailures() {
        previewRendererIsUnavailable = false
        entryFailedLUTKey = nil
    }

    private var countsEntryTime: Bool { entrySceneIsActive && readinessSnapshot().countsTime }

    func updateEntryClock() {
        guard entryPreparation.isPreparing else { return }
        entryTimer.update(at: ProcessInfo.processInfo.systemUptime, counting: countsEntryTime)
    }

    func beginEntryPreparation(generation: UInt64) {
        entryPreparationTask?.cancel()
        entryResourcesTask?.cancel()
        var next = entryPreparation
        next.begin(generation: generation)
        publishEntry(next)
        entryTimer.reset(at: ProcessInfo.processInfo.systemUptime, counting: countsEntryTime)
        if previewRendererIsUnavailable { failEntry(.previewUnavailable); return }
        if entryFailedLUTKey == entryPreparation.expectedLUTKey, entryFailedLUTKey != nil {
            failEntry(.filmUnavailable)
            return
        }
        // Session ownership keeps SwiftUI navigation/toolbar rebuilds from restarting work.
        let preparation = diagnostics.span("camera_entry_resources", "generation=\(generation)")
        let prepareResources = prepareResources
        entryResourcesTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await prepareResources()
                try Task.checkCancellation()
                guard let self, self.entryPreparation.generation == generation else {
                    preparation.end("superseded")
                    return
                }
                self.entryResourcesPrepared(generation: generation)
                preparation.end()
            } catch is CancellationError {
                preparation.end("cancelled")
            } catch {
                preparation.end("error", Diagnostics.errorFields(error))
                guard !Task.isCancelled, let self, self.entryPreparation.generation == generation else { return }
                self.previewRendererUnavailable()
            }
        }
        entryPreparationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.entryPreparation.generation == generation,
                      self.entryPreparation.isPreparing,
                      self.isCurrentGeneration(generation) else { return }
                self.refreshEntryReadiness()
                guard self.entryPreparation.isPreparing else { return }
                self.updateEntryClock()
                if self.entryTimer.elapsed >= 12 {
                    self.failEntry(.timedOut)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    func refreshEntryReadiness() {
        guard entryPreparation.isPreparing, let generation = entryPreparation.generation,
              isCurrentGeneration(generation) else { return }
        var next = entryPreparation
        let readiness = readinessSnapshot()
        next.updateReadiness(generation: generation, session: readiness.session,
            preview: readiness.preview, capture: readiness.capture, pipeline: entryPipelineIsReady)
        publishEntry(next)
    }

    func failEntry(_ failure: CameraEntryPreparation.Failure) {
        guard let generation = entryPreparation.generation else { return }
        var next = entryPreparation
        next.fail(failure, generation: generation)
        publishEntry(next)
    }

    func cancelEntryPreparation() {
        entryPreparationTask?.cancel()
        entryPreparationTask = nil
        entryResourcesTask?.cancel()
        entryResourcesTask = nil
        var next = entryPreparation
        next.cancel()
        publishEntry(next)
    }

    func publishEntry(_ next: CameraEntryPreparation) {
        guard next != entryPreparation else { return }
        entryPreparation = next
        let phase: String
        switch next.phase {
        case .inactive: phase = "inactive"
        case .preparing: phase = "preparing"
        case .revealed: phase = "revealed"
        case .failed: phase = "failed"
        }
        diagnostics.event("camera_entry_state", "phase=\(phase) generation=\(next.generation.map(String.init) ?? "none") reason=\(next.failure?.rawValue ?? "none") waiting=\(next.pendingRequirements.isEmpty ? "none" : next.pendingRequirements)")
        stateChanged(next)
    }

}
