import Foundation

/// Supply OOOAppStoreID and OOOFeedbackEmail in the app's Info configuration.
/// The legacy keys remain valid for existing build configurations.
struct AppSupportLinks {
    private static let projectURL = URL(string: "https://github.com/leavestylecode/JustShoot")!

    let reviewURL: URL?
    let shareURL: URL
    let feedbackURL: URL?

    init(info: [String: Any]) {
        let storeURL = Self.storeURL(id: info["OOOAppStoreID"] as? String)
            ?? Self.storeURL(id: info["JustShootAppStoreID"] as? String)
        reviewURL = storeURL?.appending(queryItems: [URLQueryItem(name: "action", value: "write-review")])
        shareURL = storeURL ?? Self.projectURL
        feedbackURL = Self.feedbackURL(email: info["OOOFeedbackEmail"] as? String)
            ?? Self.feedbackURL(email: info["JustShootFeedbackEmail"] as? String)
    }

    private static func storeURL(id: String?) -> URL? {
        guard let appID = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              appID.allSatisfy(\.isNumber), let number = UInt64(appID), number > 0 else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)")
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
