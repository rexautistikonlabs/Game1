//
//  TapToPayDiscovery.swift
//  FieldForge
//
//  Stripe-free discovery rules. Tests cover these without the Terminal SDK.
//  discoverReaders itself stays in StripeTerminalTapToPayBackend.
//

import Foundation
import os

/// At most one `discoverReaders` per collect. First `begin()` wins.
final class TapToPayDiscoveryOnce: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var hasStarted: Bool {
        lock.withLock { $0 }
    }

    /// True if this collect may call `discoverReaders`.
    func begin() -> Bool {
        lock.withLock { started in
            if started { return false }
            started = true
            return true
        }
    }

    func reset() {
        lock.withLock { $0 = false }
    }
}

/// When to cancel the discover `Cancelable`. Reader-found and connect-success
/// must not cancel — that aborted discovery under the hold-card sheet.
enum TapToPayDiscoverCancelPolicy {
    enum Event: Equatable {
        case readerDelivered
        case connectSucceeded
        case userCancel
        case timeout
    }

    static func shouldCancelDiscover(on event: Event) -> Bool {
        switch event {
        case .readerDelivered, .connectSucceeded:
            return false
        case .userCancel, .timeout:
            return true
        }
    }
}

/// Records which completion won. A nil Stripe error after a reader is a second
/// claim and must not replace success.
final class TapToPayFirstCompletion: @unchecked Sendable {
    enum Winner: Equatable {
        case success
        case failure
    }

    private let gate = TapToPayCallbackGate()
    private let lock = OSAllocatedUnfairLock<Winner?>(initialState: nil)

    var winner: Winner? {
        lock.withLock { $0 }
    }

    @discardableResult
    func succeed() -> Bool {
        guard gate.claim() else { return false }
        lock.withLock { $0 = .success }
        return true
    }

    /// Stripe's discover completion with `error == nil` after a reader.
    @discardableResult
    func failIgnoringNilAfterSuccess(_ error: Error?) -> Bool {
        guard gate.claim() else { return false }
        lock.withLock { $0 = .failure }
        return true
    }
}
