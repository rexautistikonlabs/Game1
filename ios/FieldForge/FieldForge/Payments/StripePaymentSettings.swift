//
//  StripePaymentSettings.swift
//  FieldForge
//
//  Device-local processor settings. Backend URL and a Stripe *publishable*
//  key only. The secret key stays on Azure. Nothing here is CloudKit-backed:
//  a half-configured merchant account is not team memory.
//

import Foundation
import Observation

/// Stripe's USD floor and the cap this function will accept.
enum StripeAmountLimits {
    static let minimumCents = 50
    static let maximumCents = 10_000_000

    static func rejectionMessage(forCents cents: Int) -> String? {
        if cents < minimumCents {
            return "Stripe requires at least $0.50."
        }
        if cents > maximumCents {
            return "Amount cannot exceed $100,000.00."
        }
        return nil
    }
}

/// Merchant ID is compiled into the entitlements. Downloading orgs never type
/// a backend URL or pk_ — those are the platform's, hidden behind a debug
/// control. A stored override still wins, so the Rex $1 Apple Pay path keeps
/// working on a device that already has Settings filled in.
@MainActor
@Observable
final class StripePaymentSettings {

    static let shared = StripePaymentSettings()

    static let defaultMerchantIdentifier = PaymentGatewayRegistry.defaultMerchantIdentifier

    /// Platform Azure Function App. Downloading orgs never see this string in
    /// Settings; debug/platform builds can override it.
    static let platformBackendOrigin = "https://fieldforgepay-a7hxe0h0dmcqaneu.eastus-01.azurewebsites.net"

    private enum Keys {
        static let backendURL = "fieldforge.stripe.backendURL"
        static let publishableKey = "fieldforge.stripe.publishableKey"
        static let platformDebug = "fieldforge.stripe.platformDebug"
        static let tapToPayEnabled = "fieldforge.stripe.tapToPayEnabled"
    }

    private let defaults: UserDefaults

    var backendURLString: String {
        didSet { defaults.set(backendURLString, forKey: Keys.backendURL) }
    }

    private(set) var publishableKey: String
    /// Set when someone pastes `sk_...`. The value is discarded, never stored.
    private(set) var rejectedSecretKey = false

    /// Backend URL + pk_ fields. Off for a normal org; on in DEBUG, or after
    /// seven taps on the version row.
    var showsPlatformDebug: Bool {
        didSet { defaults.set(showsPlatformDebug, forKey: Keys.platformDebug) }
    }

    /// Tap to Pay on iPhone ships **off**. Stripe Terminal's `discoverReaders`
    /// aborts the process on some devices and profiles, and a crash mid-capture
    /// costs a gift. The donor pay link is the primary card path; an operator
    /// who has tested Tap to Pay on their own iPhone turns it on here.
    ///
    /// While this is false nothing in the app touches `StripeTerminal`: the
    /// method tile is disabled and Collect refuses before the SDK is loaded.
    var isTapToPayEnabled: Bool {
        didSet { defaults.set(isTapToPayEnabled, forKey: Keys.tapToPayEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURLString = defaults.string(forKey: Keys.backendURL) ?? ""
        let storedKey = defaults.string(forKey: Keys.publishableKey) ?? ""
        // A secret key must never sit in UserDefaults. Strip it if a previous
        // build somehow wrote one.
        if storedKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk_") {
            defaults.removeObject(forKey: Keys.publishableKey)
            self.publishableKey = ""
        } else {
            self.publishableKey = storedKey
        }
        if defaults.object(forKey: Keys.platformDebug) != nil {
            self.showsPlatformDebug = defaults.bool(forKey: Keys.platformDebug)
        } else {
            #if DEBUG
            self.showsPlatformDebug = true
            #else
            self.showsPlatformDebug = false
            #endif
        }
        // Absent key means off. Never default this on.
        self.isTapToPayEnabled = defaults.bool(forKey: Keys.tapToPayEnabled)
    }

    /// Apple Pay merchant identifier. Already in FieldForge.entitlements.
    var merchantIdentifier: String { Self.defaultMerchantIdentifier }

    /// Stored override if the operator typed one; otherwise the platform origin.
    var effectiveBackendURLString: String {
        let stored = backendURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? Self.platformBackendOrigin : stored
    }

    var createPaymentIntentURL: URL? {
        Self.resolveCreateIntentURL(effectiveBackendURLString)
    }

    /// Donor pay link. Does not need a pk_ on this iPhone — Azure holds sk_.
    var createPaymentLinkURL: URL? {
        Self.resolveAPIURL(effectiveBackendURLString, path: "/api/create-payment-link")
    }

    var paymentStatusURL: URL? {
        Self.resolveAPIURL(effectiveBackendURLString, path: "/api/payment-status")
    }

    /// Stripe Terminal connection token. Azure holds `STRIPE_SECRET_KEY`.
    var terminalConnectionTokenURL: URL? {
        Self.resolveAPIURL(effectiveBackendURLString, path: "/api/connection-token")
    }

    /// Real Apple Pay is on when the platform (or an override) has a URL and a
    /// pk_ key. A connected `acct_` is optional — missing it charges Rex.
    var isConfigured: Bool {
        guard createPaymentIntentURL != nil else { return false }
        return Self.isPublishableKey(publishableKey)
    }

    func unlockPlatformDebug() {
        showsPlatformDebug = true
    }

    /// Pull the platform pk_ from Azure when this iPhone has none stored.
    /// Does not overwrite a key the operator already typed (the Rex path).
    func refreshPublicConfigIfNeeded() async {
        guard !Self.isPublishableKey(publishableKey) else { return }
        guard let url = Self.resolveAPIURL(effectiveBackendURLString, path: "/api/public-config") else {
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            struct Reply: Decodable { var publishableKey: String? }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let key = reply.publishableKey else { return }
            setPublishableKey(key)
        } catch {
            AppLog.payments.error("public-config fetch failed")
        }
    }

    var isTestMode: Bool {
        publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pk_test_")
    }

    func setPublishableKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk_") {
            rejectedSecretKey = true
            return
        }
        rejectedSecretKey = false
        publishableKey = trimmed
        defaults.set(trimmed, forKey: Keys.publishableKey)
    }

    nonisolated static func isPublishableKey(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("pk_") else { return false }
        guard !trimmed.hasPrefix("sk_") else { return false }
        return trimmed.count > 8
    }

    /// Accepts either the Function App origin or the full create-payment-intent URL.
    nonisolated static func resolveCreateIntentURL(_ raw: String) -> URL? {
        resolveAPIURL(raw, path: "/api/create-payment-intent")
    }

    /// Origin, or a full function URL whose path already matches `path`.
    /// A stored create-payment-intent URL still resolves sibling functions
    /// (`public-config`, `connect/oauth/start`) off the same host.
    nonisolated static func resolveAPIURL(_ raw: String, path: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        #if !DEBUG
        guard scheme == "https" else { return nil }
        #endif
        let needle = path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
        if url.path.lowercased().contains(needle) {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = path.hasPrefix("/") ? path : "/" + path
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}
