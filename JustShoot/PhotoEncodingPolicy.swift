import CoreGraphics

/// A single automatic compression policy; image dimensions and film texture stay in the graph.
/// HEVC naturally spends more bytes on complex scenes. We do not infer scene complexity from
/// the camera's compressed source, or repeatedly encode a full-resolution image to hit a byte cap.
enum PhotoEncodingPolicy {
    enum Codec: String, CaseIterable, Sendable {
        case heif10
        case heif8
        case jpeg
    }

    enum Mode: String, Sendable {
        case automatic
        case legacy
    }

    struct Decision: Equatable, Sendable {
        let codec: Codec
        let quality: CGFloat
        let mode: Mode
    }

    static func decision(for codec: Codec, legacyQuality: CGFloat? = nil) -> Decision {
        // Existing capture journals retain their frozen recipe. New captures pass nil.
        if let legacyQuality, legacyQuality.isFinite {
            return Decision(codec: codec, quality: min(max(legacyQuality, 0), 1), mode: .legacy)
        }
        let quality: CGFloat = codec == .jpeg ? 0.9 : 0.85
        return Decision(codec: codec, quality: quality, mode: .automatic)
    }
}
