import CoreImage

/// All still/Live Photo effects share one library read and one immutable kernel set.
struct FilmImageKernels: Sendable {
    enum Name: String, CaseIterable, Sendable {
        case grain = "justShootFilmGrain"
        case headroom = "justShootHeadroom"
        case highlight = "justShootHighlightEnergy"
        case composite = "justShootHaloComposite"
        case chromatic = "justShootChromaticGain"
        case hdrHighlights = "justShootHDRHighlights"
    }

    static let shared = FilmImageKernels()
    private let kernels: [Name: CIColorKernel]

    subscript(_ name: Name) -> CIColorKernel? { kernels[name] }

    private init() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var loaded: [Name: CIColorKernel] = [:]
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            for name in Name.allCases {
                do {
                    loaded[name] = try CIColorKernel(functionName: name.rawValue, fromMetalLibraryData: data)
                } catch {
                    Log.lut.error("film_kernel_load_failed name=\(name.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            Log.lut.error("film_kernel_library_missing")
        }
        kernels = loaded
        Diagnostics.emit("film_kernels_prepared",
            fields: "main_thread=\(Thread.isMainThread) count=\(loaded.count) duration_ms=\(Diagnostics.milliseconds(since: startedAt))")
    }
}
