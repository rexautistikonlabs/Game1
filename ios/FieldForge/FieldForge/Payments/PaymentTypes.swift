//
//  PaymentTypes.swift
//  FieldForge
//
//  The vocabulary of taking money in the field, and an honest account of what
//  an iOS app can and cannot do on its own.
//
//  What Apple actually provides:
//
//    * Apple Pay (PassKit) gives you an encrypted payment token. It is not
//      money. A payment processor has to turn that token into a settled
//      transaction, which means an account with Stripe, Braintree, Square,
//      Adyen or similar, and a merchant identifier from Apple. That exchange
//      needs a network.
//
//    * Tap to Pay on iPhone (ProximityReader) reads a physical card or a
//      contactless device. It requires a special entitlement granted by Apple
//      on request, a supported payment-platform SDK, iPhone XS or later, and
//      iOS 16.4+. It cannot be used without a processor either.
//
//    * Neither works offline. Card networks do not authorise without a network.
//
//  So this layer is built around one rule: an electronic payment either clears
//  or it does not exist. A failed or unreachable payment falls back to a
//  manual record — cash, cheque, or "card taken on the reader" — and the
//  document engine refuses to issue a tax acknowledgment for money that has not
//  actually arrived.
//

import Foundation
import PassKit

/// The outcome of asking for money.
enum PaymentOutcome: Equatable {
    /// Money is authorised or settled. Safe to issue a receipt.
    case captured(PaymentReceipt)
    /// The staffer backed out. Not an error; do not show one.
    case cancelled
    /// The attempt failed for a reason worth explaining and possibly retrying.
    case failed(PaymentFailure)
    /// Electronic capture is impossible right now — offline, unsupported
    /// device, missing entitlement. The UI offers the manual path instead.
    case unavailable(PaymentUnavailableReason)
}

/// What a cleared payment tells us. Only fields a receipt legitimately needs;
/// no card numbers, ever.
struct PaymentReceipt: Equatable {
    var amount: Money
    /// Processor transaction identifier, or the PassKit transaction identifier
    /// when no processor is wired up yet.
    var transactionIdentifier: String
    /// "Visa 4242" — network plus last four, which is all PassKit exposes.
    var instrumentDescription: String
    /// Cardholder or Apple Pay account name, when the network provides it.
    var payerName: String
    var payerEmail: String
    var payerPhone: String
    var authorizedAt: Date
    var method: GiftMethod
    /// True when a processor confirmed settlement rather than the app merely
    /// receiving a token. Drives `Gift.isPaymentConfirmed`.
    var isSettled: Bool

    init(
        amount: Money,
        transactionIdentifier: String = "",
        instrumentDescription: String = "",
        payerName: String = "",
        payerEmail: String = "",
        payerPhone: String = "",
        authorizedAt: Date = .now,
        method: GiftMethod = .applePay,
        isSettled: Bool = false
    ) {
        self.amount = amount
        self.transactionIdentifier = transactionIdentifier
        self.instrumentDescription = instrumentDescription
        self.payerName = payerName
        self.payerEmail = payerEmail
        self.payerPhone = payerPhone
        self.authorizedAt = authorizedAt
        self.method = method
        self.isSettled = isSettled
    }
}

struct PaymentFailure: Equatable, LocalizedError {
    /// Shown to the staffer. Written to be readable at a doorstep, not a log.
    var message: String
    /// Whether trying again might work.
    var isRetryable: Bool
    /// Processor or PassKit code, for support conversations.
    var diagnosticCode: String

    var errorDescription: String? { message }

    static let declined = PaymentFailure(
        message: "The card was declined. Ask if they would like to try another card.",
        isRetryable: true,
        diagnosticCode: "declined"
    )

    static let networkLost = PaymentFailure(
        message: "Lost the connection before the payment cleared. Nothing was charged.",
        isRetryable: true,
        diagnosticCode: "network"
    )

    static let processorNotConfigured = PaymentFailure(
        message: "No payment processor is connected yet. Record this as cash, cheque, or card taken elsewhere.",
        isRetryable: false,
        diagnosticCode: "no-processor"
    )
}

/// Why electronic capture is off the table, and what to say about it. Every
/// case here has a manual fallback, which is why none of them are fatal.
enum PaymentUnavailableReason: Equatable {
    case offline
    case applePayNotSetUp
    case merchantNotConfigured
    case tapToPayUnsupportedDevice
    case tapToPayEntitlementMissing
    case tapToPayNotProvisioned

    var explanation: String {
        switch self {
        case .offline:
            return "No connection, so cards cannot be authorised. Take cash or a cheque and it will all be recorded."
        case .applePayNotSetUp:
            return "This iPhone has no cards in Wallet. Record the gift manually instead."
        case .merchantNotConfigured:
            return "Apple Pay is not set up for this organization yet. An admin needs to add a merchant ID."
        case .tapToPayUnsupportedDevice:
            return "Tap to Pay needs iPhone XS or later. Use Apple Pay or record the gift manually."
        case .tapToPayEntitlementMissing:
            return "Tap to Pay is not enabled for this build of the app."
        case .tapToPayNotProvisioned:
            return "This iPhone has not finished Tap to Pay setup. Connect to Wi-Fi and try again."
        }
    }

    /// Short label for the disabled button.
    var shortLabel: String {
        switch self {
        case .offline: return "No signal"
        case .applePayNotSetUp: return "No cards in Wallet"
        case .merchantNotConfigured: return "Not set up"
        case .tapToPayUnsupportedDevice: return "Not supported"
        case .tapToPayEntitlementMissing: return "Not enabled"
        case .tapToPayNotProvisioned: return "Needs setup"
        }
    }
}

/// A request for money, independent of how it is collected.
struct PaymentRequest {
    var amount: Money
    /// Appears on the Apple Pay sheet — "Donation to Riverside Food Collective".
    var summaryLabel: String
    /// Appears as the merchant name. The organization's legal name.
    var merchantName: String
    /// Fund or campaign, passed to the processor as metadata.
    var fundName: String
    /// Whether to ask the payer for contact details on the Apple Pay sheet.
    /// On by default: the email is what lets the receipt be sent, and a donor
    /// who has already tapped is happy to share it.
    var requestsPayerContact: Bool = true
    var requestsBillingAddress: Bool = false
}

/// Common interface for every way of taking money.
@MainActor
protocol PaymentProvider {
    var method: GiftMethod { get }
    /// Checked before the button is drawn, so an unavailable method is
    /// explained rather than failing on tap.
    func availability() -> PaymentUnavailableReason?
    func collect(_ request: PaymentRequest) async -> PaymentOutcome
}
