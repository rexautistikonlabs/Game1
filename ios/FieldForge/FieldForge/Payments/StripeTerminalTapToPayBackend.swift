//
//  StripeTerminalTapToPayBackend.swift
//  FieldForge
//
//  Stripe Terminal Tap to Pay, in the shape of Stripe's own sample.
//
//  The whole Terminal conversation lives on the main actor, because that is
//  where the SDK calls back, and it runs as one straight line:
//
//      connection token (Azure)  ->  token provider  ->  Terminal.shared.delegate
//      ->  discoverReaders (once)  ->  connectReader  ->  retrievePaymentIntent
//      ->  processPaymentIntent
//
//  Two rules earn their keep here:
//
//  1. `discoverReaders` runs at most once per connect, and the reader is kept.
//     Discovery is ended by a successful `connectReader`, which is why connect
//     is started from inside `didUpdateDiscoveredReaders` rather than after
//     returning from discovery. Nothing cancels a discovery that already
//     produced a reader.
//  2. The connection token provider is owned for the life of the process.
//     Stripe re-asks for a token during connect and during confirm; handing it
//     an object nobody retains is a use-after-free in the middle of a tap.
//

import Foundation
import os

#if canImport(StripeTerminal)
import StripeTerminal

/// Non-isolated shell so the async `TapToPayBackend` requirements are witnessed
/// plainly. Every Terminal call is forwarded to `TapToPayTerminalSession`,
/// which is main-actor bound.
final class StripeTerminalTapToPayBackend: TapToPayBackend, @unchecked Sendable {

    private let session: TapToPayTerminalSession

    @MainActor
    init() {
        self.session = TapToPayTerminalSession()
    }

    func isReady() async -> Bool {
        guard TapToPayEntitlement.canAcceptContactlessOnThisBuild else { return false }
        return await MainActor.run {
            StripePaymentSettings.shared.terminalConnectionTokenURL != nil
                || StripePaymentSettings.shared.createPaymentIntentURL != nil
        }
    }

    /// Collect connects. Nothing warms Terminal from launch or from Route.
    func prepareReader() async throws {}

    /// Returns immediately. Never waits on Stripe's cancel completion — the
    /// What step has to come back under the staffer's thumb at once.
    func cancelCollect() async {
        await session.cancelOutstanding()
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
                try await self.session.collect(
                    amountMinorUnits: amountMinorUnits,
                    currencyCode: currencyCode,
                    reference: reference,
                    stripeAccount: stripeAccount,
                    organizationName: organizationName
                )
            }
        } catch {
            await cancelCollect()
            if error is CancellationError || TapToPayCollectUI.isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
    }

    /// 60 seconds, then the tap is abandoned and the gift stays unpaid on What.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
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
}

// MARK: - Exception shield

/// Stripe Terminal reports integration mistakes — a missing Info.plist key, a
/// call it considers illegal in the current state — by raising NSException,
/// which Swift cannot catch and which kills the process mid-capture with
/// SIGABRT. Route every SDK entry point through the ObjC shim so an assertion
/// becomes an alert on What carrying Stripe's own reason, and a fault in the
/// log naming the call that raised.
@MainActor
private func catchingTerminalException<T>(
    _ label: StaticString,
    _ work: () -> T
) throws -> T {
    var result: T?
    var nsError: NSError?
    let ok = FFCatchException({ result = work() }, &nsError)
    guard ok, let value = result else {
        let reason = nsError?.localizedDescription ?? "Stripe Terminal failed."
        AppLog.payments.fault(
            "Terminal raised during \(String(describing: label), privacy: .public): \(reason, privacy: .public)"
        )
        throw ProcessorError.server(status: 500, message: reason)
    }
    return value
}

// MARK: - Session

/// All Stripe Terminal work, on the main actor. Terminal delivers delegate
/// callbacks and completion blocks on the main thread, so main-actor isolation
/// removes every lock this file used to need: only one step of one collect is
/// ever outstanding, and only one place resumes it.
@MainActor
final class TapToPayTerminalSession {

    /// Owned for the life of the process. Stripe asks for a fresh connection
    /// token during connect and again during confirm; a provider that only the
    /// `initWithTokenProvider` call ever referenced is deallocated by then.
    private static let tokenProvider = FieldForgeConnectionTokenProvider()
    private static var didInstallTokenProvider = false
    private static let terminalDelegate = FieldForgeTerminalDelegate()

    private let readerDelegate = FieldForgeTapToPayReaderDelegate()

    /// Kept across collects. A connected reader is never rediscovered.
    private var reader: Reader?
    private var locationId = ""

    /// The step that is currently waiting on Stripe. One collect runs one step
    /// at a time, so a single slot covers discovery, connect, retrieve and
    /// confirm. `abort` unblocks the awaiting step if Stripe never calls back.
    private var outstandingCancelable: Cancelable?
    private var abortOutstanding: (() -> Void)?

    init() {
        readerDelegate.onDisconnect = { [weak self] in
            self?.reader = nil
        }
    }

    // MARK: Collect

    func collect(
        amountMinorUnits: Int,
        currencyCode: String,
        reference: String,
        stripeAccount: String?,
        organizationName: String
    ) async throws -> ProcessorChargeResult {

        // Between steps there is no Stripe callback to interrupt, so the only
        // thing that honours a cancel here is checking for one. The gaps are
        // real: two Azure round trips sit inside this method.
        try Task.checkCancellation()
        try await connectIfNeeded()

        try Task.checkCancellation()
        let clientSecret = try await createCardPresentIntent(
            amountMinorUnits: amountMinorUnits,
            fundName: reference,
            organizationName: organizationName,
            stripeAccount: stripeAccount
        )

        try Task.checkCancellation()

        let retrieved: PaymentIntent = try await awaitingStripe { finish in
            try catchingTerminalException("retrievePaymentIntent") {
                Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { intent, error in
                    finish(intent, error)
                }
            }
            return nil
        }

        // "Hold card to top of iPhone". The reader is already connected, so
        // nothing on this path can start discovery.
        let confirmed: PaymentIntent = try await awaitingStripe { finish in
            try catchingTerminalException("processPaymentIntent") {
                Terminal.shared.processPaymentIntent(
                    retrieved,
                    collectConfig: nil,
                    confirmConfig: nil
                ) { intent, error in
                    finish(intent, error)
                }
            }
        }

        let status = Terminal.stringFromPaymentIntentStatus(confirmed.status)
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

    // MARK: Connect

    private func connectIfNeeded() async throws {
        guard TapToPayEntitlement.canAcceptContactlessOnThisBuild else {
            throw TapToPayCollectError.deviceOrEntitlement
        }

        // Azure first. A missing Terminal location is an alert on What, not a
        // discovery attempt — `discoverReaders` without a location is the call
        // that fails in the least explainable way.
        let token = try await FieldForgeConnectionTokenProvider.fetch()
        guard !token.locationId.isEmpty else {
            throw TapToPayCollectError.missingLocation
        }
        locationId = token.locationId
        try Task.checkCancellation()

        try installTokenProviderIfNeeded()

        if Terminal.shared.connectionStatus == .connected { return }
        // A reader we kept but are no longer connected to is stale.
        reader = nil

        let supported = try catchingTerminalException("supportsReaders") {
            Terminal.shared.supportsReaders(
                of: .tapToPay,
                discoveryMethod: .tapToPay,
                simulated: false
            )
        }
        if case .failure(let error) = supported {
            throw error
        }

        let attempt = TapToPayConnectAttempt(
            locationId: locationId,
            readerDelegate: readerDelegate
        )
        abortOutstanding = { [weak attempt] in attempt?.cancel() }
        defer { abortOutstanding = nil }

        do {
            reader = try await attempt.run()
        } catch {
            reader = nil
            throw error
        }

        guard Terminal.shared.connectionStatus == .connected else {
            reader = nil
            throw ProcessorError.server(status: 503, message: "Tap to Pay is not connected.")
        }
    }

    private func installTokenProviderIfNeeded() throws {
        guard !Self.didInstallTokenProvider else { return }
        try catchingTerminalException("initialize") {
            if !Terminal.isInitialized() {
                Terminal.initWithTokenProvider(Self.tokenProvider)
            }
            // Connection status and payment status, for the log. Set once, and
            // before anything asks Terminal to do work.
            Terminal.shared.delegate = Self.terminalDelegate
        }
        Self.didInstallTokenProvider = true
    }

    // MARK: Cancel

    /// Cancels whatever Stripe step is outstanding and unblocks the awaiting
    /// caller. Safe when idle, and never cancels a finished step.
    func cancelOutstanding() {
        let cancelable = outstandingCancelable
        outstandingCancelable = nil
        cancelable?.cancel { _ in }
        let abort = abortOutstanding
        abortOutstanding = nil
        abort?()
    }

    /// Bridges one Stripe completion block to `async`. `start` runs on the main
    /// actor, hands back the step's `Cancelable` if it has one, and reports
    /// through `finish` exactly once — later callbacks are dropped rather than
    /// resuming a continuation twice.
    private func awaitingStripe<T>(
        _ start: @escaping @MainActor (@escaping (T?, Error?) -> Void) throws -> Cancelable?
    ) async throws -> T {
        let once = StripeOnce<T>()
        abortOutstanding = { [weak once] in once?.deliver(nil, CancellationError()) }
        defer {
            abortOutstanding = nil
            outstandingCancelable = nil
        }
        return try await once.run { finish in
            do {
                self.outstandingCancelable = try start(finish)
            } catch {
                // The Terminal call raised before it could take the completion
                // block; fail this step instead of the process.
                once.deliver(nil, error)
            }
        }
    }
}

// MARK: - One connect attempt

/// A single `discoverReaders` and the `connectReader` it leads to.
///
/// Connect is started from `didUpdateDiscoveredReaders`, which is the sample's
/// shape and the reason discovery is only ever started once: a successful
/// connect is what ends discovery, so there is no window in which a second
/// discovery could be started underneath the hold-card sheet.
@MainActor
private final class TapToPayConnectAttempt: NSObject, DiscoveryDelegate {

    private let locationId: String
    private let readerDelegate: TapToPayReaderDelegate

    private var continuation: CheckedContinuation<Reader, Error>?
    private var isFinished = false
    private var didStartConnect = false
    private var discoverCancelable: Cancelable?

    init(locationId: String, readerDelegate: TapToPayReaderDelegate) {
        self.locationId = locationId
        self.readerDelegate = readerDelegate
        super.init()
    }

    func run() async throws -> Reader {
        // A cancel that landed before discovery even started (the 60s timer
        // and the staffer's Cancel race this method) must not start it.
        guard !isFinished else { throw CancellationError() }
        let config = try TapToPayDiscoveryConfigurationBuilder().build()
        return try await withTaskCancellationHandler {
            try await runDiscovery(config)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func runDiscovery(_ config: TapToPayDiscoveryConfiguration) async throws -> Reader {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if isFinished {
                self.continuation = nil
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                self.discoverCancelable = try catchingTerminalException("discoverReaders") {
                    Terminal.shared.discoverReaders(
                        config,
                        delegate: self
                    ) { error in
                        // Discovery has stopped. A successful connect stops it
                        // with no error, and that case has already finished
                        // this attempt.
                        Task { @MainActor [weak self] in
                            guard let self, !self.isFinished else { return }
                            if let error {
                                self.finish(.failure(error))
                            } else if !self.didStartConnect {
                                self.finish(.failure(ProcessorError.server(
                                    status: 503,
                                    message: "This iPhone could not start Tap to Pay."
                                )))
                            }
                        }
                    }
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    nonisolated func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        let first = readers.first
        Task { @MainActor [weak self] in
            guard let self, let reader = first else { return }
            guard !self.isFinished, !self.didStartConnect else { return }
            self.didStartConnect = true
            self.connect(to: reader)
        }
    }

    private func connect(to reader: Reader) {
        let config: TapToPayConnectionConfiguration
        do {
            // Merchant display name defaults to the app's name; passing an
            // explicit nil into the ObjC builder is a needless risk.
            config = try TapToPayConnectionConfigurationBuilder(
                delegate: readerDelegate,
                locationId: locationId
            )
            .setTosAcceptancePermitted(true)
            .build()
        } catch {
            finish(.failure(error))
            return
        }

        do {
            try catchingTerminalException("connectReader") {
                Terminal.shared.connectReader(reader, connectionConfig: config) { connected, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let connected {
                            self.finish(.success(connected))
                        } else {
                            self.finish(.failure(error ?? ProcessorError.server(
                                status: 503,
                                message: TapToPayCollectUI.contactlessFailureMessage
                            )))
                        }
                    }
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    /// Only reached from the timeout or the staffer's Cancel. Discovery that
    /// already produced a reader is left alone — cancelling it is what used to
    /// abort the session under the hold-card sheet.
    func cancel() {
        if !didStartConnect {
            let cancelable = discoverCancelable
            discoverCancelable = nil
            cancelable?.cancel { _ in }
        }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Reader, Error>) {
        guard !isFinished else { return }
        isFinished = true
        discoverCancelable = nil
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let reader):
            continuation.resume(returning: reader)
        case .failure(let error):
            if TapToPayCollectUI.isCancellation(error) {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Resumes at most once. Stripe can call a completion block again after the
/// step is over — most often the discover completion firing with a nil error
/// once a connect ended discovery — and a second resume of a checked
/// continuation traps.
@MainActor
private final class StripeOnce<T> {

    private var continuation: CheckedContinuation<T, Error>?
    private var isFinished = false

    /// A checked continuation is not cancellation-aware on its own: cancelling
    /// the surrounding task sets a flag and then waits forever for a Stripe
    /// completion block that may never come. The handler is what turns Cancel
    /// and the 60s timeout into an actual resume.
    func run(_ start: (@escaping (T?, Error?) -> Void) -> Void) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if isFinished {
                    // Cancelled between the check above and getting here.
                    self.continuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                start { value, error in
                    Task { @MainActor [weak self] in
                        self?.deliver(value, error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.deliver(nil, CancellationError())
            }
        }
    }

    func deliver(_ value: T?, _ error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        guard let continuation else { return }
        self.continuation = nil
        if let value {
            continuation.resume(returning: value)
            return
        }
        if let error {
            if TapToPayCollectUI.isCancellation(error) {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
            return
        }
        continuation.resume(throwing: ProcessorError.server(
            status: 503,
            message: TapToPayCollectUI.contactlessFailureMessage
        ))
    }
}

// MARK: - PaymentIntent from Azure

extension TapToPayTerminalSession {

    fileprivate func createCardPresentIntent(
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
        guard let url = StripePaymentSettings.shared.createPaymentIntentURL else {
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

    /// `POST /api/connection-token` with an amount returns a `card_present`
    /// client secret alongside the connection token. Older deployments answer
    /// without one; that is not an error, it just means the separate
    /// create-payment-intent route is used instead.
    private func createIntentViaConnectionToken(
        amountMinorUnits: Int,
        fundName: String,
        organizationName: String,
        stripeAccount: String?
    ) async throws -> String? {
        guard let url = StripePaymentSettings.shared.terminalConnectionTokenURL else { return nil }

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
            locationId = reply.resolvedLocation
        }
        if (200..<300).contains(http.statusCode) {
            if let secret = reply.resolvedClientSecret, !secret.isEmpty { return secret }
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
            locationId = reply.resolvedLocation
        }
        if let message = reply.error, message == TapToPayCollectUI.missingLocationMessage {
            throw TapToPayCollectError.missingLocation
        }
        guard (200..<300).contains(http.statusCode), let secret = reply.resolvedSecret, !secret.isEmpty else {
            throw ProcessorError.server(status: http.statusCode, message: reply.error ?? "")
        }
        return secret
    }
}

// MARK: - Delegates

/// Terminal-wide status, for the log. Both methods are optional; nothing in the
/// capture flow depends on them.
private final class FieldForgeTerminalDelegate: NSObject, TerminalDelegate {

    func terminal(_ terminal: Terminal, didChangeConnectionStatus status: ConnectionStatus) {
        AppLog.payments.info("Terminal connection status \(status.rawValue, privacy: .public)")
    }

    func terminal(_ terminal: Terminal, didChangePaymentStatus status: PaymentStatus) {
        AppLog.payments.info("Terminal payment status \(status.rawValue, privacy: .public)")
    }
}

private final class FieldForgeTapToPayReaderDelegate: NSObject, TapToPayReaderDelegate {

    var onDisconnect: (() -> Void)?

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

// MARK: - Connection token

/// Owned by `TapToPayTerminalSession` for the life of the process. Stripe holds
/// this weakly and calls it again during connect and confirm.
final class FieldForgeConnectionTokenProvider: NSObject, ConnectionTokenProvider {

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

    /// `POST /api/connection-token` on Azure. `STRIPE_SECRET_KEY` and
    /// `STRIPE_TERMINAL_LOCATION_ID` live there; neither is ever on this iPhone.
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
