import Foundation

/// Owns the exposure slot from storage reservation until the native still is checkpointed.
/// The same token is checked on the main actor and hardware queue, so backgrounding cannot
/// turn a pending shutter press into a capture in a later session.
struct CameraCaptureAdmission: Sendable {
    struct Token: Equatable, Sendable {
        let id: UUID
        let sessionGeneration: UInt64
        let focalSequence: UInt64
        let focalLength: Int
        let exposureBias: Float
        let flashEnabled: Bool
        let rotationAngle: Double?
        let deadline: CameraCaptureDeadline
    }

    private enum Phase: Equatable, Sendable { case reserved, preparing, issued }
    private(set) var active: Token?
    private var phase: Phase = .reserved

    var isBusy: Bool { active != nil }

    mutating func begin(sessionGeneration: UInt64, focalSequence: UInt64, focalLength: Int,
                        exposureBias: Float, flashEnabled: Bool, rotationAngle: Double?,
                        deadline: CameraCaptureDeadline = CameraCaptureDeadline()) -> Token? {
        guard active == nil else { return nil }
        let token = Token(id: UUID(), sessionGeneration: sessionGeneration, focalSequence: focalSequence,
            focalLength: focalLength, exposureBias: exposureBias, flashEnabled: flashEnabled,
            rotationAngle: rotationAngle, deadline: deadline)
        active = token
        phase = .reserved
        return token
    }

    func permits(_ token: Token, generation: UInt64) -> Bool {
        active == token && token.sessionGeneration == generation
    }

    mutating func beginPreparation(_ token: Token, generation: UInt64) -> Bool {
        guard permits(token, generation: generation), phase == .reserved else { return false }
        phase = .preparing
        return true
    }

    mutating func markIssued(_ token: Token, generation: UInt64,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard permits(token, generation: generation), phase == .preparing,
              !token.deadline.hasExpired(at: now) else { return false }
        phase = .issued
        return true
    }

    /// Native captures retain their slot until still delivery, even if their session pauses.
    mutating func cancelUnissued() -> Token? {
        guard phase != .issued, let token = active else { return nil }
        active = nil
        phase = .reserved
        return token
    }

    @discardableResult
    mutating func cancel(_ token: Token) -> Bool {
        guard phase != .issued else { return false }
        return release(token)
    }

    @discardableResult
    mutating func release(_ token: Token) -> Bool {
        guard active == token else { return false }
        active = nil
        phase = .reserved
        return true
    }
}
