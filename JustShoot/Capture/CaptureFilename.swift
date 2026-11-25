import Foundation

enum CaptureFilename {
    static let prefix = "OOO_"

    static func normalizedExtension(_ ext: String) -> String {
        let uppercase = ext.uppercased()
        return uppercase == "JPEG" ? "JPG" : uppercase
    }

    static func stem(number: Int) -> String {
        let digits = String(number)
        return prefix + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    static func stem(id: UUID?, number: Int?) -> String? {
        if let number { return stem(number: number) }
        return id.map { prefix + $0.uuidString }
    }
}
