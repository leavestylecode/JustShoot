import SwiftData
import Foundation

enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Photo.self, CustomLUT.self] }

    // Keep the original store checksum so existing indexes migrate in place.
    @Model final class Photo {
        var id: UUID
        var timestamp: Date
        var assetLocalIdentifier: String?
        @Attribute(.externalStorage) var imageData: Data?
        var filmPresetName: String?
        var filmDisplayLabel: String?
        var isLivePhoto: Bool = false
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var locationTimestamp: Date?

        init(id: UUID, timestamp: Date) {
            self.id = id
            self.timestamp = timestamp
        }
    }
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Photo.self, CustomLUT.self] }
}

enum JustShootMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)] }
}
