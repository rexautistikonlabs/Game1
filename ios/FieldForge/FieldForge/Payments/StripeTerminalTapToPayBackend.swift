//
//  StripeTerminalTapToPayBackend.swift
//  FieldForge
//
//  Stripe Terminal Tap to Pay. Collect is the only entry. discoverReaders
//  runs at most once per collect; the Reader is kept. Discovery is never
//  started after the hold-card UI is up.
//

import Foundation
import os

#if canImport(StripeTerminal)
import StripeTerminal

/// Network and waits run off the main thread. Terminal calls that present UI
/// hop to MainActor. Not MainActor itself — collect on main with the keyboard
/// up is what aborted discoverReaders.
final class StripeTerminalTapToPayBackend: NSObject, TapToPayBackend, @unchecked Sendable {

    private let state = CollectState()
    private let readerDelegate = FieldForgeTapToPayReaderDelegate()
    private var discoveryDelegate: DiscoveryRelay?

    override init() {
        super.init()
        readerDelegate.onDisconnect = { [weak self] in
            self?.state.clearReader()
        }
    }

    func isReady() async -> Bool {
        guard TapToPayEntitlement.canAcceptContactlessOnThisBuild else { return false }
        return await MainActor.run {
            StripePaymentSettings.shared.terminalConnectionTokenURL != nil
                || StripePaymentSettings.shared.createPaymentIntentURL != nil
        }
    }

    func prepareReader() async throws {
        // Collect connects. Do not warm from launch or route.
    }

    func cancelCollect() async {
        // Return immediately. Do not wait on Stripe's cancel completion.
        state.cancelAll()
    }

    func collect(
        amountMinorUnits: Int,
        currencyCode: String,
        reference: String,
        stripeAccount: String?,
        organizationName: String
    ) async throws -> ProcessorChargeResult {
        guard TapToPayEntitlement.canAcceptContactlessOnThisBuild else {
            throw TapToPayCollectError.deviceOrEntitlement
        }
        if let message = StripeAmountLimits.rejectionMessage(forCents: amountMinorUnits) {
            throw ProcessorError.server(status: 400, message: message)
        }

        do {
            return try await withTimeout(seconds: TapToPayCollectUI.timeoutSeconds) {
                try await self.collectOnce(
                    amountMinorUnits: amountMinorUnits,
                    currencyCode: currencyCode,
                    reference: reference,
                    stripeAccount: stripeAccount,
                    organizationName: organizationName
                )
            }
        } catch is CancellationError {
            await cancelCollect()
            throw CancellationError()
        } catch let error as TapToPayCollectError {
            await cancelCollect()
            throw error
        } catch {
            await cancelCollect()
            if TapToPayCollectUI.isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
    }

    private func collectOnce(
        amountMinorUnits: Int,
        currencyCode: String,
        reference: String,
        stripeAccount: String?,
        organizationName: String
    ) async throws -> ProcessorChargeResult {
        try await ensureReaderConnected()
        try await requireConnectedReader()

        let clientSecret = try await createCardPresentIntent(
            amountMinorUnits: amountMinorUnits,
            fundName: reference,
            organizationName: organizationName,
            stripeAccount: stripeAccount
        )

        let retrieved: PaymentIntent = try await stripeFirst { finish in
            await MainActor.run {
                self.catchingStripe {
                    Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { intent, error in
                        finish(intent, error)
                    }
                } failure: { error in
                    finish(nil, error)
                }
                return nil as Cancelable?
            }
        }

        // Hold-card UI. Must not start discovery here — the Reader is already
        // connected from ensureReaderConnected.
        let confirmed: PaymentIntent = try await stripeFirst(storeAsCollect: true) { finish in
            await MainActor.run { () -> Cancelable? in
                var stored: Cancelable?
                self.catchingStripe {
                    stored = Terminal.shared.processPaymentIntent(
                        retrieved,
                        collectConfig: nil,
                        confirmConfig: nil
                    ) { intent, error in
                        finish(intent, error)
                    }
                } failure: { error in
                    finish(nil, error)
                }
                if let stored {
                    self.state.collectCancelable = stored
                }
                return stored
            }
        }

        let status = await MainActor.run {
            Terminal.stringFromPaymentIntentStatus(confirmed.status)
        }
        guard status == "succeeded" else {
            throw ProcessorError.declined(
                status.isEmpty
                    ? "The payment did not succeed."
                    : "The payment is \(status.replacingOccurrences(of: "_", with: " ")), not succeeded."
            )
        }

        return ProcessorChargeResult(
            processorTransactionID: confirmed.stripeId ?? "",
            isSettled: true,
            instrumentDescription: "Contactless card",
            paymentIntentStatus: status
        )
    }

    // MARK: Reader

    private func ensureReaderConnected() async throws {
        guard TapToPayEntitlement.canAcceptContactlessOnThisBuild else {
            throw TapToPayCollectError.deviceOrEntitlement
        }

        let token = try await FieldForgeConnectionTokenProvider.fetch()
        state.locationID = token.locationId
        guard !state.locationID.isEmpty else {
            throw TapToPayCollectError.missingLocation
        }

        try await installTokenProviderIfNeeded()

        let alreadyConnected = await MainActor.run {
            Terminal.shared.connectionStatus == .connected
        }
        if alreadyConnected { return }

        let reader: Reader
        if let kept = state.reader {
            reader = kept
        } else {
            reader = try await discoverTapToPayReader()
            state.reader = reader
        }

        let locationId = state.locationID
        guard !locationId.isEmpty else {
            throw TapToPayCollectError.missingLocation
        }

        let connectionConfig = try await MainActor.run {
            try TapToPayConnectionConfigurationBuilder(
                delegate: self.readerDelegate,
                locationId: locationId
            )
            .setMerchantDisplayName(nil)
            .setTosAcceptancePermitted(true)
            .build()
        }

        do {
            _ = try await stripeFirst { finish in
                await MainActor.run {
                    self.catchingStripe {
                        Terminal.shared.connectReader(reader, connectionConfig: connectionConfig) { connected, error in
                            finish(connected, error)
                        }
                    } failure: { error in
                        finish(nil, error)
                    }
                    return nil as Cancelable?
                }
            }
        } catch {
            // Stale reader after a failed connect — next Collect rediscovers.
            state.clearReader()
            throw error
        }
        // Connect completes discovery. Do not cancel the Cancelable; do not
        // discover again.
        state.discoverCancelable = nil
    }

    private func requireConnectedReader() async throws {
        let connected = await MainActor.run {
            Terminal.shared.connectionStatus == .connected
        }
        guard connected else {
            state.clearReader()
            throw ProcessorError.server(
                status: 503,
                message: "Tap to Pay is not connected."
            )
        }
    }

    /// At most once per collect. Keep the Reader. Do not cancel discovery
    /// after a reader — connectReader ends discovery. A second discoverReaders
    /// after the hold-card UI is up is the SIGABRT.
    private func discoverTapToPayReader() async throws -> Reader {
        if let kept = state.reader { return kept }
        guard state.beginDiscovery() else {
            if let kept = state.reader { return kept }
            throw ProcessorError.server(
                status: 503,
                message: "Tap to Pay discovery is already running."
            )
        }

        let supported = await MainActor.run {
            Terminal.shared.supportsReaders(
                of: .tapToPay,
                discoveryMethod: .tapToPay,
                simulated: false
            )
        }
        if case .failure(let error) = supported {
            state.abortDiscovery()
            throw error
        }

        let config: TapToPayDiscoveryConfiguration
        do {
            config = try await MainActor.run {
                try TapToPayDiscoveryConfigurationBuilder().build()
            }
        } catch {
            state.abortDiscovery()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<Reader, Error>.makeStream()
        let once = StreamOnce(continuation)
        let relay = DiscoveryRelay { readers in
            if let reader = readers.first {
                once.succeed(reader)
            }
        }
        discoveryDelegate = relay

        await MainActor.run {
            self.catchingStripe {
                let cancelable = Terminal.shared.discoverReaders(config, delegate: relay) { error in
                    // Success already claimed the gate. A nil error after a
                    // reader must be ignored — not a second finish.
                    once.fail(error)
                }
                self.state.discoverCancelable = cancelable
            } failure: { error in
                once.fail(error)
            }
        }

        do {
            for try await reader in stream {
                state.reader = reader
                return reader
            }
            state.abortDiscovery()
            throw ProcessorError.server(status: 503, message: "This iPhone could not start Tap to Pay.")
        } catch {
            if state.reader == nil {
                state.abortDiscovery()
            }
            if TapToPayCollectUI.isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
    }

    private func installTokenProviderIfNeeded() async throws {
        guard !state.tokenProviderInstalled else { return }
        await MainActor.run {
            if !Terminal.isInitialized() {
                Terminal.initWithTokenProvider(FieldForgeConnectionTokenProvider())
            }
        }
        state.tokenProviderInstalled = true
    }

    private func createCardPresentIntent(
        amountMinorUnits: Int,
        fundName: String,
        organizationName: String,
        stripeAccount: String?
    ) async throws -> String {
        if let combined = try await createIntentViaConnectionToken(
            amountMinorUnits: amountMinorUnits,
            fundName: fundName,
            organizationName: organizationName,
            stripeAccount: stripeAccount
        ) {
            return combined
        }
        let url = await MainActor.run { StripePaymentSettings.shared.createPaymentIntentURL }
        guard let url else {
            throw ProcessorError.notConfigured
        }
        return try await postCardPresentIntent(
            url: url,
            amountMinorUnits: amountMinorUnits,
            fundName: fundName,
            organizationName: organizationName,
            stripeAccount: stripeAccount
        )
    }

    private func createIntentViaConnectionToken(
        amountMinorUnits: Int,
        fundName: String,
        organizationName: String,
        stripeAccount: String?
    ) async throws -> String? {
        let url = await MainActor.run { StripePaymentSettings.shared.terminalConnectionTokenURL }
        guard let url else { return nil }
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
            var secret: String?
            var locationId: String?
            var location_id: String?
            var clientSecret: String?
            var client_secret: String?
            var error: String?
            var resolvedClientSecret: String? { clientSecret ?? client_secret }
            var resolvedLocation: String { locationId ?? location_id ?? "" }
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            amount: amountMinorUnits,
            currency: "usd",
            fund: fundName,
            organization: organizationName,
            stripeAccount: stripeAccount
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProcessorError.malformedResponse }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()
        if !reply.resolvedLocation.isEmpty {
            state.locationID = reply.resolvedLocation
        }
        if (200..<300).contains(http.statusCode), let secret = reply.resolvedClientSecret, !secret.isEmpty {
            return secret
        }
        if (200..<300).contains(http.statusCode) {
            return nil
        }
        if http.statusCode == 404 { return nil }
        let message = reply.error ?? ""
        if message == TapToPayCollectUI.missingLocationMessage
            || (http.statusCode == 400 && message.localizedCaseInsensitiveContains("location")) {
            throw TapToPayCollectError.missingLocation
        }
        throw ProcessorError.server(status: http.statusCode, message: message)
    }

    private func postCardPresentIntent(
        url: URL,
        amountMinorUnits: Int,
        fundName: String,
        organizationName: String,
        stripeAccount: String?
    ) async throws -> String {
        struct Body: Encodable {
            let amount: Int
            let currency: String
            let fund: String
            let organization: String
            let method: String
            var stripeAccount: String?

            enum CodingKeys: String, CodingKey {
                case amount, currency, fund, organization, method, stripeAccount
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(amount, forKey: .amount)
                try container.encode(currency, forKey: .currency)
                try container.encode(fund, forKey: .fund)
                try container.encode(organization, forKey: .organization)
                try container.encode(method, forKey: .method)
                if let stripeAccount, StripeConnectAccount.isValidIdentifier(stripeAccount) {
                    try container.encode(stripeAccount, forKey: .stripeAccount)
                }
            }
        }
        struct Reply: Decodable {
            var clientSecret: String?
            var client_secret: String?
            var locationId: String?
            var location_id: String?
            var error: String?
            var resolvedSecret: String? { clientSecret ?? client_secret }
            var resolvedLocation: String { locationId ?? location_id ?? "" }
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(
            amount: amountMinorUnits,
            currency: "usd",
            fund: fundName,
            organization: organizationName,
            method: "tap_to_pay",
            stripeAccount: stripeAccount
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProcessorError.malformedResponse }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()
        if !reply.resolvedLocation.isEmpty {
            state.locationID = reply.resolvedLocation
        }
        if let message = reply.error, message == TapToPayCollectUI.missingLocationMessage {
            throw TapToPayCollectError.missingLocation
        }
        guard (200..<300).contains(http.statusCode), let secret = reply.resolvedSecret, !secret.isEmpty else {
            throw ProcessorError.server(status: http.statusCode, message: reply.error ?? "")
        }
        return secret
    }

    /// First Stripe callback wins. Later callbacks (nil error after a reader)
    /// are ignored. Does not cancel on success — that aborted discovery.
    /// `start` is awaited on MainActor by callers so the Cancelable is stored
    /// before we wait, and Terminal UI work is not fire-and-forget off main.
    private func stripeFirst<T: Sendable>(
        storeAsCollect: Bool = false,
        start: (@escaping @Sendable (T?, Error?) -> Void) async -> Cancelable?
    ) async throws -> T {
        let (stream, continuation) = AsyncThrowingStream<T, Error>.makeStream()
        let once = StreamOnce(continuation)
        let finish: @Sendable (T?, Error?) -> Void = { value, error in
            if let value {
                once.succeed(value)
            } else {
                once.fail(error)
            }
        }
        let cancelable = await start(finish)
        if storeAsCollect, let cancelable {
            state.collectCancelable = cancelable
        }

        for try await value in stream {
            return value
        }
        throw CancellationError()
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                await self.cancelCollect()
                throw TapToPayCollectError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TapToPayCollectError.timedOut
            }
            return first
        }
    }

    /// Stripe raises NSException (not Swift Error). Catch and surface as an
    /// alert instead of aborting the process under the debugger.
    private func catchingStripe(_ work: () -> Void, failure: (Error) -> Void) {
        var nsError: NSError?
        let ok = FFCatchException({
            work()
        }, &nsError)
        if !ok {
            failure(nsError ?? ProcessorError.server(
                status: 500,
                message: nsError?.localizedDescription ?? "Tap to Pay failed."
            ))
        }
    }

}

// MARK: - Once / state

/// Yields or throws at most once. Thread-safe. A nil Stripe completion after
/// success does not finish again.
private final class StreamOnce<T: Sendable>: @unchecked Sendable {
    private let gate = TapToPayCallbackGate()
    private let continuation: AsyncThrowingStream<T, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<T, Error>.Continuation) {
        self.continuation = continuation
    }

    func succeed(_ value: T) {
        guard gate.claim() else { return }
        continuation.yield(value)
        continuation.finish()
    }

    func fail(_ error: Error?) {
        guard gate.claim() else { return }
        if let error {
            if TapToPayCollectUI.isCancellation(error) {
                continuation.finish(throwing: CancellationError())
            } else {
                continuation.finish(throwing: error)
            }
        } else {
            continuation.finish(throwing: ProcessorError.server(
                status: 503,
                message: "This iPhone could not start Tap to Pay."
            ))
        }
    }
}

private final class CollectState: @unchecked Sendable {
    private struct Box {
        var locationID = ""
        var tokenProviderInstalled = false
        var reader: Reader?
        var discoverCancelable: Cancelable?
        var collectCancelable: Cancelable?
    }

    private let discoveryOnce = TapToPayDiscoveryOnce()
    private let lock = OSAllocatedUnfairLock(initialState: Box())

    var locationID: String {
        get { lock.withLock { $0.locationID } }
        set { lock.withLock { $0.locationID = newValue } }
    }

    var tokenProviderInstalled: Bool {
        get { lock.withLock { $0.tokenProviderInstalled } }
        set { lock.withLock { $0.tokenProviderInstalled = newValue } }
    }

    var reader: Reader? {
        get { lock.withLock { $0.reader } }
        set { lock.withLock { $0.reader = newValue } }
    }

    var collectCancelable: Cancelable? {
        get { lock.withLock { $0.collectCancelable } }
        set { lock.withLock { $0.collectCancelable = newValue } }
    }

    var discoverCancelable: Cancelable? {
        get { lock.withLock { $0.discoverCancelable } }
        set { lock.withLock { $0.discoverCancelable = newValue } }
    }

    /// True if this collect may start discoverReaders.
    func beginDiscovery() -> Bool {
        discoveryOnce.begin()
    }

    func abortDiscovery() {
        lock.withLock { box in
            box.reader = nil
            box.discoverCancelable = nil
        }
        discoveryOnce.reset()
    }

    func clearReader() {
        lock.withLock { box in
            box.reader = nil
        }
        discoveryOnce.reset()
    }

    func cancelAll() {
        let pair: (Cancelable?, Cancelable?) = lock.withLock { box in
            let discover = box.discoverCancelable
            let collect = box.collectCancelable
            box.discoverCancelable = nil
            box.collectCancelable = nil
            return (discover, collect)
        }
        pair.0?.cancel { _ in }
        pair.1?.cancel { _ in }
    }
}

private final class DiscoveryRelay: NSObject, DiscoveryDelegate, @unchecked Sendable {
    private let onReaders: @Sendable ([Reader]) -> Void
    private let delivered = OSAllocatedUnfairLock(initialState: false)

    init(onReaders: @escaping @Sendable ([Reader]) -> Void) {
        self.onReaders = onReaders
    }

    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        let first = delivered.withLock { flag -> Bool in
            if flag || readers.isEmpty { return false }
            flag = true
            return true
        }
        guard first else { return }
        onReaders(readers)
    }
}

private final class FieldForgeTapToPayReaderDelegate: NSObject, TapToPayReaderDelegate {
    var onDisconnect: (@Sendable () -> Void)?

    func tapToPayReader(
        _ reader: Reader,
        didStartInstallingUpdate update: ReaderSoftwareUpdate,
        cancelable: Cancelable?
    ) {}

    func tapToPayReader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}

    func tapToPayReader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}

    func tapToPayReaderDidAcceptTermsOfService(_ reader: Reader) {}

    func tapToPayReader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {}

    func tapToPayReader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}

    func reader(_ reader: Reader, didDisconnect reason: DisconnectReason) {
        AppLog.payments.error("Tap to Pay reader disconnected")
        onDisconnect?()
    }
}

final class FieldForgeConnectionTokenProvider: ConnectionTokenProvider {
    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        Task {
            do {
                let token = try await Self.fetch()
                completion(token.secret, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    static func fetch() async throws -> (secret: String, locationId: String) {
        let (url, accountID) = await MainActor.run {
            (
                StripePaymentSettings.shared.terminalConnectionTokenURL,
                StripeConnectAccount.shared.accountID
            )
        }
        guard let url else {
            throw ProcessorError.notConfigured
        }
        struct Body: Encodable {
            var stripeAccount: String?
            enum CodingKeys: String, CodingKey { case stripeAccount }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let stripeAccount, StripeConnectAccount.isValidIdentifier(stripeAccount) {
                    try container.encode(stripeAccount, forKey: .stripeAccount)
                }
            }
        }
        struct Reply: Decodable {
            var secret: String?
            var locationId: String?
            var location_id: String?
            var error: String?
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(stripeAccount: accountID))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProcessorError.malformedResponse }
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply()
        let message = reply.error ?? ""
        if message == TapToPayCollectUI.missingLocationMessage
            || (http.statusCode == 400 && message.localizedCaseInsensitiveContains("location")) {
            throw TapToPayCollectError.missingLocation
        }
        guard (200..<300).contains(http.statusCode), let secret = reply.secret, !secret.isEmpty else {
            throw ProcessorError.server(status: http.statusCode, message: message)
        }
        let location = reply.locationId ?? reply.location_id ?? ""
        guard !location.isEmpty else {
            throw TapToPayCollectError.missingLocation
        }
        return (secret, location)
    }
}

#endif
