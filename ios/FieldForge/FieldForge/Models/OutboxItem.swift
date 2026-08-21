//
//  OutboxItem.swift
//  FieldForge
//
//  The offline promise, made concrete. Anything the app could not do because
//  there were no bars becomes a row here, survives relaunch and force-quit,
//  and is retried when the network returns.
//
//  Deliberately not a generic job queue: three kinds of work, each with an
//  explicit payload, so a corrupted or unknown row can be skipped and reported
//  rather than crashing a launch.
//

import Foundation
import SwiftData

@Model
final class OutboxItem {

    var id: UUID = UUID()

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var kindRawValue: String = OutboxKind.emailDocument.rawValue
    var kind: OutboxKind {
        get { OutboxKind(rawValue: kindRawValue) ?? .emailDocument }
        set { kindRawValue = newValue.rawValue }
    }

    var createdAt: Date = Date.now

    /// The object this work is about. Stored as a plain UUID rather than a
    /// relationship so a failed row can never keep a deleted document alive,
    /// and so the queue can be drained without loading the graph.
    var subjectID: UUID = UUID()

    /// Small JSON blob with the specifics — recipient address, message body,
    /// coordinates to geocode. Read through the typed accessors below.
    var payload: Data?

    var attemptCount: Int = 0
    var lastAttemptAt: Date?
    var lastError: String = ""

    /// Set once the work is done. Completed rows are kept for a week so the
    /// Outbox screen can show "3 sent" rather than going mysteriously empty.
    var completedAt: Date?

    /// Stops retrying. Set after too many failures, or when the user gives up
    /// on an item — the record stays so nothing silently disappears.
    var isAbandoned: Bool = false

    init(kind: OutboxKind, subjectID: UUID, payload: Data? = nil) {
        self.kindRawValue = kind.rawValue
        self.subjectID = subjectID
        self.payload = payload
    }

    var isPending: Bool { completedAt == nil && !isAbandoned }

    /// Exponential backoff, capped at an hour, so a permanently broken row does
    /// not burn battery on a walking route.
    var nextRetryAllowedAt: Date {
        guard let lastAttemptAt else { return createdAt }
        let delay = min(3600, pow(2.0, Double(min(attemptCount, 12))) * 5)
        return lastAttemptAt.addingTimeInterval(delay)
    }

    var isReadyToRetry: Bool {
        isPending && nextRetryAllowedAt <= .now
    }

    /// Five failures is enough to stop guessing and tell the user instead.
    var hasExhaustedRetries: Bool { attemptCount >= 5 }

    func recordFailure(_ message: String) {
        attemptCount += 1
        lastAttemptAt = .now
        lastError = message
        if hasExhaustedRetries { isAbandoned = true }
    }

    func recordSuccess() {
        completedAt = .now
        lastError = ""
    }

    // MARK: Typed payloads

    struct EmailPayload: Codable {
        var recipient: String
        var subject: String
        var body: String
        var fileName: String
    }

    struct GeocodePayload: Codable {
        var latitude: Double
        var longitude: Double
        /// `true` when the target is a Visit, `false` for a Contact.
        var targetIsVisit: Bool
    }

    func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(type, from: payload)
    }

    static func encodePayload<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
