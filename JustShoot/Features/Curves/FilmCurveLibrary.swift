import Foundation
import Combine
import OSLog

/// Selection, order and catalog commit together; the old selection key is a compatibility mirror.
@MainActor
final class FilmCurveLibrary: ObservableObject {
    static let shared = FilmCurveLibrary(cloud: CloudKitFilmCurveStorage())

    enum Entry: Identifiable, Hashable {
        case builtIn(CurvePreset)
        case custom(CustomFilmCurve)

        var id: String {
            switch self {
            case .builtIn(let preset): return preset.id
            case .custom(let curve): return FilmCurveLibrary.customID(curve.id)
            }
        }

        var displayName: String {
            switch self {
            case .builtIn(let preset): return preset.displayName
            case .custom(let curve): return curve.name
            }
        }

        var customCurve: CustomFilmCurve? {
            guard case .custom(let curve) = self else { return nil }
            return curve
        }
    }

    @Published private(set) var entries = CurvePreset.allCases.map(Entry.builtIn)
    @Published private(set) var hiddenBuiltInIDs: Set<String> = []
    @Published private(set) var selectedCurveID = CurvePreset.none.rawValue
    @Published private(set) var storageError: String?
    var canEdit: Bool { storageError == nil }

    private struct Header: Decodable { let version: Int }
    private struct Payload: Codable {
        var version: Int
        var customCurves: [CustomFilmCurve]
        var hiddenBuiltInIDs: [String]
        var selectedCurveID: String?
        var orderedCurveIDs: [String]?
        var sync: CloudState?
    }

    private struct ArchivedAccount: Codable {
        var catalog: FilmCurveCatalog
        var base: FilmCurveCatalog
        var selection: String
    }

    private struct CloudState: Codable {
        var account: String?
        var base = FilmCurveCatalog()
        var archived: [String: ArchivedAccount] = [:]
    }
    private static let payloadKey = "filmCurveLibrary.v1"
    private static let selectionKey = "curvePreset"
    private let defaults: UserDefaults
    private var customCache: [UUID: FilmCurve] = [:]

    private let cloud: (any FilmCurveCloudStorage)?
    private var cloudState = CloudState()
    private var syncTask: Task<Void, Never>?
    private var cloudStarted = false

    init(defaults: UserDefaults = .standard, cloud: (any FilmCurveCloudStorage)? = nil) {
        self.cloud = cloud
        self.defaults = defaults
        let payload: Payload?
        if let data = defaults.data(forKey: Self.payloadKey) {
            do {
                let header = try JSONDecoder().decode(Header.self, from: data)
                guard (1...2).contains(header.version) else { storageError = Self.readErrorMessage; return }
                payload = try JSONDecoder().decode(Payload.self, from: data)
            } catch { storageError = Self.readErrorMessage; return }
        } else {
            guard defaults.object(forKey: Self.payloadKey) == nil else { storageError = Self.readErrorMessage; return }
            payload = nil
        }
        cloudState = payload?.sync ?? CloudState()
        var seen = Set<UUID>()
        var curves = (payload?.customCurves ?? []).map { $0.normalized() }
            .filter { seen.insert($0.id).inserted && !$0.name.isEmpty }
        let validBuiltIns = Set(CurvePreset.allCases.map(\.rawValue))
        let storedHidden = Set(payload?.hiddenBuiltInIDs ?? [])
        let mappedHidden = Set(storedHidden.map { $0 == "matteShadow" ? CurvePreset.matte.rawValue : $0 })
        let hidden = mappedHidden.intersection(validBuiltIns).subtracting([CurvePreset.none.rawValue])
        var selection = payload?.selectedCurveID ?? defaults.string(forKey: Self.selectionKey) ?? CurvePreset.none.rawValue
        let needsLegacyDefinition = payload?.selectedCurveID == nil || CurvePreset(rawValue: selection) == nil
        if needsLegacyDefinition, !storedHidden.contains(selection),
           let migrated = LegacyCurveMigration.customCurve(for: selection) {
            curves.append(migrated)
            selection = Self.customID(migrated.id)
        }
        selection = Self.validSelection(selection, curves: curves, hidden: hidden)
        // Fresh installs need an explicit selection too: a new softShoulder selection
        // must not be mistaken for its previous definition on the next launch.
        var order = payload?.orderedCurveIDs ?? CurvePreset.allCases.map(\.id)
        if !order.contains(CurvePreset.fadedS.id), let fadedIndex = order.firstIndex(of: CurvePreset.matte.id) {
            order.insert(CurvePreset.fadedS.id, at: fadedIndex + 1)
        }
        _ = commit(curves: curves, hidden: hidden, selection: selection, order: order)
    }

    var customCurves: [CustomFilmCurve] { entries.compactMap(\.customCurve) }

    private func isVisible(_ entry: Entry) -> Bool {
        switch entry {
        case .builtIn(let preset): isBuiltInVisible(preset)
        case .custom(let curve): curve.isVisible
        }
    }

    var visibleEntries: [Entry] { entries.filter { isVisible($0) } }
    var hiddenEntries: [Entry] { entries.filter { !isVisible($0) } }

    var visibleCurves: [FilmCurve] {
        visibleEntries.compactMap { entry in
            switch entry {
            case .builtIn(let preset): return .builtIn(preset)
            case .custom(let curve): return customCache[curve.id]
            }
        }
    }
    var selectedCurve: FilmCurve { curve(id: selectedCurveID) ?? .builtIn(.none) }

    var selectedCurveDefinition: PhotoEditCurve {
        guard let entry = entries.first(where: { $0.id == selectedCurveID }) else { return .preset(.none) }
        switch entry {
        case .builtIn(let preset): return .preset(preset)
        case .custom(let definition): return .custom(definition)
        }
    }

    func previewData(for entry: Entry) -> CurvePreviewData? {
        switch entry {
        case .builtIn(let preset): return preset.previewData
        case .custom(let curve): return customCache[curve.id]?.previewData
        }
    }

    func curve(id: String) -> FilmCurve? {
        if let preset = CurvePreset(rawValue: id) { return hiddenBuiltInIDs.contains(id) ? nil : .builtIn(preset) }
        guard let uuid = Self.customUUID(id), entries.contains(where: { entry in
            guard case .custom(let curve) = entry else { return false }
            return curve.id == uuid && curve.isVisible
        }) else { return nil }
        return customCache[uuid]
    }

    @discardableResult
    func select(_ curve: FilmCurve) -> Bool {
        guard canEdit, let current = self.curve(id: curve.id) else { return false }
        return commit(curves: customCurves, hidden: hiddenBuiltInIDs, selection: current.id)
    }
    func isBuiltInVisible(_ preset: CurvePreset) -> Bool { !hiddenBuiltInIDs.contains(preset.rawValue) }

    @discardableResult
    func setOrder(_ ids: [String]) -> Bool {
        let currentIDs = entries.map(\.id)
        guard canEdit, ids.count == currentIDs.count, Set(ids) == Set(currentIDs) else { return false }
        if ids == currentIDs { return true }
        return commit(curves: customCurves, hidden: hiddenBuiltInIDs, selection: selectedCurveID, order: ids)
    }

    @discardableResult
    func setVisibleOrder(_ ids: [String]) -> Bool {
        let visible = visibleEntries.map(\.id)
        guard ids.count == visible.count, Set(ids) == Set(visible) else { return false }
        var reordered = ids.makeIterator()
        return setOrder(entries.map { entry in isVisible(entry) ? (reordered.next() ?? entry.id) : entry.id })
    }

    @discardableResult
    func resetList() -> Bool {
        let curves = customCurves.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }.map { curve in
            var updated = curve
            if !updated.isVisible {
                updated.isVisible = true
                updated.updatedAt = Date()
            }
            return updated
        }
        let order = CurvePreset.allCases.map(\.id) + curves.map { Self.customID($0.id) }
        return commit(curves: curves, hidden: [], selection: selectedCurveID, order: order)
    }

    @discardableResult
    func setBuiltIn(_ preset: CurvePreset, isVisible: Bool) -> Bool {
        guard canEdit, preset != .none else { return false }
        var hidden = hiddenBuiltInIDs
        if isVisible { hidden.remove(preset.rawValue) } else { hidden.insert(preset.rawValue) }
        let selection = !isVisible && selectedCurveID == preset.rawValue ? CurvePreset.none.rawValue : selectedCurveID
        return commit(curves: customCurves, hidden: hidden, selection: selection)
    }

    @discardableResult
    func setCustomVisibility(id: UUID, isVisible: Bool) -> Bool {
        var curves = customCurves
        guard canEdit, let index = curves.firstIndex(where: { $0.id == id }) else { return false }
        curves[index].isVisible = isVisible
        curves[index].updatedAt = Date()
        let selection = !isVisible && selectedCurveID == Self.customID(id) ? CurvePreset.none.rawValue : selectedCurveID
        return commit(curves: curves, hidden: hiddenBuiltInIDs, selection: selection)
    }

    @discardableResult
    func add(_ curve: CustomFilmCurve) -> Bool {
        let curves = customCurves
        guard canEdit, !curves.contains(where: { $0.id == curve.id }) else { return false }
        var normalized = curve.normalized()
        guard !normalized.name.isEmpty else { return false }
        normalized.updatedAt = Date()
        return commit(curves: curves + [normalized], hidden: hiddenBuiltInIDs, selection: selectedCurveID)
    }

    @discardableResult
    func update(_ curve: CustomFilmCurve, editedFrom original: CustomFilmCurve? = nil) -> Bool {
        var curves = customCurves
        guard canEdit, let index = curves.firstIndex(where: { $0.id == curve.id }) else { return false }
        var normalized = curve.normalized()
        guard !normalized.name.isEmpty else { return false }
        // An editor's stale draft must not undo a catalog visibility change.
        normalized.isVisible = curves[index].isVisible
        normalized.createdAt = curves[index].createdAt
        normalized.updatedAt = Date()
        curves[index] = original.map { curves[index].merging(edit: normalized, since: $0) } ?? normalized
        return commit(curves: curves, hidden: hiddenBuiltInIDs, selection: selectedCurveID)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let curves = customCurves
        guard canEdit, curves.contains(where: { $0.id == id }) else { return false }
        let selection = selectedCurveID == Self.customID(id) ? CurvePreset.none.rawValue : selectedCurveID
        return commit(curves: curves.filter { $0.id != id }, hidden: hiddenBuiltInIDs, selection: selection)
    }

    private func commit(curves: [CustomFilmCurve], hidden: Set<String>, selection: String, order: [String]? = nil,
                        syncing: Bool = false) -> Bool {
        guard canEdit else { return false }
        let catalog = CurvePreset.allCases.map(Entry.builtIn) + curves.map(Entry.custom)
        var remaining = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let updatedEntries = ((order ?? entries.map(\.id)) + catalog.map(\.id)).compactMap {
            remaining.removeValue(forKey: $0)
        }
        let payload = Payload(version: 2, customCurves: updatedEntries.compactMap(\.customCurve),
            hiddenBuiltInIDs: hidden.sorted(), selectedCurveID: selection, orderedCurveIDs: updatedEntries.map(\.id), sync: cloudState.account == nil && cloudState.archived.isEmpty ? nil : cloudState)
        let data: Data
        do { data = try JSONEncoder().encode(payload) }
        catch { storageError = Self.readErrorMessage; return false }
        defaults.set(data, forKey: Self.payloadKey)
        let old = Dictionary(uniqueKeysWithValues: customCurves.map { ($0.id, $0) })
        customCache = Dictionary(uniqueKeysWithValues: curves.map { curve in
            if old[curve.id] == curve, let cached = customCache[curve.id] { return (curve.id, cached) }
            return (curve.id, curve.filmCurve)
        })
        let changed = updatedEntries != entries || hidden != hiddenBuiltInIDs
        if updatedEntries != entries { entries = updatedEntries }
        if hidden != hiddenBuiltInIDs { hiddenBuiltInIDs = hidden }
        if selectedCurveID != selection { selectedCurveID = selection }
        defaults.set(selection, forKey: Self.selectionKey)
        if changed, cloudStarted, !syncing { refreshCloud() }
        return true
    }

    private var catalog: FilmCurveCatalog {
        FilmCurveCatalog(customCurves: customCurves, hiddenBuiltInIDs: hiddenBuiltInIDs, order: entries.map(\.id))
    }

    @discardableResult
    func refreshCloud() -> Task<Void, Never>? {
        guard let cloud, canEdit else { return nil }
        cloudStarted = true
        if let syncTask { return syncTask }
        let task = Task(priority: .utility) {
            defer { if !Task.isCancelled { syncTask = nil } }
            do {
                let account = try await cloud.accountID()
                try Task.checkCancellation()
                switchAccount(to: account)
                guard let account else { return }
                while canEdit {
                    let local = catalog
                    let synced = try await cloud.synchronize(accountID: account, base: cloudState.base, local: local)
                    try Task.checkCancellation()
                    // Edits made while the request was in flight still need to be uploaded.
                    let current = catalog
                    let applied = current == local ? synced : synced.merging(local: current, since: local)
                    if cloudState.base != synced || applied != current {
                        cloudState.base = synced
                        install(applied, selection: selectedCurveID)
                    }
                    if applied == synced { return }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                let error = error as NSError
                Log.ui.debug("curve_sync_deferred domain=\(error.domain, privacy: .public) code=\(error.code)")
            }
        }
        syncTask = task
        return task
    }

    func cloudAccountChanged() {
        syncTask?.cancel()
        syncTask = nil
        refreshCloud()
    }

    private func switchAccount(to account: String?) {
        guard cloudState.account != account else { return }
        let local = catalog
        let signedOut = cloudState.account == nil
        if let old = cloudState.account {
            cloudState.archived[old] = ArchivedAccount(catalog: local, base: cloudState.base, selection: selectedCurveID)
        }
        let saved = account.flatMap { cloudState.archived.removeValue(forKey: $0) }
        cloudState.account = account
        cloudState.base = saved?.base ?? FilmCurveCatalog()
        var next = saved?.catalog ?? FilmCurveCatalog()
        var selection = saved?.selection ?? CurvePreset.none.id
        if signedOut {
            next = next.merging(local: local, since: FilmCurveCatalog())
            if selectedCurveID != CurvePreset.none.id { selection = selectedCurveID }
        }
        install(next, selection: selection)
    }

    private func install(_ catalog: FilmCurveCatalog, selection: String) {
        let valid = Self.validSelection(selection, curves: catalog.customCurves, hidden: catalog.hiddenBuiltInIDs)
        _ = commit(curves: catalog.customCurves, hidden: catalog.hiddenBuiltInIDs, selection: valid,
                   order: catalog.order, syncing: true)
    }

    private static func validSelection(_ id: String, curves: [CustomFilmCurve], hidden: Set<String>) -> String {
        if let preset = CurvePreset(rawValue: id), !hidden.contains(preset.rawValue) { return preset.rawValue }
        if let uuid = customUUID(id), curves.contains(where: { $0.id == uuid && $0.isVisible }) { return customID(uuid) }
        return CurvePreset.none.rawValue
    }
    nonisolated static func customUUID(_ id: String) -> UUID? {
        guard id.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("custom:".count)))
    }
    nonisolated static func customID(_ id: UUID) -> String { "custom:\(id.uuidString.lowercased())" }
    private static var readErrorMessage: String {
        String(localized: "Your saved curves could not be read. They are preserved on this device; editing is unavailable.")
    }
}
