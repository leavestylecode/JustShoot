import Foundation
import SwiftData

/// One deletion transaction is shared by single-photo and gallery selection actions.
/// The capture gate stays held across the system confirmation and index commit.
@MainActor
struct PhotoDeletionService {
    struct Operations {
        let begin: ([UUID], [String]) async -> [UUID]?
        let deleteAssets: ([String]) async throws -> Void
        let deleteIndex: ([UUID]) async throws -> Set<UUID>
        let complete: (Set<UUID>) async -> Void
        let end: ([UUID]) -> Void
        let removeCachedImage: (UUID) -> Void
    }

    private let operations: Operations

    init(container: ModelContainer, pipeline: CapturePipeline = .shared) {
        operations = Operations(
            begin: { await pipeline.beginDeletion(rowIDs: $0, assetIDs: $1) },
            deleteAssets: { try await PhotoLibrary.delete(localIdentifiers: $0) },
            deleteIndex: { ids in
                let saver = await PhotoSaver.background(container: container)
                return try await saver.delete(ids: ids)
            },
            complete: { await pipeline.completeDeletion($0) },
            end: { pipeline.endDeletion($0) },
            removeCachedImage: { ImageLoader.shared.removeDiskCache(for: $0) }
        )
    }

    init(operations: Operations) {
        self.operations = operations
    }

    /// nil means a capture is busy; the caller preserves its current presentation.
    func delete(rowIDs: [UUID], assetIDs: [String]) async throws -> Set<UUID>? {
        guard !rowIDs.isEmpty else { return [] }
        guard let gateIDs = await operations.begin(rowIDs, assetIDs) else { return nil }
        defer { operations.end(gateIDs) }
        if !assetIDs.isEmpty { try await operations.deleteAssets(assetIDs) }
        let removedIDs = try await operations.deleteIndex(gateIDs)
        await operations.complete(removedIDs)
        for id in removedIDs { operations.removeCachedImage(id) }
        return removedIDs
    }
}
