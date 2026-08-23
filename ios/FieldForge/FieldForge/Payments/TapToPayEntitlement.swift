//
//  TapToPayEntitlement.swift
//  FieldForge
//
//  Runtime check for com.apple.developer.proximity-reader.payment.acceptance.
//
//  Reading the signed entitlement does not require Apple's grant, and must
//  never crash. Calling Stripe Terminal / ProximityReader payment APIs
//  *without* the grant can crash — so every Tap to Pay path consults this
//  first and refuses collect (the gift stays unpaid on What).
//
//  Do not put the key in FieldForge.entitlements until Apple has approved
//  the request. Shipping it unsigned fails code signing. See TAP_TO_PAY.md.
//

import Foundation

enum TapToPayEntitlement {

    static let identifier = "com.apple.developer.proximity-reader.payment.acceptance"

    /// True only when this build's provisioning profile actually carries the
    /// grant. `SecTaskCopyValueForEntitlement` is not a public iOS API, so we
    /// read `embedded.mobileprovision` instead. Simulator and unsigned copies
    /// have no profile — that is treated as missing. Collect then alerts
    /// and never calls Stripe Terminal Tap to Pay APIs.
    static var isPresentInSignature: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        // The profile is a CMS blob with an XML plist payload. Searching the
        // entitlement id as ASCII is enough: we only need presence, not a
        // parsed boolean, and a missing grant must not crash.
        let ascii = String(decoding: data, as: UTF8.self)
        if ascii.contains(identifier) { return true }
        if let latin1 = String(data: data, encoding: .isoLatin1), latin1.contains(identifier) {
            return true
        }
        return false
    }

    static var isStripeTerminalLinked: Bool {
        #if canImport(StripeTerminal)
        return true
        #else
        return false
        #endif
    }

    /// Entitlement plus Terminal SDK. Both are required before the tile enables.
    static var canAcceptContactlessOnThisBuild: Bool {
        isPresentInSignature && isStripeTerminalLinked
    }
}
