/// Avoid redundant native control writes while entry requirements are published.
/// Invalidation closes callbacks immediately; native teardown belongs to the session queue.
struct CameraSystemControlsState {
    private(set) var isActive = true
    private(set) var isEnabled: Bool?

    mutating func updateEnabled(_ enabled: Bool) -> Bool {
        guard isActive, isEnabled != enabled else { return false }
        isEnabled = enabled
        return true
    }

    mutating func invalidate() { isActive = false }
}
