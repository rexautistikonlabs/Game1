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
    func collect(
        amountMinorUnits: Int,
        currencyCode: String,
        reference: String,
        stripeAccount: String?,
        organizationName: String
    ) async throws -> ProcessorChargeResult
    /// Cancels an in-flight collect, discovery, or confirm. Safe if idle.
    func cancelCollect() async
}

extension TapToPayBackend {
    func cancelCollect() async {}
}

enum TapToPayBackendFactory {
    @MainActor
    static func make() -> TapToPayBackend {
        #if canImport(StripeTerminal)
        return StripeTerminalTapToPayBackend()
        #else
        return TapToPayUnavailableBackend()
        #endif
    }
}

/// No SDK linked, or entitlement missing. Reports honestly and never pretends.
struct TapToPayUnavailableBackend: TapToPayBackend {
    struct NotIntegrated: LocalizedError {
        var errorDescription: String? {
            TapToPayCollectUI.deviceOrEntitlementMessage
        }
    }

    func isReady() async -> Bool { false }
    func prepareReader() async throws { throw NotIntegrated() }
    func collect(
        amountMinorUnits: Int,
        currencyCode: String,
        reference: String,
        stripeAccount: String?,
        organizationName: String
    ) async throws -> ProcessorChargeResult {
        throw NotIntegrated()
    }
    func cancelCollect() async {}
}

@MainActor
final class TapToPayProvider: PaymentProvider {

    let method: GiftMethod = .tapToPay

    private let reachability: Reachability
    private var backend: TapToPayBackend
    /// When tests inject a backend, Collect must not replace it.
    private let usesInjectedBackend: Bool

    init(reachability: Reachability, backend: TapToPayBackend? = nil) {
        self.reachability = reachability
        if let backend {
            self.backend = backend
            self.usesInjectedBackend = true
        } else {
            self.backend = TapToPayUnavailableBackend()
            self.usesInjectedBackend = false
        }
    }

    /// Stripe Terminal is constructed here, never at launch, and never while
    /// Settings → Payments has Tap to Pay off.
    func ensureLiveBackendIfNeeded() {
        guard !usesInjectedBackend else { return }
        guard Self.isTurnedOnInSettings else { return }
        if backend is TapToPayUnavailableBackend {
            backend = TapToPayBackendFactory.make()
        }
    }

    /// The ship-off switch. False means no code path may reach `StripeTerminal`.
    static var isTurnedOnInSettings: Bool {
        StripePaymentSettings.shared.isTapToPayEnabled
    }

    static var turnedOffFailure: PaymentFailure {
        PaymentFailure(
            message: TapToPayCollectUI.turnedOffMessage,
            isRetryable: false,
            diagnosticCode: TapToPayCollectUI.turnedOffCode
        )
    }

    // MARK: Availability

    /// Whether this build's signature carries Tap to Pay *and* Stripe Terminal
    /// is linked. Never inferred from a compile flag alone: calling Terminal
    /// or ProximityReader payment APIs without the Apple grant can crash, so
    /// this is a runtime read of the signed entitlement.
    static var isEntitled: Bool {
        TapToPayEntitlement.canAcceptContactlessOnThisBuild
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

    /// Simulator or a build whose profile lacks Apple's grant. Collect must
    /// refuse with `TapToPayCollectUI.deviceOrEntitlementMessage` and must
    /// never call Stripe Terminal / ProximityReader payment APIs.
    static var shouldRefuseCollectOnThisRuntime: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return !canAcceptContactless
        #endif
    }

    static var canAcceptContactless: Bool {
        TapToPayEntitlement.canAcceptContactlessOnThisBuild
    }

    static var deviceOrEntitlementFailure: PaymentFailure {
        PaymentFailure(
            message: TapToPayCollectUI.deviceOrEntitlementMessage,
            isRetryable: false,
            diagnosticCode: TapToPayCollectUI.deviceOrEntitlementCode
        )
    }

    func availability() -> PaymentUnavailableReason? {
        // Off by default. The tile is disabled and explains itself rather than
        // failing on tap, and nothing here loads Stripe Terminal.
        if !usesInjectedBackend && !StripePaymentSettings.shared.isTapToPayEnabled {
            return .tapToPayTurnedOff
        }
        // The tile stays selectable. Collect is what starts Terminal — or
        // shows the registered-iPhone alert on Simulator / a missing grant.
        // Offline still disables: no card network authorises without a route.
        guard reachability.isOnline else { return .offline }
        return nil
    }

    func cancelCollect() async {
        await backend.cancelCollect()
    }

    /// Collect initialises Terminal. Route / launch must not.
    func prepareIfPossible() async {}

    // MARK: Collect

    func collect(_ request: PaymentRequest) async -> PaymentOutcome {
        // First gate, before anything can touch StripeTerminal. Tests that
        // inject a backend are exercising the collect path deliberately.
        if !usesInjectedBackend && !StripePaymentSettings.shared.isTapToPayEnabled {
            return .failed(Self.turnedOffFailure)
        }
        // Simulator and a missing Apple grant must not call Terminal APIs.
        // Selecting the method is not a charge; this is.
        if Self.shouldRefuseCollectOnThisRuntime {
            return .failed(Self.deviceOrEntitlementFailure)
        }
        if let reason = availability() { return .unavailable(reason) }
        guard request.amount.isPositive else {
            return .failed(PaymentFailure(
                message: "Enter an amount before taking a payment.",
                isRetryable: false,
                diagnosticCode: "zero-amount"
            ))
        }

        ensureLiveBackendIfNeeded()
        await TapToPayKeyboard.resignBeforeCollect()

        do {
            let result = try await backend.collect(
                amountMinorUnits: request.amount.minorUnits,
                currencyCode: request.amount.currencyCode,
                reference: request.fundName,
                stripeAccount: request.stripeAccount,
                organizationName: request.merchantName
            )
            return .captured(PaymentReceipt(
                amount: request.amount,
                transactionIdentifier: result.processorTransactionID,
                instrumentDescription: result.instrumentDescription ?? "Contactless card",
                method: .tapToPay,
                isSettled: result.isSettled,
                paymentIntentStatus: result.paymentIntentStatus
            ))
        } catch let error as ProcessorError {
            if error.localizedDescription == TapToPayCollectUI.missingLocationMessage {
                return .failed(PaymentFailure(
                    message: TapToPayCollectUI.missingLocationMessage,
                    isRetryable: false,
                    diagnosticCode: TapToPayCollectUI.missingLocationCode
                ))
            }
            return .failed(PaymentFailure(
                message: error.localizedDescription,
                isRetryable: error.isRetryable,
                diagnosticCode: error.diagnosticName
            ))
        } catch is CancellationError {
            return .cancelled
        } catch let error as TapToPayCollectError {
            switch error {
            case .deviceOrEntitlement:
                return .failed(Self.deviceOrEntitlementFailure)
            case .timedOut:
                return .failed(PaymentFailure(
                    message: error.localizedDescription,
                    isRetryable: true,
                    diagnosticCode: "tap-to-pay-timeout"
                ))
            case .missingLocation:
                return .failed(PaymentFailure(
                    message: TapToPayCollectUI.missingLocationMessage,
                    isRetryable: false,
                    diagnosticCode: TapToPayCollectUI.missingLocationCode
                ))
            }
        } catch {
            // A cancelled tap arrives as an error from most vendor SDKs. Treat
            // a cancellation as a cancellation, not a failure to apologise for.
            if TapToPayCollectUI.isCancellation(error) {
                return .cancelled
            }
            let message = error.localizedDescription
            if message == TapToPayCollectUI.deviceOrEntitlementMessage {
                return .failed(Self.deviceOrEntitlementFailure)
            }
            if message == TapToPayCollectUI.missingLocationMessage {
                return .failed(PaymentFailure(
                    message: TapToPayCollectUI.missingLocationMessage,
                    isRetryable: false,
                    diagnosticCode: TapToPayCollectUI.missingLocationCode
                ))
            }
            // discoverReaders / Apple Tap to Pay errors: show Stripe or Apple's
            // string and stay on What. Do not swallow into a generic tap line.
            return .failed(PaymentFailure(
                message: message.isEmpty
                    ? TapToPayCollectUI.contactlessFailureMessage
                    : message,
                isRetryable: true,
                diagnosticCode: "tap-to-pay"
            ))
        }
    }
}
