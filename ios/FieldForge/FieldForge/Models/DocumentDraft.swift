//
//  DocumentDraft.swift
//  FieldForge
//
//  The in-flight state of the capture flow. Not a SwiftData model: a draft is
//  a value type that gets encoded to a single file on every mutation, so a
//  crash, a phone call, or a dead battery halfway through signing a letter
//  loses nothing and resumes exactly where it was.
//
//  Committing a draft (see `DraftCommitter`) is what creates the real Visit,
//  Gift, and GeneratedDocument records. Until then nothing pollutes the store.
//

import Foundation

/// Everything the four-step capture flow collects, in one Codable value.
struct DocumentDraft: Codable, Equatable, Identifiable {

    var id: UUID = UUID()
    var startedAt: Date = .now
    var updatedAt: Date = .now

    // MARK: Step 1 — Who

    /// Set when the staffer picked an existing contact.
    var existingContactID: UUID?

    /// Set when a `Visit` has already been committed for this interaction —
    /// which is what a one-shot scan does before the flow even opens.
    ///
    /// Without this, committing the draft would create a *second* visit for the
    /// same doorstep, double-counting the day's doors and the conversion rate.
    var committedVisitID: UUID?

    /// Filled in when creating someone new, or when OCR pre-filled fields.
    var newContact = NewContactFields()

    // MARK: Step 2 — What

    var amountText: String = ""
    var method: GiftMethod = .cash
    var fundName: String = ""
    var referenceNumber: String = ""
    var giftDate: Date = .now
    var giftNotes: String = ""

    var inKindDescription: String = ""
    var inKindQuantityText: String = ""
    var donorEstimatedValueText: String = ""

    var providedGoodsOrServices: Bool = false
    var goodsOrServicesDescription: String = ""
    var goodsOrServicesValueText: String = ""

    /// Written by `PaymentCoordinator` once a card or Apple Pay payment
    /// clears. A draft with these set must not be edited back to a lower
    /// amount, and the UI locks the amount field accordingly.
    var confirmedTransactionIdentifier: String = ""
    var confirmedInstrumentDescription: String = ""
    var confirmedPayerName: String = ""
    var isPaymentConfirmed: Bool = false

    // MARK: Step 3 — Document

    var documentKind: DocumentKind = .receipt

    /// PNG of the signature captured for this document, if any. Base64 in the
    /// encoded draft; a few kilobytes, which is fine for a resume file.
    var signaturePNG: Data?
    var useSavedSignature: Bool = true

    /// Overrides the organization's default signatory for this one document.
    var signatoryNameOverride: String = ""
    var signatoryTitleOverride: String = ""

    // MARK: Step 4 — Relationship and delivery

    var warmth: Warmth = .unrated
    var outcome: VisitOutcome = .gaveNow
    var visitNotes: String = ""
    var visitNotesWereDictated: Bool = false
    var tagsToAdd: [String] = []
    var contactWindow: ContactWindow = .unknown

    var wantsFollowUp: Bool = false
    var followUpKind: FollowUpKind = .thankYou
    var followUpDate: Date = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    var followUpNote: String = ""

    var recipientEmail: String = ""
    var shouldEmailDocument: Bool = false

    // MARK: Location, captured at step 1 and frozen

    var latitude: Double?
    var longitude: Double?
    var locationAccuracyMeters: Double?

    /// IDs of attachments already written to the store (photos are saved
    /// immediately rather than held in the draft — a photo is too valuable to
    /// keep only in a resume file).
    var attachmentIDs: [UUID] = []

    // MARK: Derived

    var amount: Money {
        Money.parse(amountText) ?? .zero
    }

    var donorEstimatedValue: Money {
        Money.parse(donorEstimatedValueText) ?? .zero
    }

    var goodsOrServicesValue: Money {
        Money.parse(goodsOrServicesValueText) ?? .zero
    }

    var inKindQuantity: Int {
        Int(inKindQuantityText.filter(\.isNumber)) ?? 0
    }

    var isInKind: Bool { method.isInKind }

    /// Whether step 1 has enough to move on. One field: a name, or a chosen
    /// contact. That is the bar, on purpose.
    var hasWho: Bool {
        existingContactID != nil || newContact.name.trimmedOrNil != nil
    }

    /// Whether step 2 has enough to move on.
    var hasWhat: Bool {
        if isInKind { return inKindDescription.trimmedOrNil != nil }
        return amount.isPositive
    }

    /// A gift of zero with no in-kind description is a visit, not a donation —
    /// and that is a completely valid thing to record. The flow branches here
    /// rather than forcing a fake amount.
    var isVisitOnly: Bool {
        !isInKind && !amount.isPositive
    }

    mutating func touch() { updatedAt = .now }

    /// Nested so the OCR parser has one thing to fill in.
    struct NewContactFields: Codable, Equatable {
        var name: String = ""
        var contactPersonName: String = ""
        var contactPersonTitle: String = ""
        var kind: ContactKind = .business
        var source: ContactSource = .manual
        var phone: String = ""
        var email: String = ""
        var addressLine1: String = ""
        var addressLine2: String = ""
        var city: String = ""
        var state: String = ""
        var postalCode: String = ""

        var isEmpty: Bool {
            name.trimmedOrNil == nil
                && contactPersonName.trimmedOrNil == nil
                && phone.trimmedOrNil == nil
                && email.trimmedOrNil == nil
                && addressLine1.trimmedOrNil == nil
        }
    }
}

// MARK: - Resume storage

/// Persists the in-flight draft to a single file in Application Support.
///
/// Not SwiftData, and not `@AppStorage`: writing a draft must be synchronous,
/// cheap, and safe to call on every keystroke, and it must never participate
/// in CloudKit sync — a half-finished letter is nobody else's business.
enum DraftStore {

    private static let fileName = "in-flight-draft.json"

    private static var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent(fileName, conformingTo: .json)
    }

    static func save(_ draft: DocumentDraft) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(draft)
            // Atomic so a crash mid-write cannot leave a truncated draft that
            // fails to decode and takes the resume feature down with it.
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.persistence.error("Could not save draft: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load() -> DocumentDraft? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(DocumentDraft.self, from: data)
        } catch {
            AppLog.persistence.error("Discarding unreadable draft: \(error.localizedDescription, privacy: .public)")
            clear()
            return nil
        }
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var hasDraft: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
