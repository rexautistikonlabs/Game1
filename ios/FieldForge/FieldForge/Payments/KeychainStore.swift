//
//  KeychainStore.swift
//  FieldForge
//
//  Device-local secrets. Not CloudKit, not UserDefaults, not iCloud Keychain.
//  Used for the connected Stripe account id (acct_…) only — never sk_ keys.
//

import Foundation
import Security

enum KeychainStore {

    private static let service = "org.rexautistikonlabs.fieldforge"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
