import Foundation
import SwiftData

/// Commit the index first; a failed save must not leave a live row pointing to a deleted LUT.
@MainActor
enum CustomLUTPersistence {
    static func delete(_ lut: CustomLUT, in context: ModelContext,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let file = lut.fileURL
        let key = FilmSource.from(lut).lutCacheKey
        context.delete(lut)
        do { try save(context) }
        catch {
            context.rollback()
            // iOS 17 can detach a previously saved model during rollback.
            // Reattach the same identity; the source file is still intact.
            if lut.modelContext == nil { context.insert(lut) }
            throw error
        }
        FilmProcessor.shared.removeCachedLUT(cacheKey: key)
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch {
            // The index is already committed. Launch maintenance can safely remove this orphan.
            Diagnostics.emit("lut_file_cleanup_deferred", fields: Diagnostics.errorFields(error))
        }
    }

    /// A prepared tile can be actionable before @Query delivers its first model array.
    /// Missing records only retire the tile; their former file is left for normal maintenance.
    static func deletePreparedCustomFilter(id: UUID, queried: [CustomLUT], in context: ModelContext) throws -> Bool {
        let model: CustomLUT?
        if let cached = queried.first(where: { !$0.isDeleted && $0.id == id }) { model = cached }
        else {
            var descriptor = FetchDescriptor<CustomLUT>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            model = try context.fetch(descriptor).first { !$0.isDeleted }
        }
        guard let model else { return false }
        try CustomLUTPersistence.delete(model, in: context)
        return true
    }

}
