//
//  StoreService.swift
//  FieldForge
//
//  StoreKit 2. Subscriptions for the Team tier, and a transaction listener that
//  keeps `Entitlements` current.
//
//  Design notes:
//
//    * A monthly and an annual subscription, plus a deliberately cheap
//      "small organization" tier. Nonprofits have real budget constraints and
//      an annual price that reads as a rounding error to a SaaS company is a
//      board conversation to a food pantry.
//    * Nothing blocks on the store. If StoreKit never answers, the cached tier
//      stands and the app is fully usable.
//    * Restore is always available and never hidden behind a menu.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreService {

    /// Product identifiers. These must match App Store Connect and the local
    /// `Products.storekit` file used for testing.
    enum ProductID {
        static let teamMonthly = "org.example.fieldforge.team.monthly"
        static let teamAnnual = "org.example.fieldforge.team.annual"
        static let teamAnnualSmallOrg = "org.example.fieldforge.team.annual.small"

        static var all: [String] { [teamMonthly, teamAnnual, teamAnnualSmallOrg] }
    }

    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var purchaseInFlight: String?
    private(set) var lastErrorMessage: String?

    /// True once `loadProducts` has completed, successfully or not, so the
    /// paywall can distinguish "loading" from "the store is unreachable".
    private(set) var hasAttemptedLoad = false

    private let entitlements: Entitlements
    private var updateListener: Task<Void, Never>?

    init(entitlements: Entitlements) {
        self.entitlements = entitlements
        // Start listening before anything else: a purchase completed on another
        // device, or interrupted last launch, arrives through here.
        updateListener = makeTransactionListener()
    }

    deinit {
        updateListener?.cancel()
    }

    // MARK: Products

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer {
            isLoadingProducts = false
            hasAttemptedLoad = true
        }
        do {
            let loaded = try await Product.products(for: ProductID.all)
            // Cheapest first, so the affordable option is not buried.
            products = loaded.sorted { $0.price < $1.price }
            lastErrorMessage = nil
        } catch {
            AppLog.store.error("Could not load products: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "Could not reach the App Store. Everything you already have keeps working."
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    // MARK: Purchase

    enum PurchaseResult {
        case success
        case cancelled
        case pending
        case failed(String)
    }

    func purchase(_ product: Product) async -> PurchaseResult {
        purchaseInFlight = product.id
        defer { purchaseInFlight = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard let transaction = verified(verification) else {
                    return .failed("That purchase could not be verified. Nothing was charged.")
                }
                await refreshEntitlements()
                await transaction.finish()
                Haptics.success()
                return .success

            case .userCancelled:
                return .cancelled

            case .pending:
                // Ask to Buy, or a payment needing approval. The purchase may
                // complete later and arrive through the update listener.
                return .pending

            @unknown default:
                return .failed("The App Store returned something unexpected.")
            }
        } catch {
            AppLog.store.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Restores by re-reading current entitlements. `AppStore.sync()` is only
    /// used on explicit user request, because it can prompt for a password.
    func restorePurchases() async -> Bool {
        entitlements.setRefreshing(true)
        defer { entitlements.setRefreshing(false) }
        do {
            try await AppStore.sync()
        } catch {
            AppLog.store.info("AppStore.sync failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshEntitlements()
        return entitlements.isPro
    }

    // MARK: Entitlement refresh

    /// Reads `Transaction.currentEntitlements` and updates the cached tier.
    func refreshEntitlements() async {
        entitlements.setRefreshing(true)
        defer { entitlements.setRefreshing(false) }

        var highestTier: Tier = .free
        var expiry: Date?
        var sawAnyTransaction = false

        for await result in Transaction.currentEntitlements {
            guard let transaction = verified(result) else { continue }
            sawAnyTransaction = true
            guard ProductID.all.contains(transaction.productID) else { continue }
            // A revoked or expired transaction is not an entitlement.
            if let revocation = transaction.revocationDate, revocation <= .now { continue }
            if let expiration = transaction.expirationDate, expiration <= .now { continue }

            highestTier = .team
            if let expiration = transaction.expirationDate {
                expiry = max(expiry ?? expiration, expiration)
            }
        }

        // No transactions at all is ambiguous — it can mean "never bought" or
        // "StoreKit could not reach the store". `Entitlements.apply` handles
        // that by refusing to downgrade without an expiry date.
        if highestTier == .free, !sawAnyTransaction {
            AppLog.store.info("No transactions visible; leaving the cached tier alone")
            return
        }
        entitlements.apply(tier: highestTier, validUntil: expiry)
    }

    // MARK: Plumbing

    /// Unwraps a verification result, discarding anything unverified. An
    /// unverified transaction is treated as absent, never as a grant.
    private func verified<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            AppLog.store.error("Unverified transaction: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Long-lived listener for transactions arriving outside a purchase call:
    /// a renewal, a purchase made on another device, an Ask to Buy approval, or
    /// one interrupted by a crash last launch. Without this, a paying customer
    /// can end up on the free tier through no fault of their own.
    ///
    /// `Task {}` rather than `Task.detached`, so it inherits this class's main
    /// actor and can touch `entitlements` directly.
    private func makeTransactionListener() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                guard let transaction = self.verified(update) else { continue }
                await self.refreshEntitlements()
                await transaction.finish()
            }
        }
    }

    // MARK: Display helpers

    /// "$8.99 / month" — locale-correct, from StoreKit's own formatting.
    func priceDescription(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return product.displayPrice
        }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "\(period.value) days"
        case .week: unit = period.value == 1 ? "week" : "\(period.value) weeks"
        case .month: unit = period.value == 1 ? "month" : "\(period.value) months"
        case .year: unit = period.value == 1 ? "year" : "\(period.value) years"
        @unknown default: unit = "period"
        }
        return "\(product.displayPrice) / \(unit)"
    }

    /// Monthly equivalent of an annual plan, so the saving is legible without
    /// arithmetic.
    func monthlyEquivalent(for product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod,
              period.unit == .year else { return nil }
        let months = Decimal(12 * period.value)
        guard months > 0 else { return nil }
        let perMonth = product.price / months
        return perMonth.formatted(.currency(code: product.priceFormatStyle.currencyCode))
            + " / month"
    }

    var hasIntroductoryOffer: Bool {
        products.contains { $0.subscription?.introductoryOffer != nil }
    }
}
