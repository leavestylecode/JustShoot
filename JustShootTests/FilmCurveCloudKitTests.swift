import CloudKit
import XCTest
@testable import JustShoot

final class FilmCurveCloudKitTests: XCTestCase {
    func testPrivateDatabaseRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JUSTSHOOT_TEST_CURVE_ICLOUD"] == "1",
                          "Requires a signed-in physical device and a development iCloud container.")
        let prefix = "curve-qa-\(UUID())"
        let writer = CloudKitFilmCurveStorage(recordPrefix: prefix)
        let reader = CloudKitFilmCurveStorage(recordPrefix: prefix)
        print("curve_cloud_roundtrip get account")
        let account = try await writer.accountID()
        let id = try XCTUnwrap(account, "The device needs a signed-in iCloud account.")
        let recordID = CKRecord.ID(recordName: "\(prefix)-\(id)")
        let database = CKContainer.default().privateCloudDatabase
        var curve = CustomFilmCurve(name: "Round trip")
        curve.applyTemplate(.crossProcess)
        let empty = FilmCurveCatalog()
        let local = FilmCurveCatalog(customCurves: [curve], hiddenBuiltInIDs: [CurvePreset.matte.id],
                                     order: [curve.filmCurve.id] + empty.order)
        do {
            print("curve_cloud_roundtrip upload asset")
            let uploaded = try await writer.synchronize(accountID: id, base: empty, local: local)
            print("curve_cloud_roundtrip download asset")
            let downloaded = try await reader.synchronize(accountID: id, base: empty, local: empty)
            XCTAssertEqual(downloaded, uploaded)
            XCTAssertEqual(downloaded, local)
            print("curve_cloud_roundtrip update record")
            let updated = try await writer.synchronize(accountID: id, base: uploaded, local: empty)
            print("curve_cloud_roundtrip refetch record")
            let refreshed = try await reader.synchronize(accountID: id, base: downloaded, local: downloaded)
            XCTAssertEqual(updated, empty)
            XCTAssertEqual(refreshed, empty)
        } catch {
            _ = try? await database.deleteRecord(withID: recordID)
            throw error
        }
        _ = try await database.deleteRecord(withID: recordID)
    }
}
