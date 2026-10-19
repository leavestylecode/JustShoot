import UIKit

/// Start both sources together. A slow thumbnail must not delay a usable full preview.
enum PhotoPageImageLoader {
    @MainActor
    static func load(
        thumbnail: @escaping @MainActor () async -> UIImage?,
        preview: @MainActor () async -> UIImage?,
        onThumbnail: @escaping @MainActor (UIImage) -> Void,
        onPreview: @MainActor (UIImage) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let thumbnailTask = Task { @MainActor in
            let image = await thumbnail()
            guard !Task.isCancelled, let image else { return }
            onThumbnail(image)
        }
        await withTaskCancellationHandler {
            defer { thumbnailTask.cancel() }
            let image = await preview()
            guard !Task.isCancelled else { return }
            if let image {
                onPreview(image)
                thumbnailTask.cancel()
            }
            // Cancellation-aware image requests release this waiter immediately, even
            // when their underlying codec has already started on its blocking queue.
            await thumbnailTask.value
        } onCancel: {
            thumbnailTask.cancel()
        }
    }
}
