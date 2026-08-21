//
//  GeneratedDocument.swift
//  FieldForge
//
//  A rendered PDF and the frozen facts it was rendered from.
//
//  The snapshot fields are the important design decision here. A donor who
//  moves, or an organization that rebrands, must not retroactively change a
//  receipt issued two years ago — re-rendering from live relationships would
//  do exactly that. So the values that appear on the page are copied onto this
//  record at issue time, and a re-issue is an explicit, audited act.
//

import Foundation
import SwiftData

@Model
final class GeneratedDocument {

    var id: UUID = UUID()

    /// Human-facing number: "RCT-2026-0042". Minted by `DocumentNumberer`, and
    /// never reused — a re-issue keeps the original number and adds a revision.
    var documentNumber: String = ""

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var kindRawValue: String = DocumentKind.receipt.rawValue
    var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRawValue) ?? .receipt }
        set { kindRawValue = newValue.rawValue }
    }

    var issuedAt: Date = Date.now

    /// 0 for the original, 1+ for corrected re-issues. Printed as
    /// "Revised copy" in the header so a donor holding two versions can tell
    /// which is current.
    var revision: Int = 0

    // MARK: Frozen snapshot — what the page actually says

    var recipientName: String = ""
    var recipientAddressBlock: String = ""
    var organizationName: String = ""
    var organizationEIN: String = ""
    var organizationAddressBlock: String = ""
    var signatoryName: String = ""
    var signatoryTitle: String = ""

    var amountMinorUnits: Int = 0
    var currencyCode: String = "USD"
    var deductibleAmountMinorUnits: Int = 0
    var giftMethodLabel: String = ""
    var giftDate: Date = Date.now
    var fundName: String = ""
    var inKindDescription: String = ""

    /// The exact tax paragraph printed, kept verbatim. If the app's wording is
    /// ever improved, old documents still reproduce as they were issued.
    var taxLanguageUsed: String = ""

    // MARK: Files

    /// The rendered PDF. External storage keeps the SQLite row small; a few
    /// hundred of these should not bloat the store.
    @Attribute(.externalStorage) var pdfData: Data?

    /// The signature as drawn for this document, if one was captured. Kept
    /// separately so a document can be re-rendered at a different page size
    /// without losing the ink.
    @Attribute(.externalStorage) var signatureImageData: Data?

    /// SHA-256 of `pdfData`, hex. Cheap tamper-evidence, and it lets the
    /// history screen tell a genuine re-render from a byte-identical one.
    var pdfChecksum: String = ""

    // MARK: Delivery

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var deliveryStateRawValue: String = DeliveryState.saved.rawValue
    var deliveryState: DeliveryState {
        get { DeliveryState(rawValue: deliveryStateRawValue) ?? .saved }
        set { deliveryStateRawValue = newValue.rawValue }
    }

    var recipientEmail: String = ""
    var sentAt: Date?

    /// "Mail", "AirDrop", "Print", "Messages" — how it actually left the phone.
    var deliveryChannel: String = ""
    var deliveryAttempts: Int = 0
    var lastDeliveryError: String = ""

    var createdByDisplayName: String = ""

    // MARK: Relationships

    /// Inverses are on `Gift.documents` and `Organization.documents`.
    var gift: Gift?
    var organization: Organization?

    /// The original, when this record is a re-issue.
    var supersedes: GeneratedDocument?

    init(kind: DocumentKind = .receipt, documentNumber: String = "") {
        self.kindRawValue = kind.rawValue
        self.documentNumber = documentNumber
    }

    // MARK: Derived

    var amount: Money {
        Money(minorUnits: amountMinorUnits, currencyCode: currencyCode)
    }

    var deductibleAmount: Money {
        Money(minorUnits: deductibleAmountMinorUnits, currencyCode: currencyCode)
    }

    var isRevision: Bool { revision > 0 }

    /// "Receipt RCT-2026-0042" — used as the mail subject and the share title.
    var title: String {
        "\(kind.longLabel.capitalizedFirst) \(documentNumber)"
    }

    /// Filename a donor will not be confused by six months from now.
    /// "Acknowledgment-RCT-2026-0042-Riverside-Hardware.pdf"
    var suggestedFileName: String {
        let safeRecipient = recipientName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = [kind.fileStem, documentNumber, safeRecipient]
            .compactMap { $0.trimmedOrNil }
            .joined(separator: "-")
        return "\(stem).pdf"
    }

    var canBeEmailed: Bool {
        recipientEmail.trimmedOrNil != nil && pdfData != nil
    }

    /// One line for the history list.
    var summaryLine: String {
        let amountText = inKindDescription.trimmedOrNil == nil ? amount.formatted : "In-kind"
        return "\(amountText) · \(issuedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Text the search field matches against, precomputed so search stays fast
    /// with thousands of documents and no network.
    var searchIndex: String {
        [
            documentNumber, recipientName, organizationName, fundName,
            inKindDescription, giftMethodLabel, recipientEmail,
            amount.formatted, kind.longLabel
        ]
        .compactMap { $0.trimmedOrNil }
        .joined(separator: " ")
        .lowercased()
    }

    func markSent(channel: String, at date: Date = .now) {
        deliveryState = .sent
        deliveryChannel = channel
        sentAt = date
        lastDeliveryError = ""
    }

    func markQueued() {
        deliveryState = .queued
    }

    func markFailed(_ error: String) {
        deliveryState = .failed
        deliveryAttempts += 1
        lastDeliveryError = error
    }
}

extension String {
    /// "acknowledgment letter" -> "Acknowledgment letter". Unlike
    /// `capitalized`, this leaves the rest of the string alone.
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
