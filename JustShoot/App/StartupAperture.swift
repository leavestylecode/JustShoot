import UIKit

/// Adjacent blades share a curved seam. Their inner lips form the six-sided opening.
struct StartupAperture {
    static let bladeCount = 6
    let time: Double
    let radius: CGFloat
    let rotation: CGFloat

    static func poses(in size: CGSize) -> [Self] {
        let corner = hypot(size.width, size.height) / 2
        let clearRadius = (corner + 4) / cos(.pi / CGFloat(bladeCount))
        let initialRadius = 36 * (1 - 2 * AppBrand.ringStrokeFraction)
        // Sample the linkage only when the window geometry or start time changes.
        // Core Animation interpolates the paths between poses.
        let closing = (0...4).map { step in
            let t = CGFloat(step) / 4
            let travel = t * t * (3 - 2 * t)
            return Self(time: 0.22 * t, radius: initialRadius * (1 - travel),
                        rotation: 0.22 - 0.60 * travel)
        }
        let opening = (0...12).map { step in
            let t = CGFloat(step) / 12
            let travel = t * t * (3 - 2 * t)
            return Self(time: 0.28 + 0.72 * t, radius: clearRadius * travel,
                        rotation: -0.38 + 0.92 * t * (2 - t))
        }
        return closing + opening
    }

    func outline(for index: Int, in size: CGSize) -> (face: CGPath, rim: CGPath) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = hypot(size.width, size.height) * 1.25 + 72
        let sector = 2 * CGFloat.pi / CGFloat(Self.bladeCount)
        func point(from origin: CGPoint, distance: CGFloat, angle: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + distance * cos(angle), y: origin.y + distance * sin(angle))
        }
        func seam(_ index: Int) -> (lip: CGPoint, bend: CGPoint, outer: CGPoint) {
            let base = CGFloat(index % Self.bladeCount) * sector - .pi / 2
            let lip = point(from: center, distance: radius, angle: base + rotation)
            let bend = point(from: lip, distance: (reach - radius) * 0.46,
                             angle: base + rotation + 1.35)
            let outer = point(from: center, distance: reach, angle: base + 0.48)
            return (lip, bend, outer)
        }
        let a = seam(index)
        let b = seam(index + 1)
        let midAngle = (CGFloat(index) + 0.5) * sector - .pi / 2 + rotation
        let lipControl = point(from: center, distance: radius * 0.92, angle: midAngle)
        let rim = CGMutablePath()
        rim.move(to: b.lip)
        rim.addQuadCurve(to: a.lip, control: lipControl)
        rim.addQuadCurve(to: a.outer, control: a.bend)
        let face = CGMutablePath()
        face.addPath(rim)
        face.addLine(to: b.outer)
        face.addQuadCurve(to: b.lip, control: b.bend)
        face.closeSubpath()
        return (face, rim)
    }
}
