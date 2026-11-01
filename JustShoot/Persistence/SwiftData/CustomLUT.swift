import Foundation
import SwiftData

@Model
final class CustomLUT: Identifiable {
    var id: UUID
    var displayName: String
    var fileName: String
    var iso: Float
    var dimension: Int
    var createdAt: Date

    init(displayName: String, fileName: String, iso: Float, dimension: Int) {
        self.id = UUID()
        self.displayName = displayName
        self.fileName = fileName
        self.iso = iso
        self.dimension = dimension
        self.createdAt = Date()
    }
}
