import Foundation
import FotufilmCore

let inputs = try JSONDecoder().decode([[Float]].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var stock = FilmStock.named("phoenix200")!
// A color table must not depend on the neighboring sample colors.
stock.layeredTransport = nil
stock.emulsionDiffusionMM = [0, 0, 0]
stock.emulsionDiffusionSecondaryMM = [0, 0, 0]
stock.lumaDiffusionMM = 0
stock.mtfLumaShare = 0
stock.adjacencyStrength = 0
var options = FotufilmEngine.Options()
options.grainScale = 0
options.halationScale = 0
options.flareScale = 0
options.couplerScale = 0
options.localTone = false
options.paper = .screen
options.digitalReference = .referenceExposure
options.sceneIlluminantKelvin = 6500
let engine = FotufilmEngine(stock: stock, options: options)
func render(_ inputs: [[Float]]) throws -> [[Float]] {
    var image = ImageBuffer(width: inputs.count, height: 1)
    for (i, rgb) in inputs.enumerated() {
        let decoded = SIMD3<Float>(ColorScience.srgbToLinear(rgb[0]),
            ColorScience.srgbToLinear(rgb[1]), ColorScience.srgbToLinear(rgb[2]))
        let linear = ColorScience.linearSRGBToRec2020(decoded)
        for c in 0..<3 { image.planes[c][i] = linear[c] }
    }
    let output = try engine.processChecked(linearRGB: image)
    return inputs.indices.map { i in
        let linear = ColorScience.linearDisplayP3ToSRGB(SIMD3<Float>(output.planes[0][i], output.planes[1][i], output.planes[2][i]))
        return (0..<3).map { c in
            min(max(ColorScience.linearToSrgb(ColorScience.displayShoulder(linear[c], knee: options.sdrShoulderKnee(for: stock))), 0), 1)
        }
    }
}
let output = try render(inputs)
let reversed = try render(Array(inputs.reversed()))
let permutationError = zip(output, reversed.reversed()).flatMap { pair in zip(pair.0, pair.1).map { abs($0 - $1) } }.max() ?? 0
guard permutationError < 0.000001 else { fatalError("Nonlocal LUT recipe: \(permutationError)") }
try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Rendered \(inputs.count) samples; permutation error \(permutationError)")
