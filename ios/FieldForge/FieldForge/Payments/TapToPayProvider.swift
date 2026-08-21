//
//  TapToPayProvider.swift
//  FieldForge
//
//  Tap to Pay on iPhone — accepting a physical contactless card on the phone
//  itself, with no dongle.
//
//  Read this before wiring it up, because it is the single most misunderstood
//  capability in this app:
//
//  1. It needs the `com.apple.developer.proximity-reader.payment.acceptance`
//     entitlement, which Apple grants by request to organizations working with
//     a supported payment platform. It is not available by simply ticking a box
//     in Xcode, and a build that declares it without the grant fails to sign.
//
//  2. The reader session is driven by the *payment platform's* SDK (Stripe
//     Terminal, Adyen, Square, Shopify and others), not by Apple's framework
//     alone. `ProximityReader` handles the device-side reader; the platform SDK
//     handles discovery, the connection token, and the actual charge.
//
//  3. Requirements: iPhone XS or later, iOS 16.4+, and a one-time on-device
//     provisioning step per phone that needs a network.
//
//  4. It never works offline. No card network authorises without a connection.
//
//  So this file does two real things: it reports availability precisely enough
//  for the UI to explain itself, and it defines the narrow protocol a payment
//  platform SDK plugs into. Everything compiles and behaves sensibly with no
//  entitlement and no SDK — it reports `.tapToPayEntitlementMissing` and the
//  capture flow routes the staffer to Apple Pay or a manual record.
//

import Foundation
import UIKit

#if canImport(ProximityReader)
import ProximityReader
#endif

/// What a payment platform SDK must provide for Tap to Pay to work.
///
/// Deliberately tiny. An integration is: conform a wrapper around the vendor's
/// SDK to this, register it at launch, done.
protocol TapToPayBackend: Sendable {
    /// Whether the vendor SDK is present, authenticated, and this phone has
    /// completed reader provisioning.
    func isReady() async -> Bool
    /// Prepares the reader. Slow the first time on a given phone (Apple's
    /// one-off provisioning), fast afterwards.
    func prepareReader() async throws
    /// Presents the system tap UI and returns once the card is charged.
    func collect(amountMinorUnits: Int, currencyCode: String, reference: String) async throws -> ProcessorChargeResult
}

/// No SDK linked. Reports honestly and never pretends.
struct TapToPayUnavailableBackend: TapToPayBackend {
    struct NotIntegrated: LocalizedError {
        var errorDescription: String? {
            "Tap to Pay is not integrated in this build. Use Apple Pay or record the payment manually."
        }
    }

    func isReady() async -> Bool { false }
    func prepareReader() async throws { throw NotIntegrated() }
    func collect(amountMinorUnits: Int, currencyCode: String, reference: String) async throws -> ProcessorChargeResult {
        throw NotIntegrated()
    }
}

@MainActor
final class TapToPayProvider: PaymentProvider {

    let method: GiftMethod = .tapToPay

    private let reachability: Reachability
    private let backend: TapToPayBackend
    /// Cached across calls: provisioning is expensive and only needs doing once
    /// per phone, and repeating the check at every door would be rude to the
    /// battery.
    private var readerPrepared = false
    private var cachedBackendReady: Bool?

    init(reachability: Reachability, backend: TapToPayBackend = TapToPayUnavailableBackend()) {
        self.reachability = reachability
        self.backend = backend
    }

    // MARK: Availability

    /// Whether this build carries the Tap to Pay entitlement.
    ///
    /// Driven by a compile-time flag rather than sniffed at runtime, on purpose.
    /// iOS gives an app no reliable public way to read its own entitlements, and
    /// the entitlement is a build-time fact anyway. Once Apple grants it:
    ///
    ///   1. uncomment the key in `FieldForge.entitlements`, and
    ///   2. add `-D TAP_TO_PAY_ENABLED` to `OTHER_SWIFT_FLAGS` (or set
    ///      `SWIFT_ACTIVE_COMPILATION_CONDITIONS = TAP_TO_PAY_ENABLED`).
    ///
    /// Until then the button is drawn disabled with an accurate explanation
    /// rather than failing on tap.
    static var isEntitled: Bool {
        #if TAP_TO_PAY_ENABLED
        return true
        #else
        return false
        #endif
    }

    /// Device support, independent of entitlement. Tap to Pay needs a Secure
    /// Element and an NFC reader configuration only present on iPhone XS and
    /// later.
    static var isDeviceCapable: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif canImport(ProximityReader)
        // `PaymentCardReader.isSupported` is the authoritative check and does
        // not require the entitlement to read.
        return PaymentCardReader.isSupported
        #else
        return false
        #endif
    }

    func availability() -> PaymentUnavailableReason? {
        guard Self.isDeviceCapable else { return .tapToPayUnsupportedDevice }
        guard Self.isEntitled else { return .tapToPayEntitlementMissing }
        guard reachability.isOnline else { return .offline }
        if cachedBackendReady == false { return .tapToPayNotProvisioned }
        return nil
    }

    /// Warms up the reader so the first tap of the day is not the slow one.
    /// Call from the Today screen when the staffer starts a route.
    func prepareIfPossible() async {
        guard availability() == nil, !readerPrepared else { return }
        let ready = await backend.isReady()
        cachedBackendReady = ready
        guard ready else { return }
        do {
            try await backend.prepareReader()
            readerPrepared = true
            AppLog.payments.info("Tap to Pay reader prepared")
        } catch {
            AppLog.payments.error("Reader preparation failed: \(error.localizedDescription, privacy: .public)")
        }
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

        let ready = await backend.isReady()
        cachedBackendReady = ready
        guard ready else { return .unavailable(.tapToPayNotProvisioned) }

        if !readerPrepared {
            do {
                try await backend.prepareReader()
                readerPrepared = true
            } catch {
                return .failed(PaymentFailure(
                    message: error.localizedDescription,
                    isRetryable: true,
                    diagnosticCode: "reader-prepare"
                ))
            }
        }

        do {
            let result = try await backend.collect(
                amountMinorUnits: request.amount.minorUnits,
                currencyCode: request.amount.currencyCode,
                reference: request.fundName
            )
            return .captured(PaymentReceipt(
                amount: request.amount,
                transactionIdentifier: result.processorTransactionID,
                instrumentDescription: result.instrumentDescription ?? "Contactless card",
                method: .tapToPay,
                isSettled: result.isSettled
            ))
        } catch let error as ProcessorError {
            return .failed(PaymentFailure(
                message: error.localizedDescription,
                isRetryable: error.isRetryable,
                diagnosticCode: error.diagnosticName
            ))
        } catch {
            // A cancelled tap arrives as an error from most vendor SDKs. Treat
            // a cancellation as a cancellation, not a failure to apologise for.
            if (error as NSError).code == NSUserCancelledError {
                return .cancelled
            }
            return .failed(PaymentFailure(
                message: error.localizedDescription,
                isRetryable: true,
                diagnosticCode: "tap-to-pay"
            ))
        }
    }
}
