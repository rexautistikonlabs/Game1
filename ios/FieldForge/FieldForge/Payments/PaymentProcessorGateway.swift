//
//  PaymentProcessorGateway.swift
//  FieldForge
//
//  The seam between "Apple handed us a payment token" and "money moved".
//
//  Apple Pay produces a `PKPaymentToken` containing an encrypted payment
//  credential. Only a payment processor can decrypt and charge it, and that
//  requires server-side keys — which must never be in an app binary. So this
//  file defines the boundary and ships two implementations:
//
//    * `SimulatedProcessorGateway` — for development and for demoing the whole
//      flow without a merchant account. Loudly labelled; refuses to run in a
//      release build.
//    * `HostedProcessorGateway` — posts the token to the organization's own
//      endpoint, which does the charge with its secret key. This is the
//      supported production path, and the endpoint is a dozen lines of server
//      code with any processor's SDK. See README, "Wiring a processor".
//

import Foundation
import PassKit

/// What the app sends onward, and what it expects back.
struct ProcessorChargeRequest {
    var amountMinorUnits: Int
    var currencyCode: String
    /// Opaque, encrypted, processor-decryptable. Never logged, never stored.
    var paymentData: Data
    var network: String
    var instrumentDescription: String
    var transactionIdentifier: String
    var payerName: String
    var payerEmail: String
    var fundName: String
    var organizationName: String
    /// Idempotency key, so a retry after a dropped response cannot double-charge
    /// a donor. This is the single most important field in this struct.
    var idempotencyKey: String
}

struct ProcessorChargeResult {
    var processorTransactionID: String
    var isSettled: Bool
    /// Present when the processor knows more than PassKit does.
    var instrumentDescription: String?
    /// Stripe's PaymentIntent status when the gateway saw one. A tax letter is
    /// only allowed once this reads `succeeded`, so a gateway that cannot know
    /// (the simulated one, a bare charge endpoint) leaves it empty rather than
    /// guessing.
    var paymentIntentStatus: String = ""
}

enum ProcessorError: LocalizedError {
    case notConfigured
    case declined(String)
    case network(String)
    case server(status: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No payment processor is connected."
        case .declined(let reason):
            return reason.isEmpty ? "The card was declined." : reason
        case .network(let detail):
            return "Could not reach the payment service. \(detail)"
        case .server(let status, let message):
            return message.isEmpty ? "Payment service error (\(status))." : message
        case .malformedResponse:
            return "The payment service replied with something unexpected."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .server(let status, _): return status >= 500
        case .declined, .notConfigured, .malformedResponse: return false
        }
    }
}

protocol PaymentProcessorGateway: Sendable {
    var isConfigured: Bool { get }
    func charge(_ request: ProcessorChargeRequest) async throws -> ProcessorChargeResult
}

// MARK: - Development gateway

/// Pretends to charge. For building the UI and demoing the flow.
///
/// It refuses to operate in a release build. A simulated payment that produced
/// a real-looking tax receipt would be a genuinely harmful bug, so the guard is
/// a hard failure rather than a warning.
struct SimulatedProcessorGateway: PaymentProcessorGateway {

    /// Set to a value to force a specific outcome while testing.
    enum Behaviour: Sendable {
        case succeed
        case decline
        case networkFailure
    }

    var behaviour: Behaviour = .succeed
    var artificialDelay: Duration = .milliseconds(600)

    var isConfigured: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    func charge(_ request: ProcessorChargeRequest) async throws -> ProcessorChargeResult {
        #if !DEBUG
        throw ProcessorError.notConfigured
        #else
        try? await Task.sleep(for: artificialDelay)
        switch behaviour {
        case .succeed:
            return ProcessorChargeResult(
                processorTransactionID: "sim_\(UUID().uuidString.prefix(20))",
                isSettled: true,
                instrumentDescription: request.instrumentDescription
            )
        case .decline:
            throw ProcessorError.declined("Simulated decline.")
        case .networkFailure:
            throw ProcessorError.network("Simulated network failure.")
        }
        #endif
    }
}

// MARK: - Production gateway

/// Posts the Apple Pay token to the organization's own HTTPS endpoint.
///
/// The endpoint holds the processor's secret key and performs the charge. This
/// keeps the app out of PCI scope entirely: it never sees a card number and
/// never holds a processor secret.
struct HostedProcessorGateway: PaymentProcessorGateway {

    /// e.g. https://donations.example.org/api/charge
    let endpoint: URL
    /// A public, revocable identifier for this organization's install. Not a
    /// secret — anything in the binary is readable.
    let organizationPublicKey: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 25

    var isConfigured: Bool { !organizationPublicKey.isEmpty }

    func charge(_ request: ProcessorChargeRequest) async throws -> ProcessorChargeResult {
        guard isConfigured else { throw ProcessorError.notConfigured }

        struct Body: Encodable {
            let amount: Int
            let currency: String
            let paymentData: String
            let network: String
            let instrument: String
            let appleTransactionID: String
            let payerName: String
            let payerEmail: String
            let fund: String
            let organization: String
        }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(organizationPublicKey, forHTTPHeaderField: "X-FieldForge-Key")
        // The idempotency key is what makes a retry safe. Processors honour
        // this header; so must the endpoint in front of them.
        urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

        let body = Body(
            amount: request.amountMinorUnits,
            currency: request.currencyCode,
            paymentData: request.paymentData.base64EncodedString(),
            network: request.network,
            instrument: request.instrumentDescription,
            appleTransactionID: request.transactionIdentifier,
            payerName: request.payerName,
            payerEmail: request.payerEmail,
            fund: request.fundName,
            organization: request.organizationName
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

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

        struct Reply: Decodable {
            var transactionID: String?
            var settled: Bool?
            var instrument: String?
            var error: String?
            var declined: Bool?
        }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()

        guard (200..<300).contains(http.statusCode) else {
            if reply.declined == true {
                throw ProcessorError.declined(reply.error ?? "")
            }
            throw ProcessorError.server(status: http.statusCode, message: reply.error ?? "")
        }
        guard let transactionID = reply.transactionID, !transactionID.isEmpty else {
            throw ProcessorError.malformedResponse
        }

        return ProcessorChargeResult(
            processorTransactionID: transactionID,
            isSettled: reply.settled ?? true,
            instrumentDescription: reply.instrument
        )
    }
}

// MARK: - Registry

/// One place the app asks "can we actually charge a card?".
///
/// Configured at launch from whatever the organization has set up. Defaults to
/// the simulated gateway in debug and to nothing in release, which means a
/// shipped build with no processor configured cleanly reports
/// `.merchantNotConfigured` and steers the staffer to the manual path.
@MainActor
final class PaymentGatewayRegistry {

    static let shared = PaymentGatewayRegistry()

    private(set) var gateway: PaymentProcessorGateway

    /// The Apple merchant identifier from the entitlements file. Must match, or
    /// PassKit silently produces no payment sheet.
    private(set) var merchantIdentifier: String = "merchant.org.example.fieldforge"

    private init() {
        #if DEBUG
        gateway = SimulatedProcessorGateway()
        #else
        gateway = HostedProcessorGateway(
            endpoint: URL(string: "https://example.invalid/charge")!,
            organizationPublicKey: ""
        )
        #endif
    }

    func configure(gateway: PaymentProcessorGateway, merchantIdentifier: String) {
        self.gateway = gateway
        self.merchantIdentifier = merchantIdentifier
        AppLog.payments.info("Payment gateway configured (configured: \(gateway.isConfigured, privacy: .public))")
    }

    var canChargeCards: Bool { gateway.isConfigured }

    /// True in a debug build using the simulator. The UI shows a visible banner
    /// when this is on, so nobody demos a fake receipt believing it is real.
    var isSimulated: Bool { gateway is SimulatedProcessorGateway }
}
