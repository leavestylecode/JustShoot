import Foundation
import Vision
import ImageIO

struct Pair: Decodable {
    let name: String
    let before: String
    let after: String
}

struct TextLine: Codable {
    let text: String
    let confidence: Float
    let y: Double
}

struct Result: Codable {
    let name: String
    let before: [TextLine]
    let after: [TextLine]
}

func recognize(_ path: String) throws -> [TextLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.005
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { item in
        guard let candidate = item.topCandidates(1).first else { return nil }
        return TextLine(text: candidate.string, confidence: candidate.confidence, y: item.boundingBox.minY)
    }
}

let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var results: [Result] = []
for (index, pair) in pairs.enumerated() {
    let result = try autoreleasepool {
        Result(name: pair.name, before: try recognize(pair.before), after: try recognize(pair.after))
    }
    results.append(result)
    if (index + 1) % 10 == 0 {
        print("OCR checked \(index + 1)/\(pairs.count)")
        fflush(stdout)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
print("OCR finished \(results.count) cover pairs")
