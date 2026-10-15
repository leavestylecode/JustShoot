import Foundation

/// Only the previous selection is promoted to an editable curve. Frozen points preserve
/// its appearance independently of the smaller, updated built-in catalog.
enum LegacyCurveMigration {
    static func customCurve(for id: String) -> CustomFilmCurve? {
        let name: String
        let master: [(Float, Float)]
        switch id {
        case "softShoulder":
            name = String(localized: "Film Soft")
            master = [(0, 0), (0.08, 0.045), (0.25, 0.20), (0.50, 0.52), (0.75, 0.82), (0.92, 0.965), (1, 1)]
        case "airyPastel":
            name = String(localized: "Open Shadows")
            master = [(0, 0), (0.08, 0.11), (0.25, 0.31), (0.50, 0.54), (0.75, 0.79), (0.92, 0.95), (1, 1)]
        case "softFaded":
            name = String(localized: "Fade")
            master = [(0, 0.075), (0.25, 0.29), (0.50, 0.51), (0.75, 0.72), (1, 0.93)]
        case "matteShadow":
            name = String(localized: "Matte")
            master = [(0, 0.06), (0.16, 0.18), (0.35, 0.36), (0.62, 0.66), (0.84, 0.88), (1, 0.985)]
        case "warmRetro":
            var curve = CustomFilmCurve(name: String(localized: "Warm Print"))
            curve.redPoints = CurveMath.points([(0, 0.015), (0.15, 0.10), (0.38, 0.34), (0.62, 0.68), (0.85, 0.91), (1, 1)])
            curve.greenPoints = CurveMath.points([(0, 0.025), (0.15, 0.12), (0.38, 0.35), (0.62, 0.66), (0.85, 0.88), (1, 0.985)])
            curve.bluePoints = CurveMath.points([(0, 0.055), (0.15, 0.15), (0.38, 0.36), (0.62, 0.61), (0.85, 0.80), (1, 0.93)])
            return curve
        default: return nil
        }
        var curve = CustomFilmCurve(name: name)
        curve.masterPoints = CurveMath.points(master)
        return curve
    }
}
