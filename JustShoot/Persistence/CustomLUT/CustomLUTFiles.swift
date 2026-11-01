import Foundation

/// File locations are independent of SwiftData model instances.
enum CustomLUTFiles {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("CustomLUTs", isDirectory: true)
    }
}

extension CustomLUT {
    static var storageDirectory: URL { CustomLUTFiles.directory }
    var fileURL: URL { CustomLUTFiles.directory.appendingPathComponent(fileName) }
}
