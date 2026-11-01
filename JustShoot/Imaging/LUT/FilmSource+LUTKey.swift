import Foundation

extension FilmSource {
    /// FilmProcessor 缓存键
    var lutCacheKey: String {
        switch self {
        case .preset(let p): return p.lutResourceName + FilmLookRefinement.cacheSuffix
                + (p == .kodakPortra400 ? FilmMaterial.revision : "")
        case .custom(let id, _, _, _): return "custom_\(id.uuidString)"
        }
    }
}
