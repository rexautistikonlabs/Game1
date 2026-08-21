//
//  ManualPaymentProvider.swift
//  FieldForge
//
//  Cash, cheque, in-kind, pledge, and "they gave me their card details for the
//  office to run".
//
//  This is not a fallback in the apologetic sense. In real outreach it is the
//  majority of gifts, so it is a first-class provider with the same interface
//  as Apple Pay — which means the capture flow has exactly one code path and
//  never treats a $20 bill as a degraded experience.
//

import Foundation

@MainActor
struct ManualPaymentProvider: PaymentProvider {

    let method: GiftMethod

    init(method: GiftMethod = .cash) {
        self.method = method
    }

    /// Always available. That is the entire point: no signal, no reader, no
    /// merchant account, no problem.
    func availability() -> PaymentUnavailableReason? { nil }

    func collect(_ request: PaymentRequest) async -> PaymentOutcome {
        // An in-kind gift legitimately has no amount, so it is not held to the
        // positive-amount rule.
        guard method.isInKind || method == .pledge || request.amount.isPositive else {
            return .failed(PaymentFailure(
                message: "Enter an amount.",
                isRetryable: false,
                diagnosticCode: "zero-amount"
            ))
        }

        // Manual gifts are "settled" in the only sense that matters: the money
        // or the goods are physically in hand. A pledge is explicitly not.
        return .captured(PaymentReceipt(
            amount: request.amount,
            transactionIdentifier: "",
            instrumentDescription: "",
            authorizedAt: .now,
            method: method,
            isSettled: method != .pledge
        ))
    }
}
