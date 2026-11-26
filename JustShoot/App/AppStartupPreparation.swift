import Combine
import Foundation
import SwiftData

struct HomeCustomFilter: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let iso: Float
    let fileName: String

    init(id: UUID, displayName: String, iso: Float, fileName: String) {
        self.id = id
        self.displayName = displayName
        self.iso = iso
        self.fileName = fileName
    }

    init(_ model: CustomLUT) {
        id = model.id
        displayName = model.displayName
        iso = model.iso
        fileName = model.fileName
    }

    var source: FilmSource { .custom(id: id, displayName: displayName, iso: iso, fileName: fileName) }
}

@MainActor
final class AppStartupPreparation: ObservableObject {
    struct Ready {
        let container: ModelContainer
        let customFilters: [HomeCustomFilter]
    }

    typealias OpenStorage = @Sendable () throws -> ModelContainer
    typealias LoadCustomFilters = @Sendable (ModelContainer) async throws -> [HomeCustomFilter]

    @Published private(set) var ready: Ready?
    @Published private(set) var isPreparing = false
    @Published private(set) var hasFailed = false
    @Published private(set) var failureMessage: String?

    private let openStorage: OpenStorage
    private let loadCustomFilters: LoadCustomFilters
    private let timeout: Duration
    private var container: ModelContainer?
    private var openingStorage: Task<ModelContainer, any Error>?
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var deadlineGeneration: UInt64 = 0
    private var isActive = true

    init(timeout: Duration = .seconds(20),
         openStorage: @escaping OpenStorage = AppStartupPreparation.openDefaultStorage,
         loadCustomFilters: @escaping LoadCustomFilters = AppStartupPreparation.loadDefaultCustomFilters) {
        self.timeout = timeout
        self.openStorage = openStorage
        self.loadCustomFilters = loadCustomFilters
    }

    func prepare() async {
        guard ready == nil else { return }
        if let preparation { await preparation.value; return }
        Diagnostics.start()
        generation &+= 1
        let request = generation
        isPreparing = true
        hasFailed = false
        failureMessage = nil
        let operation = Task { [weak self] in
            guard let self else { return }
            let span = DiagnosticTrace(id: "startup").span("app_startup_prepare")
            do {
                let container = try await self.openContainer()
                try Task.checkCancellation()
                let customFilters = try await self.loadCustomFilters(container)
                try Task.checkCancellation()
                guard self.generation == request else { span.end("superseded"); return }
                self.cancelDeadline()
                self.ready = Ready(container: container, customFilters: customFilters)
                self.isPreparing = false
                self.preparation = nil
                span.end()
            } catch {
                span.end(error is CancellationError ? "cancelled" : "error", Diagnostics.errorFields(error))
                guard self.generation == request else { return }
                self.cancelDeadline()
                self.isPreparing = false
                self.preparation = nil
                self.hasFailed = !(error is CancellationError)
                self.failureMessage = self.hasFailed ? String(localized: "Your photos and filters are kept on this device.") : nil
            }
        }
        preparation = operation
        armDeadline(for: request)
        await operation.value
    }

    func retry() async {
        cancel()
        await prepare()
    }

    func cancel() {
        guard ready == nil else { return }
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        cancelDeadline()
        isPreparing = false
        hasFailed = false
        failureMessage = nil
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        cancelDeadline()
        if active, isPreparing { armDeadline(for: generation) }
    }

    private func openContainer() async throws -> ModelContainer {
        if let container { return container }
        let task: Task<ModelContainer, any Error>
        if let openingStorage { task = openingStorage }
        else {
            let open = openStorage
            task = Task.detached(priority: .userInitiated) {
                let span = DiagnosticTrace(id: "storage").span("storage_open")
                do { let value = try open(); span.end(); return value }
                catch { span.end("error", Diagnostics.errorFields(error)); throw error }
            }
            openingStorage = task
        }
        do {
            let opened = try await task.value
            container = opened
            if openingStorage == task { openingStorage = nil }
            return opened
        } catch {
            if openingStorage == task { openingStorage = nil }
            throw error
        }
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadline?.cancel()
        deadline = nil
    }

    private func armDeadline(for request: UInt64) {
        guard isActive else { return }
        cancelDeadline()
        let deadlineID = deadlineGeneration
        let timeout = timeout
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            guard !Task.isCancelled, let self, self.isActive, self.isPreparing,
                  self.generation == request, self.deadlineGeneration == deadlineID else { return }
            self.cancel()
            self.hasFailed = true
            self.failureMessage = String(localized: "Opening the library timed out.")
            Diagnostics.emit("app_startup_timeout")
        }
    }

    nonisolated private static func openDefaultStorage() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        try FileManager.default.createDirectory(at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try ModelContainer(for: schema, migrationPlan: JustShootMigrationPlan.self, configurations: [configuration])
    }

    nonisolated private static func loadDefaultCustomFilters(container: ModelContainer) async throws -> [HomeCustomFilter] {
        try await Task.detached(priority: .userInitiated) {
            try DiagnosticTrace(id: "startup").measure("startup_custom_filters") {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<CustomLUT>(sortBy: [SortDescriptor(\CustomLUT.createdAt, order: .reverse)])
                return try context.fetch(descriptor).map(HomeCustomFilter.init)
            }
        }.value
    }
}
