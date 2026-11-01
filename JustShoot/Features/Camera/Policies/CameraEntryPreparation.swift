import Foundation

/// An entry is revealed once per running session generation. Later filter/focal changes
/// update their normal capture gates without bringing the full-screen entry cover back.
struct CameraEntryPreparation: Equatable, Sendable {
    enum Failure: String, Equatable, Sendable {
        case permissionDenied = "permission_denied"
        case cameraUnavailable = "camera_unavailable"
        case filmUnavailable = "film_unavailable"
        case previewUnavailable = "preview_unavailable"
        case timedOut = "timed_out"
    }

    enum Phase: Equatable, Sendable {
        case inactive
        case preparing
        case revealed
        case failed(Failure)
    }

    private enum Requirement: String, CaseIterable, Hashable, Sendable {
        case session, preview, capture, pipeline, resources, device
        case photoTemplate = "photo_template"
        case audio, lut, gpu
    }

    private(set) var phase: Phase = .inactive
    private(set) var generation: UInt64?
    private(set) var expectedLUTKey: String?
    private(set) var deviceWarmupCompletedAt: TimeInterval?
    private var preparedLUTKey: String?
    private var renderedLUTKey: String?
    private var satisfied: Set<Requirement> = []

    var isPreparing: Bool { phase == .preparing }
    var resourcesReady: Bool { satisfied.contains(.resources) }
    var isRevealed: Bool { phase == .revealed }
    /// Preparing a cube is insufficient: a frame using it must have reached the renderer.
    var isCurrentLookRendered: Bool {
        isRevealed && expectedLUTKey != nil && expectedLUTKey == preparedLUTKey && expectedLUTKey == renderedLUTKey
    }
    var coversContent: Bool { !isRevealed }
    var failure: Failure? {
        guard case .failed(let failure) = phase else { return nil }
        return failure
    }
    var pendingRequirements: String {
        Requirement.allCases.filter { !satisfied.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    mutating func begin(generation: UInt64) {
        self.generation = generation
        phase = .preparing
        renderedLUTKey = nil
        deviceWarmupCompletedAt = nil
        satisfied = []
        updateLUTRequirements()
    }

    mutating func updateLUT(expectedKey: String, preparedKey: String?) {
        // Keep the last displayed key when a pending selection is cancelled. Returning
        // to that look must not wait for a one-shot ticket which already completed.
        expectedLUTKey = expectedKey
        preparedLUTKey = preparedKey
        guard isPreparing else { return }
        updateLUTRequirements()
        revealIfReady()
    }

    func needsRender(generation: UInt64, lutKey: String, capturedAt: TimeInterval) -> Bool {
        guard (isPreparing || isRevealed), renderedLUTKey != lutKey,
              self.generation == generation, expectedLUTKey == lutKey,
              let deviceWarmupCompletedAt, capturedAt.isFinite else { return false }
        return capturedAt >= deviceWarmupCompletedAt
    }

    mutating func rendered(generation: UInt64, lutKey: String, capturedAt: TimeInterval) {
        guard needsRender(generation: generation, lutKey: lutKey, capturedAt: capturedAt) else { return }
        // GPU completion may arrive before SwiftUI publishes the prepared-key update.
        renderedLUTKey = lutKey
        guard isPreparing else { return }
        updateLUTRequirements()
        revealIfReady()
    }

    mutating func preparedDevice(generation: UInt64, completedAt: TimeInterval) {
        guard isPreparing, self.generation == generation, completedAt.isFinite else { return }
        deviceWarmupCompletedAt = completedAt
        renderedLUTKey = nil
        satisfied.remove(.gpu)
        satisfied.insert(.device)
        revealIfReady()
    }

    mutating func preparedResources(generation: UInt64) {
        guard isPreparing, self.generation == generation else { return }
        satisfied.insert(.resources)
        revealIfReady()
    }

    mutating func preparedPhotoTemplate(generation: UInt64) {
        guard isPreparing, self.generation == generation else { return }
        satisfied.insert(.photoTemplate)
        revealIfReady()
    }

    mutating func preparedAudio(generation: UInt64) {
        guard isPreparing, self.generation == generation else { return }
        satisfied.insert(.audio)
        revealIfReady()
    }

    mutating func updateReadiness(generation: UInt64, session: Bool, preview: Bool,
                                 capture: Bool, pipeline: Bool) {
        guard isPreparing, self.generation == generation else { return }
        for (requirement, ready) in [(Requirement.session, session), (.preview, preview),
                                     (.capture, capture), (.pipeline, pipeline)] {
            if ready { satisfied.insert(requirement) }
            else { satisfied.remove(requirement) }
        }
        revealIfReady()
    }

    mutating func fail(_ failure: Failure, generation: UInt64) {
        guard (isPreparing || (isRevealed && failure == .previewUnavailable)), self.generation == generation else { return }
        phase = .failed(failure)
    }

    mutating func cancel() {
        generation = nil
        phase = .inactive
        renderedLUTKey = nil
        deviceWarmupCompletedAt = nil
        satisfied = []
    }

    private mutating func updateLUTRequirements() {
        guard let key = expectedLUTKey else { return }
        if preparedLUTKey == key { satisfied.insert(.lut) }
        else { satisfied.remove(.lut) }
        if renderedLUTKey == key { satisfied.insert(.gpu) }
        else { satisfied.remove(.gpu) }
    }

    private mutating func revealIfReady() {
        if satisfied.count == Requirement.allCases.count { phase = .revealed }
    }

    /// The owner marks active/inactive and permission transitions synchronously. Only active
    /// preparation time counts; a system permission sheet can remain open indefinitely.
    struct ActiveTimer: Sendable {
        private(set) var elapsed: TimeInterval = 0
        private var lastTime: TimeInterval?
        private var wasCounting = false

        mutating func reset(at now: TimeInterval, counting: Bool) {
            elapsed = 0
            lastTime = now
            wasCounting = counting
        }

        mutating func update(at now: TimeInterval, counting: Bool) {
            if let lastTime, wasCounting { elapsed += max(0, now - lastTime) }
            lastTime = now
            wasCounting = counting
        }
    }
}
