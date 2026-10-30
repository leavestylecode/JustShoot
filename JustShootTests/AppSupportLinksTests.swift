import XCTest
@testable import JustShoot

final class AppSupportLinksTests: XCTestCase {
    func testUnconfiguredOrPlaceholderDestinationsAreHidden() {
        let absent = AppSupportLinks(info: [:])
        XCTAssertNil(absent.reviewURL)
        XCTAssertNil(absent.feedbackURL)
        let placeholder = AppSupportLinks(info: ["JustShootAppStoreID": "0000000000",
            "JustShootFeedbackEmail": "feedback@example.com"])
        XCTAssertNil(placeholder.reviewURL)
        XCTAssertNil(placeholder.feedbackURL)
    }

    func testConfiguredDestinationsAreWellFormed() {
        let links = AppSupportLinks(info: ["JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "support@justshoot.test"])
        XCTAssertEqual(links.reviewURL?.host, "apps.apple.com")
        XCTAssertEqual(links.reviewURL?.path, "/app/id123456789")
        XCTAssertEqual(links.feedbackURL?.scheme, "mailto")
        XCTAssertEqual(URLComponents(url: links.feedbackURL!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "subject", value: "JustShoot Feedback")])
    }

    func testInvalidAddressesCannotAddRecipientsOrQueryParameters() {
        for email in ["bad", "@test.com", "user@test.com?bcc=other@test.com", "one@test.com\nother@test.com"] {
            XCTAssertNil(AppSupportLinks(info: ["JustShootFeedbackEmail": email]).feedbackURL)
        }
    }
}
