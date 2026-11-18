import Foundation

/// Unconfigured destinations stay out of Settings. Supply real values through
/// OOOAppStoreID / OOOFeedbackEmail in the app's Info configuration. The legacy
/// keys remain valid for existing build configurations.
struct AppSupportLinks {
    let reviewURL: URL?
    let feedbackURL: URL?

    init(info: [String: Any]) {
        reviewURL = Self.reviewURL(id: info["OOOAppStoreID"] as? String)
            ?? Self.reviewURL(id: info["JustShootAppStoreID"] as? String)
        feedbackURL = Self.feedbackURL(email: info["OOOFeedbackEmail"] as? String)
            ?? Self.feedbackURL(email: info["JustShootFeedbackEmail"] as? String)
    }

    private static func reviewURL(id: String?) -> URL? {
        guard let appID = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              appID.allSatisfy(\.isNumber), let number = UInt64(appID), number > 0 else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }

    private static func feedbackURL(email value: String?) -> URL? {
        guard let email = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].lowercased().hasSuffix("example.com"),
              !email.contains(where: { $0.isWhitespace || "?&#/".contains($0) }) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: "OOO Feedback")]
        return components.url
    }
}
