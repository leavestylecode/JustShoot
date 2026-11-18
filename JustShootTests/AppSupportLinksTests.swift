import XCTest
@testable import JustShoot

final class AppSupportLinksTests: XCTestCase {
    func testUnconfiguredOrPlaceholderDestinationsAreHidden() {
        let absent = AppSupportLinks(info: [:])
        XCTAssertNil(absent.reviewURL)
        XCTAssertNil(absent.feedbackURL)
        let placeholder = AppSupportLinks(info: ["OOOAppStoreID": "0000000000",
            "OOOFeedbackEmail": "feedback@example.com"])
        XCTAssertNil(placeholder.reviewURL)
        XCTAssertNil(placeholder.feedbackURL)
    }

    func testConfiguredDestinationsAreWellFormed() {
        let links = AppSupportLinks(info: ["OOOAppStoreID": "123456789",
            "OOOFeedbackEmail": "support@justshoot.test"])
        XCTAssertEqual(links.reviewURL?.host, "apps.apple.com")
        XCTAssertEqual(links.reviewURL?.path, "/app/id123456789")
        XCTAssertEqual(links.feedbackURL?.scheme, "mailto")
        XCTAssertEqual(URLComponents(url: links.feedbackURL!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "subject", value: "OOO Feedback")])
    }

    func testLegacyKeysStillConfigureBothDestinations() {
        let links = AppSupportLinks(info: [
            "JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "old@justshoot.test"
        ])

        XCTAssertEqual(links.reviewURL?.path, "/app/id123456789")
        XCTAssertEqual(links.feedbackURL?.path, "old@justshoot.test")
    }

    func testValidNewValuesTakePrecedenceOverLegacyValues() {
        let links = AppSupportLinks(info: [
            "OOOAppStoreID": "987654321",
            "OOOFeedbackEmail": "new@justshoot.test",
            "JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "old@justshoot.test"
        ])

        XCTAssertEqual(links.reviewURL?.path, "/app/id987654321")
        XCTAssertEqual(links.feedbackURL?.path, "new@justshoot.test")
    }

    func testInvalidNewValueFallsBackIndependently() {
        let links = AppSupportLinks(info: [
            "OOOAppStoreID": "987654321",
            "OOOFeedbackEmail": "feedback@example.com",
            "JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "old@justshoot.test"
        ])

        XCTAssertEqual(links.reviewURL?.path, "/app/id987654321")
        XCTAssertEqual(links.feedbackURL?.path, "old@justshoot.test")
    }

    func testInvalidAddressesCannotAddRecipientsOrQueryParameters() {
        for email in ["bad", "@test.com", "user@test.com?bcc=other@test.com", "one@test.com\nother@test.com"] {
            XCTAssertNil(AppSupportLinks(info: ["OOOFeedbackEmail": email]).feedbackURL)
        }
    }
}
