// Read-only OCR for generated packaging titles; supplements visual review.
import Foundation
import Vision
import ImageIO

let paths = CommandLine.arguments.dropFirst()
var records: [[String: Any]] = []
for path in paths {
    autoreleasepool {
        let url = URL(fileURLWithPath: path)
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let observations: [[String: Any]] = (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return ["text": candidate.string, "confidence": candidate.confidence,
                        "x": box.origin.x, "y": box.origin.y, "width": box.width, "height": box.height]
            }
            records.append(["path": path, "text": text, "observations": observations])
        } catch {
            records.append(["path": path, "error": String(describing: error)])
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
