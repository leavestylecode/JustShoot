import Foundation

enum FilmSource: Hashable, Identifiable {
    case preset(FilmPreset)
    case custom(id: UUID, displayName: String, iso: Float, fileName: String)

    var rawSimulation: FujifilmSimulation? {
        if case .preset(let preset) = self { return preset.rawSimulation }
        return nil
    }

    var id: String {
        switch self {
        case .preset(let p): return p.rawValue
        case .custom(let id, _, _, _): return id.uuidString
        }
    }

    var displayName: String {
        switch self {
        case .preset(let p): return p.displayName
        case .custom(_, let name, _, _): return name
        }
    }

    var iso: Float {
        switch self {
        case .preset(let p): return p.iso
        case .custom(_, _, let iso, _): return iso
        }
    }

    /// Photo.filmPresetName 存储值（用于查询过滤）
    var photoFilterName: String {
        switch self {
        case .preset(let p): return p.rawValue
        case .custom(let id, _, _, _): return "custom:\(id.uuidString)"
        }
    }
}
