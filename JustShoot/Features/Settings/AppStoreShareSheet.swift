import LinkPresentation
import SwiftUI
import UIKit

/// Bridges UIActivityViewController so the share payload stays a single URL
/// (WeChat / QQ accept it) while the preview header still shows our title +
/// app icon via LPLinkMetadata. See `AppStoreShareItemSource`.
struct AppStoreShareSheet: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let subject: String
    let icon: UIImage?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let source = AppStoreShareItemSource(
            url: url,
            title: title,
            subject: subject,
            icon: icon
        )
        return UIActivityViewController(activityItems: [source], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Activity item that exposes the URL as the only shareable payload and
/// attaches an LPLinkMetadata (title + app icon) purely as preview decoration.
private final class AppStoreShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String
    private let subject: String
    private let icon: UIImage?

    init(url: URL, title: String, subject: String, icon: UIImage?) {
        self.url = url
        self.title = title
        self.subject = subject
        self.icon = icon
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let icon {
            let provider = NSItemProvider(object: icon)
            metadata.iconProvider = provider
            metadata.imageProvider = provider
        }
        return metadata
    }
}
