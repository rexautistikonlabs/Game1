//
//  StripeConnectAccount.swift
//  FieldForge
//
//  The connected Stripe account for a downloading nonprofit. Only `acct_…`
//  is stored, in the Keychain. Azure holds STRIPE_SECRET_KEY and creates the
//  PaymentIntent with Stripe-Account so funds land on their Stripe, not the
//  platform's. No connected account → charge the platform (Rex test path).
//

import Foundation
import Observation

@MainActor
@Observable
final class StripeConnectAccount {

    static let shared = StripeConnectAccount()

    static let keychainAccount = "stripe-connect-account"

    private(set) var accountID: String?

    var isConnected: Bool { accountID != nil }

    /// Last 4 of the acct_ id, for Settings. Never a key.
    var displayIdentifier: String {
        guard let accountID else { return "" }
        let tail = accountID.suffix(4)
        return "acct_…\(tail)"
    }

    init(loadFromKeychain: Bool = true) {
        guard loadFromKeychain else { return }
        if let stored = KeychainStore.get(account: Self.keychainAccount),
           Self.isValidIdentifier(stored) {
            accountID = stored
        } else if KeychainStore.get(account: Self.keychainAccount) != nil {
            // A previous build must never have written a key; strip junk.
            KeychainStore.delete(account: Self.keychainAccount)
        }
    }

    func connect(accountID raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidIdentifier(trimmed) else { return false }
        KeychainStore.set(trimmed, account: Self.keychainAccount)
        accountID = trimmed
        return true
    }

    func disconnect() {
        KeychainStore.delete(account: Self.keychainAccount)
        accountID = nil
    }

    nonisolated static func isValidIdentifier(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("acct_") else { return false }
        guard !trimmed.hasPrefix("sk_"), !trimmed.hasPrefix("pk_") else { return false }
        let rest = trimmed.dropFirst(5)
        return !rest.isEmpty && rest.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
