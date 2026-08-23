//
//  PayLinkMessage.swift
//  FieldForge
//
//  The SMS or email a donor receives, and the helpers that open them. Pure so
//  tests can check the copy without MessageUI. Never carries a secret key.
//

import Foundation

/// How the pay link is delivered. Each channel uses its own Stripe
/// idempotency key, so sending both may create two Checkout sessions.
enum PayLinkChannel: String, Sendable {
    case sms
    case email
}

enum PayLinkMessage {

    /// "{Org} — tap to give $25.00: https://…"
    static func body(organizationName: String, amount: Money, url: URL) -> String {
        let org = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = org.isEmpty ? "our organization" : org
        return "\(name) — tap to give \(amount.formatted): \(url.absoluteString)"
    }

    /// "{Org} — gift of $25.00"
    static func emailSubject(organizationName: String, amount: Money) -> String {
        "\(displayName(organizationName)) — gift of \(amount.formatted)"
    }

    /// Short note plus the Checkout URL. Never a key.
    static func emailBody(organizationName: String, amount: Money, url: URL) -> String {
        """
        \(displayName(organizationName)) — a gift of \(amount.formatted).

        \(url.absoluteString)
        """
    }

    static func digits(from phone: String) -> String {
        phone.filter { $0.isNumber || $0 == "+" }
    }

    static func isUsablePhone(_ phone: String) -> Bool {
        let digits = digits(from: phone).filter(\.isNumber)
        return digits.count >= 7
    }

    static func isUsableEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !local.isEmpty, !domain.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            return false
        }
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Fallback when `MFMessageComposeViewController` cannot send.
    static func smsURL(phone: String, body: String) -> URL? {
        let digits = digits(from: phone)
        guard isUsablePhone(phone) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+")
        let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
        return URL(string: "sms:\(digits)&body=\(encoded)")
    }

    /// Fallback when `MFMailComposeViewController` cannot send.
    static func mailtoURL(email: String, subject: String, body: String) -> URL? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableEmail(trimmed) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = trimmed
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// `cs_…` from a Checkout URL, used if Azure omits `sessionId`.
    static func sessionID(from url: URL) -> String? {
        let path = url.path
        for piece in path.split(separator: "/") {
            if piece.hasPrefix("cs_") { return String(piece) }
        }
        if let host = url.host, host.contains("checkout.stripe.com"),
           let last = path.split(separator: "/").last, last.hasPrefix("cs_") {
            return String(last)
        }
        return nil
    }

    private static func displayName(_ organizationName: String) -> String {
        let org = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return org.isEmpty ? "our organization" : org
    }
}
