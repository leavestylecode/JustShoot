/// Native camera configuration only reports readiness. Resource preparation is shared
/// by session-scoped entry coordinators and uses the process-wide rendering caches.
enum CameraEntryResources {
    static func prepare() async throws {
        async let preview: Void = PreviewMetalResources.warmUpForRenderer()
        async let processing: Void = FilmProcessor.shared.warmUpForCapture()
        _ = try await (preview, processing)
    }
}
