import Observation
import OSLog
import StoreKit

@MainActor @Observable
final class MembershipStore {
    static let lifetimeProductID = "leavestylecode.JustShoot.membership.lifetime"

    enum Entitlement: Equatable {
        case checking, inactive, unverified
        case active(since: Date)
    }

    enum ProductState {
        case idle, loading, available(Product), unavailable
    }

    enum Operation {
        case purchasing, restoring
    }

    enum Notice {
        case purchaseFailed, verificationFailed, restoreFailed, noPurchases
    }

    private(set) var entitlement = Entitlement.checking
    private(set) var productState = ProductState.idle
    private(set) var operation: Operation?
    private(set) var notice: Notice?
    private(set) var isPurchasePending = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var entitlementReadID = 0
    @ObservationIgnored private var appliedEntitlementReadID = 0

    deinit {
        updatesTask?.cancel()
    }

    var isLifetimeMember: Bool {
        if case .active = entitlement { return true }
        return false
    }

    func startTransactionListener() {
        guard updatesTask == nil else { return }
        updatesTask = Task(priority: .utility) { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                await self.handleTransaction(result)
            }
        }
    }

    func refreshEntitlement() async {
        entitlementReadID += 1
        let readID = entitlementReadID
        let result = await Self.currentEntitlement()
        // A slower snapshot must not overwrite a newer read or a verified purchase.
        guard !Task.isCancelled, readID > appliedEntitlementReadID else { return }
        appliedEntitlementReadID = readID
        setEntitlement(result)
    }

    func loadProduct() async {
        guard !isLifetimeMember else { return }
        if case .loading = productState { return }
        let previousState = productState
        productState = .loading
        do {
            let products = try await Product.products(for: [Self.lifetimeProductID])
            try Task.checkCancellation()
            guard let product = products.first(where: { $0.id == Self.lifetimeProductID && $0.type == .nonConsumable }) else {
                productState = .unavailable
                Log.membership.error("membership_product_unavailable")
                return
            }
            productState = .available(product)
        } catch {
            if Task.isCancelled {
                productState = previousState
            } else {
                productState = .unavailable
                Log.membership.error("membership_product_load_failed error=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func purchase(using confirm: @MainActor (Product) async throws -> Product.PurchaseResult) async {
        guard operation == nil, entitlement == .inactive, AppStore.canMakePayments,
              case .available(let product) = productState else { return }
        operation = .purchasing
        notice = nil
        defer { operation = nil }

        do {
            switch try await confirm(product) {
            case .success(let result):
                await handleTransaction(result)
                if !isLifetimeMember, notice != .verificationFailed { notice = .purchaseFailed }
            case .pending:
                if !isLifetimeMember { isPurchasePending = true }
            case .userCancelled:
                break
            @unknown default:
                if !isLifetimeMember { notice = .purchaseFailed }
            }
        } catch StoreKitError.userCancelled {
            return
        } catch {
            if !isLifetimeMember { notice = .purchaseFailed }
            Log.membership.error("membership_purchase_failed error=\(error.localizedDescription, privacy: .private)")
        }
    }

    func restorePurchases() async {
        guard operation == nil else { return }
        operation = .restoring
        notice = nil
        defer { operation = nil }

        do {
            // AppStore.sync may ask for authentication. Only invoke it from Restore Purchases.
            try await AppStore.sync()
            await refreshEntitlement()
            if entitlement == .inactive, !isPurchasePending { notice = .noPurchases }
        } catch StoreKitError.userCancelled {
            return
        } catch {
            notice = .restoreFailed
            Log.membership.error("membership_restore_failed error=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func handleTransaction(_ result: VerificationResult<Transaction>) async {
        let transaction = result.unsafePayloadValue
        guard Self.isLifetimeTransaction(transaction) else { return }
        guard case .verified = result else {
            if !isLifetimeMember { notice = .verificationFailed }
            Log.membership.error("membership_transaction_unverified")
            return
        }

        if transaction.revocationDate == nil {
            entitlementReadID += 1
            appliedEntitlementReadID = entitlementReadID
            setEntitlement(.active(since: transaction.originalPurchaseDate))
        } else {
            await refreshEntitlement()
        }
        await transaction.finish()
    }

    private func setEntitlement(_ value: Entitlement) {
        guard entitlement != value else { return }
        entitlement = value
        if case .active = value {
            if notice != nil { notice = nil }
            if isPurchasePending { isPurchasePending = false }
        }
    }

    private static func currentEntitlement() async -> Entitlement {
        var entitlement = Entitlement.inactive
        for await result in Transaction.currentEntitlements {
            let transaction = result.unsafePayloadValue
            guard isLifetimeTransaction(transaction), transaction.revocationDate == nil else { continue }
            if case .verified(let verified) = result { return .active(since: verified.originalPurchaseDate) }
            entitlement = .unverified
        }
        return entitlement
    }

    private static func isLifetimeTransaction(_ transaction: Transaction) -> Bool {
        transaction.productID == lifetimeProductID && transaction.productType == .nonConsumable
    }
}
