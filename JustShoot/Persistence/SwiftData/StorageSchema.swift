import SwiftData

// MARK: - SwiftData 版本化 Schema & 迁移计划
// 迁移策略：当 Photo / CustomLUT 字段增删时，新增 SchemaV2 并在 stages 中声明
// .lightweight 或 .custom 迁移步骤，避免在存量用户端崩溃
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Photo.self, CustomLUT.self] }
}

enum JustShootMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
