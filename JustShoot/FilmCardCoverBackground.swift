import SwiftUI
import UIKit

// Dominant-color extraction for the film card detail backdrop. Port of
// DeepMusic's BackgroundBlurHelper.extractDominantColor — same 4-corner CPU
// algorithm: 4×48px patches → 16×16 downsample → fast path on uniform corners,
// otherwise a 4×4×4 RGB histogram weighted by saturation. HSV value clamped
// to [0.08, 0.96] so neither pure black nor pure white slip through.

enum FilmCardCoverColor {
    struct Result: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let luminance: CGFloat
    }

    static func extract(from image: UIImage) -> Result? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let minDim = min(width, height)
        guard minDim >= 64 else { return nil }

        // Skip the outermost 3% so 1–5px frames/borders don't dominate.
        let inset = max(1, Int((Double(minDim) * 0.03).rounded()))
        let patchSize = min(48, (minDim / 2) - inset)
        guard patchSize >= 16 else { return nil }

        let destSize = 16
        let pixelsPerCorner = destSize * destSize
        let bytesPerCorner = pixelsPerCorner * 4

        let cornerOrigins: [(Int, Int)] = [
            (inset, inset),
            (width - patchSize - inset, inset),
            (inset, height - patchSize - inset),
            (width - patchSize - inset, height - patchSize - inset)
        ]

        var pixels = [UInt8](repeating: 0, count: 4 * bytesPerCorner)
        var cornerMeans: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        cornerMeans.reserveCapacity(4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        for (idx, origin) in cornerOrigins.enumerated() {
            let rect = CGRect(x: origin.0, y: origin.1, width: patchSize, height: patchSize)
            guard let cropped = cgImage.cropping(to: rect) else { return nil }

            let byteOffset = idx * bytesPerCorner
            let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress?.advanced(by: byteOffset),
                      let ctx = CGContext(
                        data: base,
                        width: destSize,
                        height: destSize,
                        bitsPerComponent: 8,
                        bytesPerRow: destSize * 4,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo
                      ) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: destSize, height: destSize))
                return true
            }
            guard success else { return nil }

            var sumR = 0, sumG = 0, sumB = 0
            for i in 0..<pixelsPerCorner {
                sumR += Int(pixels[byteOffset + i * 4])
                sumG += Int(pixels[byteOffset + i * 4 + 1])
                sumB += Int(pixels[byteOffset + i * 4 + 2])
            }
            let n = CGFloat(pixelsPerCorner) * 255
            cornerMeans.append((
                r: CGFloat(sumR) / n,
                g: CGFloat(sumG) / n,
                b: CGFloat(sumB) / n
            ))
        }

        // Fast path: all 4 corners agree to within 0.06 per channel → mean wins.
        let threshold: CGFloat = 0.06
        var isUniform = true
        uniformCheck: for i in 0..<cornerMeans.count {
            for j in (i + 1)..<cornerMeans.count {
                let dr = abs(cornerMeans[i].r - cornerMeans[j].r)
                let dg = abs(cornerMeans[i].g - cornerMeans[j].g)
                let db = abs(cornerMeans[i].b - cornerMeans[j].b)
                if max(dr, max(dg, db)) > threshold {
                    isUniform = false
                    break uniformCheck
                }
            }
        }

        if isUniform {
            let r0 = cornerMeans.reduce(CGFloat(0)) { $0 + $1.r } / 4
            let g0 = cornerMeans.reduce(CGFloat(0)) { $0 + $1.g } / 4
            let b0 = cornerMeans.reduce(CGFloat(0)) { $0 + $1.b } / 4
            return finalize(r: r0, g: g0, b: b0)
        }

        // Slow path: 4×4×4 histogram, score = count × (1 + saturation × 0.8)
        let binsPerChannel = 4
        let totalBins = binsPerChannel * binsPerChannel * binsPerChannel
        var counts = [Int](repeating: 0, count: totalBins)
        var sumsR = [CGFloat](repeating: 0, count: totalBins)
        var sumsG = [CGFloat](repeating: 0, count: totalBins)
        var sumsB = [CGFloat](repeating: 0, count: totalBins)

        let totalPixels = 4 * pixelsPerCorner
        for i in 0..<totalPixels {
            let r = CGFloat(pixels[i * 4]) / 255
            let g = CGFloat(pixels[i * 4 + 1]) / 255
            let b = CGFloat(pixels[i * 4 + 2]) / 255

            let br = min(Int(r * CGFloat(binsPerChannel)), binsPerChannel - 1)
            let bg = min(Int(g * CGFloat(binsPerChannel)), binsPerChannel - 1)
            let bb = min(Int(b * CGFloat(binsPerChannel)), binsPerChannel - 1)
            let idx = (br * binsPerChannel + bg) * binsPerChannel + bb

            counts[idx] += 1
            sumsR[idx] += r
            sumsG[idx] += g
            sumsB[idx] += b
        }

        var bestIdx = 0
        var bestScore: CGFloat = 0
        var bestCount = 0
        for i in 0..<totalBins where counts[i] > 0 {
            let c = CGFloat(counts[i])
            let r = sumsR[i] / c
            let g = sumsG[i] / c
            let b = sumsB[i] / c
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let s = maxC == 0 ? 0 : (maxC - minC) / maxC
            let score = c * (1 + s * 0.8)
            if score > bestScore {
                bestScore = score
                bestIdx = i
                bestCount = counts[i]
            }
        }

        guard bestCount > 0 else { return nil }
        let c = CGFloat(bestCount)
        let r0 = sumsR[bestIdx] / c
        let g0 = sumsG[bestIdx] / c
        let b0 = sumsB[bestIdx] / c
        return finalize(r: r0, g: g0, b: b0)
    }

    private static func finalize(r: CGFloat, g: CGFloat, b: CGFloat) -> Result {
        var (h, s, v) = rgbToHsv(r: r, g: g, b: b)
        v = min(max(v, 0.08), 0.96)
        let rgb = hsvToRgb(h: h, s: s, v: v)
        let luminance = (0.2126 * rgb.r) + (0.7152 * rgb.g) + (0.0722 * rgb.b)
        return Result(
            red: rgb.r, green: rgb.g, blue: rgb.b,
            luminance: min(max(luminance, 0), 1)
        )
    }

    private static func rgbToHsv(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let v = maxC
        let s = maxC == 0 ? 0 : delta / maxC
        var h: CGFloat = 0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, v)
    }

    private static func hsvToRgb(h: CGFloat, s: CGFloat, v: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        if s == 0 { return (v, v, v) }
        let hh = h * 6
        let i = Int(hh.rounded(.down)) % 6
        let f = hh - CGFloat(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

// MARK: - Process-wide cache (keyed by FilmCard.id)

private final class FilmCardCoverColorCache: @unchecked Sendable {
    final class Box: NSObject, @unchecked Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let luminance: CGFloat
        nonisolated init(red: CGFloat, green: CGFloat, blue: CGFloat, luminance: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.luminance = luminance
        }
    }

    nonisolated(unsafe) private let store: NSCache<NSString, Box>

    nonisolated init() {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 256
        store = cache
    }

    nonisolated func value(forKey key: NSString) -> Box? { store.object(forKey: key) }
    nonisolated func setValue(_ value: Box, forKey key: NSString) { store.setObject(value, forKey: key) }
}

// MARK: - Manager

@Observable
@MainActor
final class FilmCardCoverColorManager: Sendable {
    var dominantColor: UIColor = FilmCardCoverColorManager.fallbackColor
    var luminance: CGFloat = FilmCardCoverColorManager.fallbackLuminance

    private var task: Task<Void, Never>?
    private var currentCardId: String?
    private let transitionAnimation = Animation.easeOut(duration: 0.22)

    nonisolated static let fallbackColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    nonisolated static let fallbackLuminance: CGFloat = 0.15

    private nonisolated static let cache = FilmCardCoverColorCache()

    /// Sync cache hit → first frame paints the cover tone, no async gap.
    func prefetchFromCache(cardId: String?) {
        guard let cardId else { return }
        currentCardId = cardId
        if let box = Self.cache.value(forKey: cardId as NSString) {
            dominantColor = UIColor(red: box.red, green: box.green, blue: box.blue, alpha: 1)
            luminance = box.luminance
        }
    }

    func refresh(for card: FilmCard) {
        let cardId = card.id
        if cardId == currentCardId, dominantColor != Self.fallbackColor {
            return
        }
        currentCardId = cardId
        let cacheKey = cardId as NSString

        if let box = Self.cache.value(forKey: cacheKey) {
            task?.cancel()
            task = nil
            apply(
                UIColor(red: box.red, green: box.green, blue: box.blue, alpha: 1),
                luminance: box.luminance,
                animated: dominantColor != Self.fallbackColor
            )
            return
        }

        task?.cancel()
        task = Task { [weak self] in
            // 320px is plenty: extractor needs minDim ≥ 64 and 48×48 corner
            // patches, so any reasonable thumbnail works and reuses the same
            // FilmCardImageCache slot the grid populates.
            guard let image = await FilmCardImageCache.shared.loadImage(card: card, maxPixel: 320) else { return }
            guard !Task.isCancelled else { return }
            let extracted = await Task.detached(priority: .utility) {
                FilmCardCoverColor.extract(from: image)
            }.value
            guard let result = extracted else { return }
            let box = FilmCardCoverColorCache.Box(
                red: result.red, green: result.green, blue: result.blue, luminance: result.luminance
            )
            Self.cache.setValue(box, forKey: cacheKey)
            guard let self, !Task.isCancelled, self.currentCardId == cardId else { return }
            let color = UIColor(red: result.red, green: result.green, blue: result.blue, alpha: 1)
            self.apply(color, luminance: result.luminance, animated: true)
            self.task = nil
        }
    }

    private func apply(_ color: UIColor, luminance: CGFloat, animated: Bool) {
        if animated {
            withAnimation(transitionAnimation) {
                dominantColor = color
                self.luminance = min(max(luminance, 0), 1)
            }
        } else {
            dominantColor = color
            self.luminance = min(max(luminance, 0), 1)
        }
    }
}

// MARK: - Backdrop view
// Flat dominant color + a luminance/contrast-aware top + bottom readability
// scrim. Same constants as PlaylistCoverBackgroundView.readabilityScrim.

struct FilmCardCoverBackdrop: View {
    let dominantColor: UIColor
    let luminance: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(dominantColor)
            readabilityScrim
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topScrimStrength: Double {
        let lum = Double(luminance)
        let contrastBoost = colorSchemeContrast == .increased ? 0.05 : 0
        let transparencyBoost = reduceTransparency ? 0.04 : 0
        if colorScheme == .dark {
            return min(0.08 + (lum * 0.08) + contrastBoost + transparencyBoost, 0.24)
        }
        return min(0.05 + ((1 - lum) * 0.06) + contrastBoost + transparencyBoost, 0.18)
    }

    private var bottomScrimStrength: Double {
        let lum = Double(luminance)
        let contrastBoost = colorSchemeContrast == .increased ? 0.08 : 0
        let transparencyBoost = reduceTransparency ? 0.08 : 0
        if colorScheme == .dark {
            return min(0.18 + (lum * 0.18) + contrastBoost + transparencyBoost, 0.46)
        }
        return min(0.12 + ((1 - lum) * 0.16) + contrastBoost + transparencyBoost, 0.34)
    }

    private var readabilityScrim: some View {
        let scrim: Color = colorScheme == .dark ? .black : .white
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: scrim.opacity(topScrimStrength), location: 0.0),
                    .init(color: scrim.opacity(topScrimStrength * 0.45), location: 0.12),
                    .init(color: .clear, location: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.56),
                    .init(color: scrim.opacity(bottomScrimStrength * 0.45), location: 0.78),
                    .init(color: scrim.opacity(bottomScrimStrength), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Foreground palette
// Picks white-ish vs near-black ink based on the backdrop luminance, then
// exposes the standard hierarchy multipliers (primary / secondary / tertiary /
// quaternary). Threshold at 0.55: pastels and light covers flip to dark ink,
// most colored covers stay on white.

struct FilmCardForegroundPalette {
    let prefersDarkInk: Bool

    init(luminance: CGFloat) {
        self.prefersDarkInk = luminance >= 0.55
    }

    var primary: Color {
        prefersDarkInk ? Color(red: 0.07, green: 0.07, blue: 0.09) : .white
    }

    var secondary: Color { primary.opacity(0.72) }
    var tertiary: Color { primary.opacity(0.55) }
    var quaternary: Color { primary.opacity(0.40) }

    /// Soft tint used for chip/pill fills — readable on either ink color.
    var chipFill: Color { primary.opacity(prefersDarkInk ? 0.10 : 0.14) }
    var divider: Color { primary.opacity(prefersDarkInk ? 0.18 : 0.22) }
}
