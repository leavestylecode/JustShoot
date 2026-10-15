import Foundation
import Combine

/// Selection and catalog commit together; the old selection key is only a compatibility mirror.
@MainActor
final class FilmCurveLibrary: ObservableObject {
    @Published private(set) var customCurves: [CustomFilmCurve] = []
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
    }
    private static let payloadKey = "filmCurveLibrary.v1"
    private static let selectionKey = "curvePreset"
    private let defaults: UserDefaults
    private var customCache: [UUID: FilmCurve] = [:]

    init(defaults: UserDefaults = .standard) {
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
        _ = commit(curves: curves, hidden: hidden, selection: selection)
    }

    var visibleCurves: [FilmCurve] {
        CurvePreset.allCases.filter { !hiddenBuiltInIDs.contains($0.rawValue) }.map(FilmCurve.builtIn)
            + customCurves.filter(\.isVisible).compactMap { customCache[$0.id] }
    }
    var selectedCurve: FilmCurve { curve(id: selectedCurveID) ?? .builtIn(.none) }
    var totalCurveCount: Int { CurvePreset.allCases.count + customCurves.count }
    var visibleCurveCount: Int { visibleCurves.count }

    func curve(id: String) -> FilmCurve? {
        if let preset = CurvePreset(rawValue: id) { return hiddenBuiltInIDs.contains(id) ? nil : .builtIn(preset) }
        guard let uuid = Self.customUUID(id), customCurves.contains(where: { $0.id == uuid && $0.isVisible }) else { return nil }
        return customCache[uuid]
    }

    @discardableResult
    func select(_ curve: FilmCurve) -> Bool {
        guard canEdit, let current = self.curve(id: curve.id) else { return false }
        return commit(curves: customCurves, hidden: hiddenBuiltInIDs, selection: current.id)
    }
    func isBuiltInVisible(_ preset: CurvePreset) -> Bool { !hiddenBuiltInIDs.contains(preset.rawValue) }

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
        guard canEdit, let index = customCurves.firstIndex(where: { $0.id == id }) else { return false }
        var curves = customCurves
        curves[index].isVisible = isVisible
        curves[index].updatedAt = Date()
        let selection = !isVisible && selectedCurveID == Self.customID(id) ? CurvePreset.none.rawValue : selectedCurveID
        return commit(curves: curves, hidden: hiddenBuiltInIDs, selection: selection)
    }

    @discardableResult
    func add(_ curve: CustomFilmCurve) -> Bool {
        guard canEdit, !customCurves.contains(where: { $0.id == curve.id }) else { return false }
        var normalized = curve.normalized()
        guard !normalized.name.isEmpty else { return false }
        normalized.updatedAt = Date()
        return commit(curves: customCurves + [normalized], hidden: hiddenBuiltInIDs, selection: selectedCurveID)
    }

    @discardableResult
    func update(_ curve: CustomFilmCurve) -> Bool {
        guard canEdit, let index = customCurves.firstIndex(where: { $0.id == curve.id }) else { return false }
        var normalized = curve.normalized()
        guard !normalized.name.isEmpty else { return false }
        // An editor's stale draft must not undo a catalog visibility change.
        normalized.isVisible = customCurves[index].isVisible
        normalized.createdAt = customCurves[index].createdAt
        normalized.updatedAt = Date()
        var curves = customCurves
        curves[index] = normalized
        return commit(curves: curves, hidden: hiddenBuiltInIDs, selection: selectedCurveID)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard canEdit, customCurves.contains(where: { $0.id == id }) else { return false }
        let selection = selectedCurveID == Self.customID(id) ? CurvePreset.none.rawValue : selectedCurveID
        return commit(curves: customCurves.filter { $0.id != id }, hidden: hiddenBuiltInIDs, selection: selection)
    }

    private func commit(curves: [CustomFilmCurve], hidden: Set<String>, selection: String) -> Bool {
        guard canEdit else { return false }
        let payload = Payload(version: 2, customCurves: curves, hiddenBuiltInIDs: hidden.sorted(), selectedCurveID: selection)
        let data: Data
        do { data = try JSONEncoder().encode(payload) }
        catch { storageError = Self.readErrorMessage; return false }
        defaults.set(data, forKey: Self.payloadKey)
        let old = Dictionary(uniqueKeysWithValues: customCurves.map { ($0.id, $0) })
        customCache = Dictionary(uniqueKeysWithValues: curves.map { curve in
            if old[curve.id] == curve, let cached = customCache[curve.id] { return (curve.id, cached) }
            return (curve.id, curve.filmCurve)
        })
        customCurves = curves
        hiddenBuiltInIDs = hidden
        selectedCurveID = selection
        defaults.set(selection, forKey: Self.selectionKey)
        return true
    }

    private static func validSelection(_ id: String, curves: [CustomFilmCurve], hidden: Set<String>) -> String {
        if let preset = CurvePreset(rawValue: id), !hidden.contains(preset.rawValue) { return preset.rawValue }
        if let uuid = customUUID(id), curves.contains(where: { $0.id == uuid && $0.isVisible }) { return customID(uuid) }
        return CurvePreset.none.rawValue
    }
    private static func customUUID(_ id: String) -> UUID? {
        guard id.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("custom:".count)))
    }
    private static func customID(_ id: UUID) -> String { "custom:\(id.uuidString.lowercased())" }
    private static var readErrorMessage: String {
        String(localized: "Your saved curves could not be read. They are preserved on this device; editing is unavailable.")
    }
}
