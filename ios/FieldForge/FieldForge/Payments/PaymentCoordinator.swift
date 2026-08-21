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

    private let applePay: ApplePayProvider
    private let tapToPay: TapToPayProvider
    private let reachability: Reachability

    init(reachability: Reachability, tapToPayBackend: TapToPayBackend = TapToPayUnavailableBackend()) {
        self.reachability = reachability
        self.applePay = ApplePayProvider(reachability: reachability)
        self.tapToPay = TapToPayProvider(reachability: reachability, backend: tapToPayBackend)
    }

    // MARK: Options

    /// Electronic methods first when they work, manual methods first when they
    /// do not. The ordering is the feature: a staffer with no signal should not
    /// have to scroll past two dead buttons to reach "Cash".
    var methodOptions: [MethodOption] {
        let electronic = [
            MethodOption(method: .tapToPay, unavailableReason: tapToPay.availability()),
            MethodOption(method: .applePay, unavailableReason: applePay.availability()),
        ]
        let manual = GiftMethod.offlineCapable.map {
            MethodOption(method: $0, unavailableReason: nil)
        }
        let anyElectronicWorks = electronic.contains(where: \.isEnabled)
        return anyElectronicWorks ? electronic + manual : manual + electronic
    }

    /// Whether to show the "no signal — cash and cheques still work" banner.
    var shouldShowOfflineReassurance: Bool { !reachability.isOnline }

    var isSimulatingPayments: Bool { PaymentGatewayRegistry.shared.isSimulated }

    // MARK: Collect

    func collect(method: GiftMethod, request: PaymentRequest) async -> PaymentOutcome {
        inFlightMethod = method
        lastFailure = nil
        defer { inFlightMethod = nil }

        let provider: any PaymentProvider
        switch method {
        case .applePay: provider = applePay
        case .tapToPay: provider = tapToPay
        default: provider = ManualPaymentProvider(method: method)
        }

        let outcome = await provider.collect(request)
        if case .failed(let failure) = outcome {
            lastFailure = failure
            AppLog.payments.error("Payment failed via \(method.rawValue, privacy: .public): \(failure.diagnosticCode, privacy: .public)")
        }
        return outcome
    }

    /// Warms the card reader at the start of a route.
    func prepareForRoute() async {
        await tapToPay.prepareIfPossible()
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
        draft.isPaymentConfirmed = receipt.isSettled
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

    /// Builds the request from a draft plus the organization.
    func request(for draft: DocumentDraft, organization: Organization) -> PaymentRequest {
        PaymentRequest(
            amount: draft.amount,
            summaryLabel: "Donation to \(organization.name.trimmedOrNil ?? "our organization")",
            merchantName: organization.printableLegalName,
            fundName: draft.fundName.trimmedOrNil ?? organization.defaultFundName
        )
    }
}
