import Foundation

/// Unconfigured destinations stay out of Settings. Supply real values through
/// JustShootAppStoreID / JustShootFeedbackEmail in the app's Info configuration.
struct AppSupportLinks {
    let reviewURL: URL?
    let feedbackURL: URL?

    init(info: [String: Any]) {
        let appID = (info["JustShootAppStoreID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !appID.isEmpty, appID.allSatisfy(\.isNumber), let number = UInt64(appID), number > 0 {
            reviewURL = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
        } else {
            reviewURL = nil
        }
        let email = (info["JustShootFeedbackEmail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
           !parts[1].lowercased().hasSuffix("example.com"),
           !email.contains(where: { $0.isWhitespace || "?&#/".contains($0) }) {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = email
            components.queryItems = [URLQueryItem(name: "subject", value: "JustShoot Feedback")]
            feedbackURL = components.url
        } else {
            feedbackURL = nil
        }
    }
}
