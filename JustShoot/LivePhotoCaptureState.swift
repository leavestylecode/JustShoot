/// Buffer availability and readiness are independent of the user's saved Live preference.
struct LivePhotoCaptureState: Equatable, Sendable {
    let supported: Bool
    let enabled: Bool

    var canCapture: Bool { supported && enabled }
}
