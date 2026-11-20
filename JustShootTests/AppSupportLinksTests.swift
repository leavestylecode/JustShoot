import XCTest
@testable import JustShoot

final class AppSupportLinksTests: XCTestCase {
    func testUnconfiguredOrPlaceholderStoreIDUsesPublicProjectForSharing() {
        let absent = AppSupportLinks(info: [:])
        XCTAssertNil(absent.reviewURL)
        XCTAssertNil(absent.feedbackURL)
        XCTAssertEqual(absent.shareURL.absoluteString, "https://github.com/leavestylecode/JustShoot")
        let placeholder = AppSupportLinks(info: ["OOOAppStoreID": "0000000000",
            "OOOFeedbackEmail": "feedback@example.com"])
        XCTAssertNil(placeholder.reviewURL)
        XCTAssertNil(placeholder.feedbackURL)
        XCTAssertEqual(placeholder.shareURL, absent.shareURL)
    }

    func testConfiguredDestinationsAreWellFormed() {
        let links = AppSupportLinks(info: ["OOOAppStoreID": "123456789",
            "OOOFeedbackEmail": "support@justshoot.test"])
        XCTAssertEqual(links.reviewURL?.host, "apps.apple.com")
        XCTAssertEqual(links.reviewURL?.path, "/app/id123456789")
        XCTAssertEqual(links.reviewURL?.query, "action=write-review")
        XCTAssertEqual(links.shareURL.absoluteString, "https://apps.apple.com/app/id123456789")
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
        XCTAssertEqual(links.shareURL.absoluteString, "https://apps.apple.com/app/id123456789")
        XCTAssertEqual(links.feedbackURL?.absoluteString, "mailto:old@justshoot.test?subject=OOO%20Feedback")
    }

    func testValidNewValuesTakePrecedenceOverLegacyValues() {
        let links = AppSupportLinks(info: [
            "OOOAppStoreID": "987654321",
            "OOOFeedbackEmail": "new@justshoot.test",
            "JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "old@justshoot.test"
        ])

        XCTAssertEqual(links.reviewURL?.path, "/app/id987654321")
        XCTAssertEqual(links.shareURL.absoluteString, "https://apps.apple.com/app/id987654321")
        XCTAssertEqual(links.feedbackURL?.absoluteString, "mailto:new@justshoot.test?subject=OOO%20Feedback")
    }

    func testInvalidNewValueFallsBackIndependently() {
        let links = AppSupportLinks(info: [
            "OOOAppStoreID": "987654321",
            "OOOFeedbackEmail": "feedback@example.com",
            "JustShootAppStoreID": "123456789",
            "JustShootFeedbackEmail": "old@justshoot.test"
        ])

        XCTAssertEqual(links.reviewURL?.path, "/app/id987654321")
        XCTAssertEqual(links.feedbackURL?.absoluteString, "mailto:old@justshoot.test?subject=OOO%20Feedback")
    }

    func testInvalidAddressesCannotAddRecipientsOrQueryParameters() {
        for email in ["bad", "@test.com", "user@test.com?bcc=other@test.com", "one@test.com\nother@test.com"] {
            XCTAssertNil(AppSupportLinks(info: ["OOOFeedbackEmail": email]).feedbackURL)
        }
    }
}
