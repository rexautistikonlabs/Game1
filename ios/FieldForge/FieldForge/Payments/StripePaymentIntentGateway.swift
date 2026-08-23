//
//  StripePaymentIntentGateway.swift
//  FieldForge
//
//  Real charges: the Azure function creates a PaymentIntent with the secret
//  key; this iPhone tokenizes Apple Pay with the publishable key and confirms.
//  `isSettled` is true only when Stripe reports status `succeeded`.
//

import Foundation

struct StripePaymentIntentGateway: PaymentProcessorGateway {

    let createIntentURL: URL
    let publishableKey: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 25

    var isConfigured: Bool {
        StripePaymentSettings.isPublishableKey(publishableKey)
    }

    func charge(_ request: ProcessorChargeRequest) async throws -> ProcessorChargeResult {
        guard isConfigured else { throw ProcessorError.notConfigured }
        if let message = StripeAmountLimits.rejectionMessage(forCents: request.amountMinorUnits) {
            throw ProcessorError.server(status: 400, message: message)
        }

        let clientSecret = try await createPaymentIntent(request)
        let tokenID = try await createApplePayToken(request)
        let intent = try await confirmPaymentIntent(
            clientSecret: clientSecret,
            tokenID: tokenID,
            idempotencyKey: request.idempotencyKey,
            stripeAccount: request.stripeAccount
        )

        guard intent.status == "succeeded" else {
            throw ProcessorError.declined(
                intent.status.isEmpty
                    ? "The payment did not succeed."
                    : "The payment is \(intent.status.replacingOccurrences(of: "_", with: " ")), not succeeded."
            )
        }

        return ProcessorChargeResult(
            processorTransactionID: intent.id,
            isSettled: true,
            instrumentDescription: request.instrumentDescription,
            paymentIntentStatus: intent.status
        )
    }

    // MARK: Azure — create PaymentIntent

    private func createPaymentIntent(_ request: ProcessorChargeRequest) async throws -> String {
        struct Body: Encodable {
            let amount: Int
            let currency: String
            let fund: String
            let organization: String
            var stripeAccount: String?

            enum CodingKeys: String, CodingKey {
                case amount, currency, fund, organization, stripeAccount
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(amount, forKey: .amount)
                try container.encode(currency, forKey: .currency)
                try container.encode(fund, forKey: .fund)
                try container.encode(organization, forKey: .organization)
                if let stripeAccount, StripeConnectAccount.isValidIdentifier(stripeAccount) {
                    try container.encode(stripeAccount, forKey: .stripeAccount)
                }
            }
        }
        struct Reply: Decodable {
            var clientSecret: String?
            var client_secret: String?
            var error: String?

            var resolvedSecret: String? { clientSecret ?? client_secret }
        }

        var urlRequest = URLRequest(url: createIntentURL, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            amount: request.amountMinorUnits,
            currency: "usd",
            fund: request.fundName,
            organization: request.organizationName,
            stripeAccount: request.stripeAccount
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
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
        guard let secret = reply.resolvedSecret, !secret.isEmpty else {
            throw ProcessorError.malformedResponse
        }
        return secret
    }

    // MARK: Stripe — tokenize Apple Pay, confirm PaymentIntent

    private func createApplePayToken(_ request: ProcessorChargeRequest) async throws -> String {
        guard let pkToken = String(data: request.paymentData, encoding: .utf8), !pkToken.isEmpty else {
            throw ProcessorError.malformedResponse
        }

        var pairs: [(String, String)] = [("pk_token", pkToken)]
        if !request.instrumentDescription.isEmpty {
            pairs.append(("pk_token_instrument_name", request.instrumentDescription))
        }
        if !request.network.isEmpty {
            pairs.append(("pk_token_payment_network", request.network))
        }
        if !request.transactionIdentifier.isEmpty {
            pairs.append(("pk_token_transaction_id", request.transactionIdentifier))
        }
        if !request.payerName.isEmpty {
            pairs.append(("card[name]", request.payerName))
        }

        let json = try await stripeFormPOST(
            path: "tokens",
            pairs: pairs,
            idempotencyKey: request.idempotencyKey + "-token",
            stripeAccount: request.stripeAccount
        )
        guard let id = json["id"] as? String, id.hasPrefix("tok_") else {
            throw ProcessorError.malformedResponse
        }
        return id
    }

    private func confirmPaymentIntent(
        clientSecret: String,
        tokenID: String,
        idempotencyKey: String,
        stripeAccount: String?
    ) async throws -> ConfirmedIntent {
        guard let intentID = Self.paymentIntentID(from: clientSecret) else {
            throw ProcessorError.malformedResponse
        }

        let json = try await stripeFormPOST(
            path: "payment_intents/\(intentID)/confirm",
            pairs: [
                ("client_secret", clientSecret),
                ("payment_method_data[type]", "card"),
                ("payment_method_data[card][token]", tokenID),
            ],
            idempotencyKey: idempotencyKey + "-confirm",
            stripeAccount: stripeAccount
        )

        guard let id = json["id"] as? String else {
            throw ProcessorError.malformedResponse
        }
        let status = (json["status"] as? String) ?? ""
        return ConfirmedIntent(id: id, status: status)
    }

    private struct ConfirmedIntent {
        var id: String
        var status: String
    }

    /// `pi_xxx_secret_yyy` → `pi_xxx`.
    static func paymentIntentID(from clientSecret: String) -> String? {
        guard let range = clientSecret.range(of: "_secret_") else { return nil }
        let id = String(clientSecret[..<range.lowerBound])
        return id.hasPrefix("pi_") ? id : nil
    }

    private func stripeFormPOST(
        path: String,
        pairs: [(String, String)],
        idempotencyKey: String,
        stripeAccount: String? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.stripe.com/v1/\(path)") else {
            throw ProcessorError.malformedResponse
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        if let stripeAccount, StripeConnectAccount.isValidIdentifier(stripeAccount) {
            urlRequest.setValue(stripeAccount, forHTTPHeaderField: "Stripe-Account")
        }
        urlRequest.httpBody = StripeForm.encode(pairs)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ProcessorError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProcessorError.malformedResponse
        }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? ""
            let type = (error["type"] as? String) ?? ""
            if type == "card_error" || (error["code"] as? String) == "card_declined" {
                throw ProcessorError.declined(message)
            }
            throw ProcessorError.server(status: http.statusCode, message: message)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProcessorError.server(status: http.statusCode, message: "")
        }
        return object
    }
}

enum StripeForm {
    static func encode(_ pairs: [(String, String)]) -> Data {
        pairs
            .map { "\(percentEncode($0))=\(percentEncode($1))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
