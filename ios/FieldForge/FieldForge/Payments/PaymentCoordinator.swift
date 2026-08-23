//
//  PaymentCoordinator.swift
//  FieldForge
//
//  One object the capture flow talks to. It picks the right provider, reports
//  which methods are usable right now and why the others are not, and turns a
//  cleared payment into the fields a receipt needs.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class PaymentCoordinator {

    /// Registered Apple Pay merchant ID. Must match FieldForge.entitlements.
    /// Do not use `merchant.org.rexautistikonlabs.fieldforge.app`.
    static let applePayMerchantIdentifier = PaymentGatewayRegistry.defaultMerchantIdentifier

    /// What the method picker draws. Availability is resolved up front so a
    /// disabled option can explain itself instead of failing on tap.
    struct MethodOption: Identifiable {
        let method: GiftMethod
        let unavailableReason: PaymentUnavailableReason?

        var id: String { method.rawValue }
        var isEnabled: Bool { unavailableReason == nil }
    }

    /// Set while a sheet is up, so the UI can disable the amount field and show
    /// a spinner on the right button.
    private(set) var inFlightMethod: GiftMethod?

    /// The last electronic failure, for an inline explanation rather than an
    /// alert the staffer has to dismiss with a donor watching.
    private(set) var lastFailure: PaymentFailure?

    /// Stored so SwiftUI notices Settings flipping SIMULATED off.
    private(set) var isSimulatingPayments: Bool

    private let applePay: ApplePayProvider
    private let tapToPay: TapToPayProvider
    private let reachability: Reachability

    init(reachability: Reachability, tapToPayBackend: TapToPayBackend? = nil) {
        self.reachability = reachability
        self.applePay = ApplePayProvider(reachability: reachability)
        // Unavailable until Collect. Stripe Terminal must not load at launch.
        self.tapToPay = TapToPayProvider(
            reachability: reachability,
            backend: tapToPayBackend
        )
        PaymentGatewayRegistry.shared.applyStripeSettings()
        self.isSimulatingPayments = PaymentGatewayRegistry.shared.isSimulated
    }

    /// Call after Settings writes a backend URL or publishable key.
    func reloadProcessor() {
        PaymentGatewayRegistry.shared.applyStripeSettings()
        isSimulatingPayments = PaymentGatewayRegistry.shared.isSimulated
        // Provider stays constructed so PassKit/Azure PaymentIntent code does
        // not bit-rot; capture never presents it.
        _ = applePay.availability()
    }

    // MARK: Options

    /// Electronic methods first when they work, manual methods first when they
    /// do not. The ordering is the feature: a staffer with no signal should not
    /// have to scroll past two dead buttons to reach "Cash".
    var methodOptions: [MethodOption] {
        let electronic = [
            MethodOption(
                method: .textPayLink,
                unavailableReason: reachability.isOnline ? nil : .offline
            ),
            MethodOption(
                method: .emailPayLink,
                unavailableReason: reachability.isOnline ? nil : .offline
            ),
            MethodOption(method: .tapToPay, unavailableReason: tapToPay.availability()),
        ]
        let manual = GiftMethod.offlineCapable.map {
            MethodOption(method: $0, unavailableReason: nil)
        }
        let anyElectronicWorks = electronic.contains(where: \.isEnabled)
        return anyElectronicWorks ? electronic + manual : manual + electronic
    }

    /// Staff Wallet is not a capture control. Operators must not charge this
    /// iPhone’s Wallet by mistake. Azure PaymentIntent stays; the UI does not call it.
    static let presentsStaffApplePayInCapture = false

    /// Kept for Settings/tests. Capture does not show this button.
    static let staffWalletButtonTitle = "Pay with this iPhone’s Wallet (staff)"

    /// Whether to show the "no signal — cash and cheques still work" banner.
    var shouldShowOfflineReassurance: Bool { !reachability.isOnline }

    /// Text and email pay links talk to Azure only. No pk_ and never sk_ on this iPhone.
    var canCreatePayLink: Bool {
        reachability.isOnline && StripePaymentSettings.shared.createPaymentLinkURL != nil
    }

    // MARK: Collect

    func collect(method: GiftMethod, request: PaymentRequest) async -> PaymentOutcome {
        if inFlightMethod != nil {
            return .failed(PaymentFailure(
                message: "A payment is already in progress.",
                isRetryable: true,
                diagnosticCode: "reentrant"
            ))
        }
        inFlightMethod = method
        lastFailure = nil
        if method == .tapToPay {
            TapToPaySession.markStarted()
        }
        defer {
            inFlightMethod = nil
            if method == .tapToPay {
                TapToPaySession.markFinished()
            }
        }

        let provider: any PaymentProvider
        switch method {
        case .applePay:
            // Capture never presents this. Azure PaymentIntent stays; do not
            // delete the route. Tests and Settings still construct the provider.
            return .failed(PaymentFailure(
                message: "In-person Wallet charge is off. Text or email a pay link so the donor pays on their own phone.",
                isRetryable: false,
                diagnosticCode: "staff-apple-pay-off"
            ))
        case .tapToPay: provider = tapToPay
        case .textPayLink, .emailPayLink:
            return .failed(PaymentFailure(
                message: "Text or email a pay link so the donor pays on their own phone.",
                isRetryable: false,
                diagnosticCode: "text-pay-link"
            ))
        default: provider = ManualPaymentProvider(method: method)
        }

        let outcome = await provider.collect(request)
        if case .failed(let failure) = outcome {
            lastFailure = failure
            AppLog.payments.error("Payment failed via \(method.rawValue, privacy: .public): \(failure.diagnosticCode, privacy: .public)")
        }
        return outcome
    }

    /// Does not initialise Terminal. Collect is the only entry.
    func prepareForRoute() async {}

    /// Cancels an in-flight Tap to Pay collect. Returns immediately so the
    /// What step cannot hang waiting on Stripe.
    func cancelTapToPay() async {
        await tapToPay.cancelCollect()
    }

    /// True when a captured outcome is safe to treat as received.
    static func shouldMarkReceived(_ outcome: PaymentOutcome) -> Bool {
        ApplePaySheetSeam.shouldMarkPaid(outcome)
    }

    // MARK: Applying a result

    /// Writes a cleared payment into the draft. The amount is taken from the
    /// receipt rather than the field, so what the donor was charged and what the
    /// document says can never disagree.
    func apply(_ receipt: PaymentReceipt, to draft: inout DocumentDraft) {
        draft.method = receipt.method
        draft.amountText = receipt.amount.decimalValue.formatted(
            .number.precision(.fractionLength(2)).grouping(.never)
        )
        draft.confirmedTransactionIdentifier = receipt.transactionIdentifier
        draft.confirmedInstrumentDescription = receipt.instrumentDescription
        draft.confirmedPayerName = receipt.payerName
        // Card-like methods are received only after PaymentIntent succeeded.
        if receipt.method.requiresStripeSucceededForLetter {
            draft.isPaymentConfirmed = receipt.isSettled && receipt.paymentIntentStatus == "succeeded"
        } else {
            draft.isPaymentConfirmed = receipt.isSettled
        }
        draft.paymentIntentStatus = receipt.paymentIntentStatus
        draft.giftDate = receipt.authorizedAt

        // A donor who just handed over their email through Apple Pay has
        // volunteered the fastest possible delivery route. Use it.
        if draft.recipientEmail.trimmedOrNil == nil, !receipt.payerEmail.isEmpty {
            draft.recipientEmail = receipt.payerEmail
            draft.shouldEmailDocument = true
        }
        if draft.newContact.name.trimmedOrNil == nil, !receipt.payerName.isEmpty {
            draft.newContact.name = receipt.payerName
            draft.newContact.kind = .individual
        }
        if draft.newContact.email.trimmedOrNil == nil, !receipt.payerEmail.isEmpty {
            draft.newContact.email = receipt.payerEmail
        }
        draft.touch()
    }

    func createPayLink(
        for draft: DocumentDraft,
        organization: Organization,
        contactName: String,
        channel: PayLinkChannel = .sms
    ) async throws -> PayLink {
        guard let createURL = StripePaymentSettings.shared.createPaymentLinkURL else {
            throw ProcessorError.notConfigured
        }
        guard let statusURL = StripePaymentSettings.shared.paymentStatusURL else {
            throw ProcessorError.notConfigured
        }
        let client = StripePaymentLinkClient(createURL: createURL, statusURL: statusURL)
        let amount = draft.amount
        // Channel is part of the key so SMS and email can each mint a session.
        // The gift stores the latest sessionId and status checks that one.
        let key = "\(draft.id.uuidString)-\(amount.minorUnits)-\(channel.rawValue)"
        return try await client.create(
            amountMinorUnits: amount.minorUnits,
            giftID: draft.id,
            contactName: contactName,
            fundName: draft.fundName.trimmedOrNil ?? organization.defaultFundName,
            organizationName: organization.name,
            stripeAccount: StripeConnectAccount.shared.accountID,
            idempotencyKey: key
        )
    }

    func refreshPayLinkStatus(sessionID: String, giftID: UUID) async throws -> PayLinkStatus {
        guard let createURL = StripePaymentSettings.shared.createPaymentLinkURL,
              let statusURL = StripePaymentSettings.shared.paymentStatusURL else {
            throw ProcessorError.notConfigured
        }
        let client = StripePaymentLinkClient(createURL: createURL, statusURL: statusURL)
        return try await client.status(
            sessionID: sessionID,
            giftID: giftID,
            stripeAccount: StripeConnectAccount.shared.accountID
        )
    }

    /// Pay link has been sent. Gift stays unpaid until Stripe reports succeeded.
    /// Sending SMS and email may mint two sessions; this keeps the latest.
    func applyPayLink(_ link: PayLink, to draft: inout DocumentDraft, channel: PayLinkChannel = .sms) {
        draft.method = channel == .email ? .emailPayLink : .textPayLink
        draft.checkoutSessionID = link.sessionID
        draft.paymentLinkURL = link.url.absoluteString
        draft.isPaymentConfirmed = false
        draft.paymentIntentStatus = ""
        draft.touch()
    }

    func apply(_ status: PayLinkStatus, to draft: inout DocumentDraft) {
        if let cents = status.amountMinorUnits, cents > 0 {
            draft.amountText = Money(minorUnits: cents, currencyCode: draft.amount.currencyCode)
                .decimalValue
                .formatted(.number.precision(.fractionLength(2)).grouping(.never))
        }
        if !status.sessionID.isEmpty {
            draft.checkoutSessionID = status.sessionID
        }
        if status.paid {
            if !draft.method.isPayLink {
                draft.method = .textPayLink
            }
            draft.isPaymentConfirmed = true
            draft.paymentIntentStatus = "succeeded"
            if !status.paymentIntentID.isEmpty {
                draft.confirmedTransactionIdentifier = status.paymentIntentID
            }
            draft.confirmedInstrumentDescription = "Pay link"
        } else {
            draft.isPaymentConfirmed = false
            draft.paymentIntentStatus = status.paymentIntentStatus.isEmpty
                ? status.status
                : status.paymentIntentStatus
        }
        draft.touch()
    }

    func apply(_ status: PayLinkStatus, to gift: Gift) {
        if let cents = status.amountMinorUnits, cents > 0 {
            gift.amountMinorUnits = cents
        }
        if !status.sessionID.isEmpty {
            gift.checkoutSessionID = status.sessionID
        }
        if status.paid {
            if !gift.method.isPayLink {
                gift.method = .textPayLink
            }
            gift.isPaymentConfirmed = true
            gift.paymentIntentStatus = "succeeded"
            gift.giftStatus = .received
            if !status.paymentIntentID.isEmpty {
                gift.transactionIdentifier = status.paymentIntentID
            }
            if gift.paymentInstrumentDescription.trimmedOrNil == nil {
                gift.paymentInstrumentDescription = "Pay link"
            }
        } else {
            gift.isPaymentConfirmed = false
            gift.paymentIntentStatus = status.paymentIntentStatus.isEmpty
                ? status.status
                : status.paymentIntentStatus
        }
        gift.touch()
    }

    /// Builds the request from a draft plus the organization.
    func request(for draft: DocumentDraft, organization: Organization) -> PaymentRequest {
        PaymentRequest(
            amount: draft.amount,
            summaryLabel: "Donation to \(organization.name.trimmedOrNil ?? "our organization")",
            merchantName: organization.printableLegalName,
            fundName: draft.fundName.trimmedOrNil ?? organization.defaultFundName,
            stripeAccount: StripeConnectAccount.shared.accountID
        )
    }
}
