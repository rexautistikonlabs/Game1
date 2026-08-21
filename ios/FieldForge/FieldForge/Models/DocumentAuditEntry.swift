//
//  DocumentAuditEntry.swift
//  FieldForge
//
//  The audit trail for issued documents.
//
//  Why this exists as its own model rather than a few fields on
//  `GeneratedDocument`: a document's history is append-only. A receipt handed to
//  a donor is a fact, and everything that happens to it afterwards — sent,
//  re-sent, voided, corrected — is another fact layered on top, not an edit to
//  the first one. Storing that as mutable fields loses the order and loses the
//  reasons, which are exactly what somebody reconstructing a dispute needs.
//
//  Entries are never modified and never deleted, including when the document is
//  voided. A void with no trail is indistinguishable from a mistake.
//

import Foundation
import SwiftData

@Model
final class DocumentAuditEntry {

    var id: UUID = UUID()

    /// When it happened, not when it was written down.
    var occurredAt: Date = Date.now

    private var actionRawValue: String = Action.issued.rawValue
    var action: Action {
        get { Action(rawValue: actionRawValue) ?? .issued }
        set { actionRawValue = newValue.rawValue }
    }

    /// Free text describing the specifics: the email address it went to, the
    /// reason for a void, the failure a delivery hit.
    var detail: String = ""

    /// Who did it. A display name, not an identity.
    var actorDisplayName: String = ""

    /// The document's delivery state immediately after this entry, so the
    /// trail can be read on its own without replaying the whole chain.
    var resultingStateRawValue: String = DeliveryState.saved.rawValue
    var resultingState: DeliveryState {
        get { DeliveryState(rawValue: resultingStateRawValue) ?? .saved }
        set { resultingStateRawValue = newValue.rawValue }
    }

    /// Inverse declared on `GeneratedDocument.auditTrail`.
    var document: GeneratedDocument?

    init(
        action: Action = .issued,
        detail: String = "",
        actorDisplayName: String = "",
        resultingState: DeliveryState = .saved,
        occurredAt: Date = .now
    ) {
        self.actionRawValue = action.rawValue
        self.detail = detail
        self.actorDisplayName = actorDisplayName
        self.resultingStateRawValue = resultingState.rawValue
        self.occurredAt = occurredAt
    }

    /// What can happen to a document.
    enum Action: String, CaseIterable, Codable, Sendable {
        case issued
        case sent
        case queued
        case deliveryFailed
        case printed
        case shared
        case voided
        case reissued
        case supersededByReissue
        case emailChanged

        var label: String {
            switch self {
            case .issued: return "Issued"
            case .sent: return "Sent"
            case .queued: return "Queued to send"
            case .deliveryFailed: return "Delivery failed"
            case .printed: return "Printed"
            case .shared: return "Shared"
            case .voided: return "Voided"
            case .reissued: return "Corrected copy issued"
            case .supersededByReissue: return "Replaced by a corrected copy"
            case .emailChanged: return "Recipient address changed"
            }
        }

        var symbolName: String {
            switch self {
            case .issued: return "doc.badge.plus"
            case .sent: return "paperplane.fill"
            case .queued: return "clock.arrow.circlepath"
            case .deliveryFailed: return "exclamationmark.triangle.fill"
            case .printed: return "printer.fill"
            case .shared: return "square.and.arrow.up"
            case .voided: return "xmark.octagon.fill"
            case .reissued: return "arrow.triangle.2.circlepath"
            case .supersededByReissue: return "arrow.uturn.forward"
            case .emailChanged: return "envelope.badge"
            }
        }

        /// Entries that change what the document *means*, as opposed to what
        /// happened to it. These are shown with emphasis in the trail.
        var isMaterial: Bool {
            switch self {
            case .issued, .voided, .reissued, .supersededByReissue: return true
            case .sent, .queued, .deliveryFailed, .printed, .shared, .emailChanged: return false
            }
        }
    }

    /// One line for the trail list.
    var summaryLine: String {
        let who = actorDisplayName.trimmedOrNil.map { " by \($0)" } ?? ""
        let what = detail.trimmedOrNil.map { " — \($0)" } ?? ""
        return "\(action.label)\(who)\(what)"
    }
}

// MARK: - Recording

extension GeneratedDocument {

    /// Appends to the trail. The only way an audit entry is created, so there is
    /// one place to look when asking whether something is recorded.
    ///
    /// Two deliberate details:
    ///
    /// * **It inserts explicitly** via the document's own `modelContext`.
    ///   SwiftData does propagate inserts through relationships, but the audit
    ///   trail is the one structure in this app whose entire purpose is being
    ///   reliable, and "it probably cascades" is not a good enough basis for
    ///   the record somebody reconstructs a dispute from. When the document is
    ///   not yet in a context — a preview, a test fixture — the relationship
    ///   alone still links them.
    ///
    /// * **It takes no context parameter.** The entry joins whatever
    ///   transaction the caller is already in, so an audit entry can never be
    ///   committed without the change it describes, or the reverse.
    func recordAudit(
        _ action: DocumentAuditEntry.Action,
        detail: String = "",
        actor: String = "",
        at date: Date = .now
    ) {
        let entry = DocumentAuditEntry(
            action: action,
            detail: detail,
            actorDisplayName: actor,
            resultingState: deliveryState,
            occurredAt: date
        )
        // Setting one side is enough — `auditTrail` declares the inverse, so
        // SwiftData populates the array. Appending to it as well would risk a
        // duplicate entry in the in-memory copy.
        entry.document = self
        modelContext?.insert(entry)
    }

    /// The trail, oldest first, which is how a history is read.
    var orderedAuditTrail: [DocumentAuditEntry] {
        (auditTrail ?? []).sorted { $0.occurredAt < $1.occurredAt }
    }

    /// The entry explaining a void, when there is one. `voidedAt` is the
    /// authoritative flag — it is a stored property, so lists and `#Predicate`
    /// can use it without loading the trail; this is where the *reason* lives.
    var voidEntry: DocumentAuditEntry? {
        orderedAuditTrail.last { $0.action == .voided }
    }
}
