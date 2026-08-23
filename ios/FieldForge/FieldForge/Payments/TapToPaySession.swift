//
//  TapToPaySession.swift
//  FieldForge
//
//  Survives a force-quit mid-collect. Launch reads this *before* any Terminal
//  API: a dirty flag means discard the in-flight draft and show Today.
//

import Foundation

enum TapToPaySession {

    static let collectInFlightKey = "fieldforge.tapToPay.collectInFlight"

    private static var defaults: UserDefaults { .standard }

    static var collectInFlight: Bool {
        get { defaults.bool(forKey: collectInFlightKey) }
        set { defaults.set(newValue, forKey: collectInFlightKey) }
    }

    static func markStarted() {
        collectInFlight = true
    }

    static func markFinished() {
        collectInFlight = false
    }

    /// Call once at launch, before first paint of the real UI. Always clears
    /// the in-flight flag so a crashed collect cannot leave Today white.
    /// If the last process died during collect, the draft is discarded so a
    /// half-open PaymentIntent cannot block Today.
    @discardableResult
    static func recoverIfDirty() -> Bool {
        let dirty = collectInFlight
        collectInFlight = false
        guard dirty else { return false }
        DraftStore.clear()
        AppLog.payments.error("Discarded a dirty Tap to Pay session at launch")
        return true
    }
}
