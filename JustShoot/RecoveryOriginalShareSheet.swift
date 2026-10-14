import SwiftUI
import UIKit

struct RecoveryOriginalExport: Identifiable {
    let id = UUID()
    let url: URL
}

/// An ordinary file share preserves the exact HEIC/JPEG recovery copy and its metadata.
struct RecoveryOriginalShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        ShareExportDirectory.application.remove(files: [coordinator.url])
    }

    final class Coordinator {
        let url: URL
        init(url: URL) { self.url = url }
    }
}
