#if targetEnvironment(simulator)
import StoreKit
import StoreKitTest
import XCTest
@testable import JustShoot

@MainActor
final class MembershipStoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "JustShootProducts", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        // Confirm StoreKit 2 is connected to the local test service before invoking purchase or sync.
        let productID = MembershipStore.lifetimeProductID
        let localPurchase: Transaction
        do {
            localPurchase = try await session.buyProduct(identifier: productID)
        } catch StoreKitError.notEntitled {
            throw XCTSkip("This simulator runtime does not grant access to Xcode’s local StoreKit service.")
        }
        XCTAssertTrue(session.disableDialogs)
        try await waitUntil("StoreKit did not use the local test configuration") {
            guard case .verified(let transaction)? = await Transaction.latest(for: productID) else { return false }
            return transaction.id == localPurchase.id && transaction.environment == .xcode
        }
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session?.resetToDefaultState()
        session = nil
    }

    func testPurchaseActivatesMembershipAndPersistsAcrossStoreInstances() async throws {
        let store = await makeStore()
        guard case .available(let product) = store.productState else {
            return XCTFail("Lifetime membership product was unavailable")
        }
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertFalse(product.displayPrice.isEmpty)
        XCTAssertEqual(store.entitlement, .inactive)

        await store.purchase { try await $0.purchase() }

        guard case .verified(let transaction)? = await Transaction.latest(for: product.id) else {
            return XCTFail("Expected a verified lifetime purchase")
        }
        XCTAssertEqual(store.entitlement, .active(since: transaction.originalPurchaseDate))
        XCTAssertNil(store.notice)
        XCTAssertEqual(session.allTransactions().count, 1)
        await store.purchase { _ in
            XCTFail("A lifetime member should not be prompted to buy again")
            return .userCancelled
        }

        let relaunched = MembershipStore()
        try await waitUntil("Verified entitlement was unavailable to a new store instance") {
            await relaunched.refreshEntitlement()
            return relaunched.isLifetimeMember
        }
        XCTAssertEqual(relaunched.entitlement, store.entitlement)
    }

    func testRestoreReportsMissingPurchaseAndRecoversExistingMembership() async throws {
        let store = MembershipStore()
        await store.restorePurchases()
        XCTAssertEqual(store.entitlement, .inactive)
        XCTAssertEqual(store.notice, .noPurchases)

        let original = try await session.buyProduct(identifier: MembershipStore.lifetimeProductID)
        await store.restorePurchases()

        XCTAssertEqual(store.entitlement, .active(since: original.originalPurchaseDate))
        XCTAssertNil(store.notice)
    }

    func testPendingApprovalAndRefundUpdateMembershipThroughListener() async throws {
        session.askToBuyEnabled = true
        let store = await makeStore()
        await store.purchase { try await $0.purchase() }

        XCTAssertTrue(store.isPurchasePending)
        XCTAssertFalse(store.isLifetimeMember)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        // StoreKit Test may take tens of seconds to deliver Transaction.updates on iOS 18.
        try await waitUntil("Approval did not activate the membership", timeout: .seconds(120)) { store.isLifetimeMember }
        XCTAssertFalse(store.isPurchasePending)
        guard case .verified(let transaction)? = await Transaction.latest(for: MembershipStore.lifetimeProductID) else {
            return XCTFail("Expected a verified transaction after approval")
        }
        XCTAssertEqual(store.entitlement, .active(since: transaction.originalPurchaseDate))

        let approved = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: approved.identifier)
        try await waitUntil("Refund did not revoke the membership", timeout: .seconds(120)) { !store.isLifetimeMember }
        XCTAssertEqual(store.entitlement, .inactive)
    }

    func testCancellationAndPurchaseFailureLeaveMembershipInactive() async {
        let store = await makeStore()
        await store.purchase { _ in .userCancelled }
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.entitlement, .inactive)
        XCTAssertNil(store.operation)

        await store.purchase { _ in
            throw StoreKitError.networkError(URLError(.notConnectedToInternet))
        }

        XCTAssertEqual(store.notice, .purchaseFailed)
        XCTAssertEqual(store.entitlement, .inactive)
        XCTAssertNil(store.operation)
    }

    private func makeStore() async -> MembershipStore {
        let store = MembershipStore()
        store.startTransactionListener()
        await store.refreshEntitlement()
        await store.loadProduct()
        return store
    }

    private func waitUntil(_ message: String, timeout: Duration = .seconds(5), condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        repeat {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        throw NSError(domain: "MembershipStoreKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
