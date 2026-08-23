//
//  StripePaymentLinkClient.swift
//  FieldForge
//
//  Azure creates the Checkout Session with STRIPE_SECRET_KEY. This client
//  posts amount / giftId / contactName and never sees sk_. The same URL is
//  reused for SMS and email; the latest sessionId is what status checks.
//

import Foundation

struct PayLink: Equatable, Sendable {
    var url: URL
    var sessionID: String
}

struct PayLinkStatus: Equatable, Sendable {
    var paid: Bool
    var status: String
    var sessionID: String
    var paymentIntentID: String
    var paymentIntentStatus: String
    var amountMinorUnits: Int?
    var url: URL?
}

struct StripePaymentLinkClient: Sendable {

    var createURL: URL
    var statusURL: URL
    var session: URLSession = .shared
    var timeout: TimeInterval = 25

    func create(
        amountMinorUnits: Int,
        giftID: UUID,
        contactName: String,
        fundName: String = "",
        organizationName: String = "",
        stripeAccount: String? = nil,
        idempotencyKey: String
    ) async throws -> PayLink {
        if let message = StripeAmountLimits.rejectionMessage(forCents: amountMinorUnits) {
            throw ProcessorError.server(status: 400, message: message)
        }

        struct Body: Encodable {
            let amount: Int
            let giftId: String
            let contactName: String
            var fund: String?
            var organization: String?
            var stripeAccount: String?
        }
        struct Reply: Decodable {
            var url: String?
            var sessionId: String?
            var error: String?
        }

        var request = URLRequest(url: createURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(Body(
            amount: amountMinorUnits,
            giftId: giftID.uuidString,
            contactName: contactName,
            fund: fundName.trimmedOrNil,
            organization: organizationName.trimmedOrNil,
            stripeAccount: stripeAccount.flatMap {
                StripeConnectAccount.isValidIdentifier($0) ? $0 : nil
            }
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProcessorError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProcessorError.malformedResponse
        }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()
        guard (200..<300).contains(http.statusCode) else {
            throw ProcessorError.server(status: http.statusCode, message: reply.error ?? "")
        }
        guard let raw = reply.url, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else {
            throw ProcessorError.malformedResponse
        }
        let sessionID = reply.sessionId.flatMap { $0.hasPrefix("cs_") ? $0 : nil }
            ?? PayLinkMessage.sessionID(from: url)
            ?? ""
        return PayLink(url: url, sessionID: sessionID)
    }

    func status(
        sessionID: String,
        giftID: UUID,
        stripeAccount: String? = nil
    ) async throws -> PayLinkStatus {
        guard var components = URLComponents(url: statusURL, resolvingAgainstBaseURL: false) else {
            throw ProcessorError.malformedResponse
        }
        var items: [URLQueryItem] = []
        if sessionID.hasPrefix("cs_") {
            items.append(URLQueryItem(name: "sessionId", value: sessionID))
        }
        items.append(URLQueryItem(name: "giftId", value: giftID.uuidString))
        if let stripeAccount, StripeConnectAccount.isValidIdentifier(stripeAccount) {
            items.append(URLQueryItem(name: "stripeAccount", value: stripeAccount))
        }
        components.queryItems = items
        guard let url = components.url else { throw ProcessorError.malformedResponse }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProcessorError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProcessorError.malformedResponse
        }

        struct Reply: Decodable {
            var url: String?
            var sessionId: String?
            var status: String?
            var paid: Bool?
            var amount: Int?
            var paymentIntentId: String?
            var paymentIntentStatus: String?
            var error: String?
        }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()
        guard (200..<300).contains(http.statusCode) else {
            throw ProcessorError.server(status: http.statusCode, message: reply.error ?? "")
        }

        let paid = reply.paid == true || reply.paymentIntentStatus == "succeeded" || reply.status == "succeeded"
        return PayLinkStatus(
            paid: paid,
            status: reply.paymentIntentStatus ?? reply.status ?? "",
            sessionID: reply.sessionId ?? sessionID,
            paymentIntentID: reply.paymentIntentId ?? "",
            paymentIntentStatus: reply.paymentIntentStatus ?? (paid ? "succeeded" : ""),
            amountMinorUnits: reply.amount,
            url: reply.url.flatMap(URL.init(string:))
        )
    }
}
