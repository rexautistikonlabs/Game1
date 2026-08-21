//
//  ApplePayProvider.swift
//  FieldForge
//
//  Apple Pay via PassKit, wrapped so the capture flow can `await` a payment.
//
//  The delegate dance is the awkward part of PassKit: authorisation arrives on
//  a delegate callback, the processor charge has to complete before the sheet
//  can show its tick, and the sheet's dismissal is a separate callback again.
//  All of that is contained here behind a single async function.
//

import Foundation
import PassKit

@MainActor
final class ApplePayProvider: NSObject, PaymentProvider {

    let method: GiftMethod = .applePay

    /// Networks worth accepting for donations. Deliberately broad — a donor
    /// holding a Discover card should not be turned away.
    private let supportedNetworks: [PKPaymentNetwork] = [
        .visa, .masterCard, .amex, .discover, .maestro, .interac, .cartesBancaires, .JCB,
    ]

    /// Three-D Secure is the baseline capability every processor supports.
    private let merchantCapabilities: PKMerchantCapability = [.threeDSecure, .credit, .debit]

    private var continuation: CheckedContinuation<PaymentOutcome, Never>?
    private var pendingRequest: PaymentRequest?
    /// Set on the authorisation callback, read when the sheet finishes.
    fileprivate var resolvedOutcome: PaymentOutcome?
    private var controller: PKPaymentAuthorizationController?

    private let reachability: Reachability
    private let registry: PaymentGatewayRegistry

    init(reachability: Reachability, registry: PaymentGatewayRegistry = .shared) {
        self.reachability = reachability
        self.registry = registry
        super.init()
    }

    // MARK: Availability

    /// Checked before the button is drawn. Each case has a specific,
    /// actionable explanation — "not available" on its own is useless to a
    /// staffer standing in a shop.
    func availability() -> PaymentUnavailableReason? {
        guard registry.canChargeCards else { return .merchantNotConfigured }
        guard reachability.isOnline else { return .offline }
        guard PKPaymentAuthorizationController.canMakePayments() else { return .applePayNotSetUp }
        // `canMakePayments(usingNetworks:)` is the stricter check: the device
        // supports Apple Pay *and* has a usable card provisioned.
        guard PKPaymentAuthorizationController.canMakePayments(usingNetworks: supportedNetworks) else {
            return .applePayNotSetUp
        }
        return nil
    }

    // MARK: Collect

    func collect(_ request: PaymentRequest) async -> PaymentOutcome {
        if let reason = availability() { return .unavailable(reason) }
        guard request.amount.isPositive else {
            return .failed(PaymentFailure(
                message: "Enter an amount before taking a payment.",
                isRetryable: false,
                diagnosticCode: "zero-amount"
            ))
        }
        // Two sheets at once is a PassKit crash. Refuse rather than race.
        guard continuation == nil else {
            return .failed(PaymentFailure(
                message: "A payment is already in progress.",
                isRetryable: true,
                diagnosticCode: "reentrant"
            ))
        }

        let paymentRequest = makePaymentRequest(from: request)
        let controller = PKPaymentAuthorizationController(paymentRequest: paymentRequest)
        controller.delegate = self
        self.controller = controller
        self.pendingRequest = request
        self.resolvedOutcome = nil

        return await withCheckedContinuation { (continuation: CheckedContinuation<PaymentOutcome, Never>) in
            self.continuation = continuation
            controller.present { presented in
                guard !presented else { return }
                // The sheet never appeared, so `didFinish` will never fire.
                Task { @MainActor in
                    self.finish(with: .unavailable(.applePayNotSetUp))
                }
            }
        }
    }

    private func makePaymentRequest(from request: PaymentRequest) -> PKPaymentRequest {
        let paymentRequest = PKPaymentRequest()
        paymentRequest.merchantIdentifier = registry.merchantIdentifier
        paymentRequest.merchantCapabilities = merchantCapabilities
        paymentRequest.supportedNetworks = supportedNetworks
        paymentRequest.countryCode = Locale.current.region?.identifier ?? "US"
        paymentRequest.currencyCode = request.amount.currencyCode

        // Asking for the email is what makes "receipt sent before they walk
        // away" possible, so it is on by default.
        if request.requestsPayerContact {
            paymentRequest.requiredShippingContactFields = [.emailAddress, .name]
        }
        if request.requestsBillingAddress {
            paymentRequest.requiredBillingContactFields = [.postalAddress, .name]
        }

        // One summary item. The last item is the total, per PassKit's contract.
        paymentRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: request.summaryLabel,
                amount: NSDecimalNumber(decimal: request.amount.decimalValue),
                type: .final
            )
        ]
        return paymentRequest
    }

    // MARK: Completion plumbing

    fileprivate func finish(with outcome: PaymentOutcome) {
        controller?.delegate = nil
        controller = nil
        pendingRequest = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

// MARK: - PKPaymentAuthorizationControllerDelegate

extension ApplePayProvider: PKPaymentAuthorizationControllerDelegate {

    /// The token has arrived. Charge it, and only then tell the sheet to show
    /// its tick — a green tick before the money moves is a lie the donor sees.
    /// `nonisolated` plus `assumeIsolated`: PassKit declares these callbacks
    /// without actor isolation but always delivers them on the main thread, and
    /// this is the documented way to bridge that without a hop that would let
    /// the sheet finish before we have recorded the outcome.
    nonisolated func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        MainActor.assumeIsolated {
            authorize(payment: payment, completion: completion)
        }
    }

    private func authorize(
        payment: PKPayment,
        completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        guard let request = pendingRequest else {
            completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
            resolvedOutcome = .failed(PaymentFailure(
                message: "The payment could not be matched to a gift.",
                isRetryable: true,
                diagnosticCode: "lost-request"
            ))
            return
        }

        let network = payment.token.paymentMethod.network?.rawValue ?? ""
        let instrument = payment.token.paymentMethod.displayName ?? network
        let payerName = [
            payment.shippingContact?.name?.givenName,
            payment.shippingContact?.name?.familyName,
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let chargeRequest = ProcessorChargeRequest(
            amountMinorUnits: request.amount.minorUnits,
            currencyCode: request.amount.currencyCode,
            paymentData: payment.token.paymentData,
            network: network,
            instrumentDescription: instrument,
            transactionIdentifier: payment.token.transactionIdentifier,
            payerName: payerName,
            payerEmail: payment.shippingContact?.emailAddress ?? "",
            fundName: request.fundName,
            organizationName: request.merchantName,
            // PassKit's transaction identifier is stable for this
            // authorisation, which makes it exactly the right idempotency key.
            idempotencyKey: payment.token.transactionIdentifier
        )

        let gateway = registry.gateway
        Task { @MainActor in
            do {
                let result = try await gateway.charge(chargeRequest)
                let receipt = PaymentReceipt(
                    amount: request.amount,
                    transactionIdentifier: result.processorTransactionID,
                    instrumentDescription: result.instrumentDescription ?? instrument,
                    payerName: payerName,
                    payerEmail: payment.shippingContact?.emailAddress ?? "",
                    payerPhone: payment.shippingContact?.phoneNumber?.stringValue ?? "",
                    authorizedAt: .now,
                    method: .applePay,
                    isSettled: result.isSettled
                )
                self.resolvedOutcome = .captured(receipt)
                completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
            } catch let error as ProcessorError {
                AppLog.payments.error("Charge failed: \(error.diagnosticName, privacy: .public)")
                self.resolvedOutcome = .failed(PaymentFailure(
                    message: error.localizedDescription,
                    isRetryable: error.isRetryable,
                    diagnosticCode: error.diagnosticName
                ))
                completion(PKPaymentAuthorizationResult(status: .failure, errors: [error]))
            } catch {
                self.resolvedOutcome = .failed(PaymentFailure(
                    message: error.localizedDescription,
                    isRetryable: true,
                    diagnosticCode: "unknown"
                ))
                completion(PKPaymentAuthorizationResult(status: .failure, errors: [error]))
            }
        }
    }

    nonisolated func paymentAuthorizationControllerDidFinish(
        _ controller: PKPaymentAuthorizationController
    ) {
        controller.dismiss {
            MainActor.assumeIsolated {
                // No resolved outcome means the sheet was dismissed without an
                // authorisation — the staffer or the donor backed out.
                self.finish(with: self.resolvedOutcome ?? .cancelled)
            }
        }
    }
}

extension ProcessorError {
    /// Short, loggable name. Never includes a processor message, which could
    /// contain donor detail.
    var diagnosticName: String {
        switch self {
        case .notConfigured: return "not-configured"
        case .declined: return "declined"
        case .network: return "network"
        case .server(let status, _): return "server-\(status)"
        case .malformedResponse: return "malformed"
        }
    }
}
