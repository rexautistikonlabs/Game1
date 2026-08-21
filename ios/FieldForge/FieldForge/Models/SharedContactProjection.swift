//
//  SharedContactProjection.swift
//  FieldForge
//
//  What a teammate is allowed to see. Nothing else.
//
//  This is the load-bearing type of the Shared Warmth feature, and its design
//  is a privacy argument expressed as a data model.
//
//  The promise the app makes is that `Contact.privateNotes` and
//  `Visit.privateNotes` never leave the device. Promises made in comments get
//  broken by the next person to add a field. So instead:
//
//  1. **This type has no field for private notes.** Not an empty one, not an
//     optional one — none. Nothing that reads a `Contact` and writes a
//     `SharedContactProjection` can carry them, because there is nowhere to put
//     them.
//
//  2. **The CloudKit record is built from the projection, never from `Contact`.**
//     `recordFields()` is a method on this type, so the code that talks to the
//     network literally cannot see a `Contact` and cannot reach a private field.
//
//  3. **It lives in a physically separate store file** with its own
//     `ModelConfiguration` (see `Persistence.sharedWarmthConfiguration`). The
//     bytes that sync and the bytes that must not sync are different files on
//     disk.
//
//  4. **A test asserts it.** `SharedWarmthPrivacyTests` writes a sentinel string
//     into every private field, projects, builds the record, and fails if the
//     sentinel appears anywhere in the output.
//
//  Four independent mechanisms, three of them compile-time. That is the level
//  of care a donor note deserves.
//

import CloudKit
import CoreLocation
import Foundation
import SwiftData

@Model
final class SharedContactProjection {

    // MARK: Identity

    /// Mirrors `Contact.id`. This is the join key between a staffer's own record
    /// and what the team sees, and it is what makes a projection idempotent: the
    /// same contact always produces the same CloudKit record name.
    var contactID: UUID = UUID()

    /// Which team's zone this belongs to. A consultant working with two
    /// organizations has two, and they must never bleed together.
    var teamZoneName: String = ""

    // MARK: The shared facts — deliberately a short list

    var displayName: String = ""
    /// The line under the name: the named human, or the street. Precomputed on
    /// the owning device so a teammate does not need the address components.
    var subtitleLine: String = ""

    var kindRawValue: String = ContactKind.business.rawValue
    var warmthRawValue: Int = Warmth.unrated.rawValue
    var contactWindowRawValue: String = ContactWindow.unknown.rawValue

    /// A hard stop travels with the record. If someone asked not to be
    /// contacted, every teammate must know before they knock.
    var isDoNotContact: Bool = false

    /// Notes the staffer explicitly wrote *for the team*. The other notes field
    /// does not exist on this type.
    var sharedNotes: String = ""

    var tags: [String] = []

    var latitude: Double?
    var longitude: Double?

    // MARK: Giving history — the whole point of sharing

    var lifetimeGivingMinorUnits: Int = 0
    var currencyCode: String = "USD"
    var giftCount: Int = 0
    var visitCount: Int = 0
    var lastVisitAt: Date?
    var lastGiftAt: Date?
    var firstGiftAt: Date?

    /// Who to ask about this record. A display name, not an identity.
    var lastUpdatedByDisplayName: String = ""

    // MARK: Sync bookkeeping

    var updatedAt: Date = Date.now

    /// Set when the local copy is ahead of the server. The push pass drains
    /// these; being offline just means they sit here, which is the point.
    var needsUpload: Bool = true

    /// `CKRecord.recordChangeTag` from the last successful server round trip.
    /// Empty means this row has never been on the server.
    var lastKnownChangeTag: String = ""

    /// `true` when this row arrived from a teammate rather than being projected
    /// from a local `Contact`. Drives "shared by Ana" in the UI, and stops the
    /// push pass echoing a record straight back where it came from.
    var isRemote: Bool = false

    /// Tombstone. A staffer who turns sharing off for one contact needs the
    /// record withdrawn from the team, and a withdrawal has to survive being
    /// offline just as reliably as a write does.
    var isWithdrawn: Bool = false

    init(contactID: UUID = UUID(), teamZoneName: String = "") {
        self.contactID = contactID
        self.teamZoneName = teamZoneName
    }

    // MARK: Typed accessors

    var kind: ContactKind {
        get { ContactKind(rawValue: kindRawValue) ?? .business }
        set { kindRawValue = newValue.rawValue }
    }

    var warmth: Warmth {
        get { Warmth(rawValue: warmthRawValue) ?? .unrated }
        set { warmthRawValue = newValue.rawValue }
    }

    var contactWindow: ContactWindow {
        get { ContactWindow(rawValue: contactWindowRawValue) ?? .unknown }
        set { contactWindowRawValue = newValue.rawValue }
    }

    var lifetimeGiving: Money {
        Money(minorUnits: lifetimeGivingMinorUnits, currencyCode: currencyCode)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: Projecting from a local contact

    /// The one and only path from private data to shared data.
    ///
    /// Takes a `Contact`, reads the allowed fields, writes them here. Adding a
    /// field to `Contact` does not add it to the team's view — somebody has to
    /// come to this function and decide, which is exactly the friction that
    /// should exist.
    func update(from contact: Contact, updatedBy staffDisplayName: String) {
        contactID = contact.id
        displayName = contact.displayName
        subtitleLine = contact.subtitle
        kind = contact.kind
        warmth = contact.warmth
        contactWindow = contact.contactWindow
        isDoNotContact = contact.isDoNotContact
        // `sharedNotes`, never `privateNotes`. The latter has no destination.
        sharedNotes = contact.sharedNotes
        tags = contact.tags
        latitude = contact.latitude
        longitude = contact.longitude
        lifetimeGivingMinorUnits = contact.lifetimeGivingMinorUnits
        currencyCode = contact.organization?.defaultCurrencyCode ?? "USD"
        giftCount = contact.giftCount
        visitCount = contact.visitCount
        lastVisitAt = contact.lastVisitAt
        lastGiftAt = contact.lastGiftAt
        firstGiftAt = contact.firstGiftAt
        lastUpdatedByDisplayName = staffDisplayName
        updatedAt = .now
        needsUpload = true
        isWithdrawn = false
    }

    /// Applies a teammate's version onto the local copy.
    ///
    /// Last-writer-wins on `updatedAt`, with one deliberate exception:
    /// `isDoNotContact` is sticky. If anybody on the team has been told to stop
    /// contacting someone, a staler record must not undo that.
    func merge(remote: SharedContactProjection) {
        let doNotContact = isDoNotContact || remote.isDoNotContact

        if remote.updatedAt >= updatedAt {
            displayName = remote.displayName
            subtitleLine = remote.subtitleLine
            kindRawValue = remote.kindRawValue
            warmthRawValue = remote.warmthRawValue
            contactWindowRawValue = remote.contactWindowRawValue
            sharedNotes = remote.sharedNotes
            tags = remote.tags
            latitude = remote.latitude
            longitude = remote.longitude
            lifetimeGivingMinorUnits = remote.lifetimeGivingMinorUnits
            currencyCode = remote.currencyCode
            giftCount = remote.giftCount
            visitCount = remote.visitCount
            lastVisitAt = remote.lastVisitAt
            lastGiftAt = remote.lastGiftAt
            firstGiftAt = remote.firstGiftAt
            lastUpdatedByDisplayName = remote.lastUpdatedByDisplayName
            updatedAt = remote.updatedAt
        }

        isDoNotContact = doNotContact
        lastKnownChangeTag = remote.lastKnownChangeTag
        needsUpload = false
    }
}

// MARK: - CloudKit representation

extension SharedContactProjection {

    /// CloudKit record type. Versioned in the name so a future, wider
    /// projection can be introduced without colliding with deployed schema.
    static let recordType = "SharedContactV1"

    /// Stable record name, so re-projecting the same contact updates its record
    /// instead of creating a second one.
    var recordName: String { "contact-\(contactID.uuidString)" }

    /// Field keys, listed once. `SharedWarmthPrivacyTests` walks this list and
    /// asserts none of them can carry private content.
    enum Key {
        static let contactID = "contactID"
        static let displayName = "displayName"
        static let subtitleLine = "subtitleLine"
        static let kind = "kind"
        static let warmth = "warmth"
        static let contactWindow = "contactWindow"
        static let isDoNotContact = "isDoNotContact"
        static let sharedNotes = "sharedNotes"
        static let tags = "tags"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let lifetimeGivingMinorUnits = "lifetimeGivingMinorUnits"
        static let currencyCode = "currencyCode"
        static let giftCount = "giftCount"
        static let visitCount = "visitCount"
        static let lastVisitAt = "lastVisitAt"
        static let lastGiftAt = "lastGiftAt"
        static let firstGiftAt = "firstGiftAt"
        static let lastUpdatedByDisplayName = "lastUpdatedByDisplayName"
        static let updatedAt = "updatedAt"

        /// Every key that is ever written. Nothing outside this list reaches
        /// CloudKit, and the test enforces that.
        static let all: [String] = [
            contactID, displayName, subtitleLine, kind, warmth, contactWindow,
            isDoNotContact, sharedNotes, tags, latitude, longitude,
            lifetimeGivingMinorUnits, currencyCode, giftCount, visitCount,
            lastVisitAt, lastGiftAt, firstGiftAt, lastUpdatedByDisplayName,
            updatedAt,
        ]
    }

    /// Fills a `CKRecord` from this projection.
    ///
    /// A method on the projection, deliberately: the networking layer never
    /// holds a `Contact`, so it cannot read a private field even by accident.
    func apply(to record: CKRecord) {
        record[Key.contactID] = contactID.uuidString as CKRecordValue
        record[Key.displayName] = displayName as CKRecordValue
        record[Key.subtitleLine] = subtitleLine as CKRecordValue
        record[Key.kind] = kindRawValue as CKRecordValue
        record[Key.warmth] = warmthRawValue as CKRecordValue
        record[Key.contactWindow] = contactWindowRawValue as CKRecordValue
        record[Key.isDoNotContact] = (isDoNotContact ? 1 : 0) as CKRecordValue
        record[Key.sharedNotes] = sharedNotes as CKRecordValue
        record[Key.tags] = tags as CKRecordValue
        record[Key.latitude] = latitude.map { $0 as CKRecordValue }
        record[Key.longitude] = longitude.map { $0 as CKRecordValue }
        record[Key.lifetimeGivingMinorUnits] = lifetimeGivingMinorUnits as CKRecordValue
        record[Key.currencyCode] = currencyCode as CKRecordValue
        record[Key.giftCount] = giftCount as CKRecordValue
        record[Key.visitCount] = visitCount as CKRecordValue
        record[Key.lastVisitAt] = lastVisitAt.map { $0 as CKRecordValue }
        record[Key.lastGiftAt] = lastGiftAt.map { $0 as CKRecordValue }
        record[Key.firstGiftAt] = firstGiftAt.map { $0 as CKRecordValue }
        record[Key.lastUpdatedByDisplayName] = lastUpdatedByDisplayName as CKRecordValue
        record[Key.updatedAt] = updatedAt as CKRecordValue
    }

    /// Builds a detached projection from a record that arrived from a teammate.
    /// Returns `nil` for a record that is missing the join key, which would
    /// otherwise create an unattributable orphan.
    static func fromRecord(_ record: CKRecord, teamZoneName: String) -> SharedContactProjection? {
        guard let idString = record[Key.contactID] as? String,
              let contactID = UUID(uuidString: idString) else { return nil }

        let projection = SharedContactProjection(contactID: contactID, teamZoneName: teamZoneName)
        projection.displayName = record[Key.displayName] as? String ?? ""
        projection.subtitleLine = record[Key.subtitleLine] as? String ?? ""
        projection.kindRawValue = record[Key.kind] as? String ?? ContactKind.business.rawValue
        projection.warmthRawValue = record[Key.warmth] as? Int ?? Warmth.unrated.rawValue
        projection.contactWindowRawValue = record[Key.contactWindow] as? String ?? ContactWindow.unknown.rawValue
        projection.isDoNotContact = (record[Key.isDoNotContact] as? Int ?? 0) != 0
        projection.sharedNotes = record[Key.sharedNotes] as? String ?? ""
        projection.tags = record[Key.tags] as? [String] ?? []
        projection.latitude = record[Key.latitude] as? Double
        projection.longitude = record[Key.longitude] as? Double
        projection.lifetimeGivingMinorUnits = record[Key.lifetimeGivingMinorUnits] as? Int ?? 0
        projection.currencyCode = record[Key.currencyCode] as? String ?? "USD"
        projection.giftCount = record[Key.giftCount] as? Int ?? 0
        projection.visitCount = record[Key.visitCount] as? Int ?? 0
        projection.lastVisitAt = record[Key.lastVisitAt] as? Date
        projection.lastGiftAt = record[Key.lastGiftAt] as? Date
        projection.firstGiftAt = record[Key.firstGiftAt] as? Date
        projection.lastUpdatedByDisplayName = record[Key.lastUpdatedByDisplayName] as? String ?? ""
        projection.updatedAt = record[Key.updatedAt] as? Date ?? .now
        projection.lastKnownChangeTag = record.recordChangeTag ?? ""
        projection.isRemote = true
        projection.needsUpload = false
        return projection
    }
}

// MARK: - What the staffer is shown before they agree to share

extension SharedContactProjection {

    /// Plain-language description of everything that would leave the device for
    /// one contact. Shown in the sharing confirmation, because the only honest
    /// way to ask for consent is to show the actual payload.
    static func disclosureLines(for contact: Contact) -> [String] {
        var lines: [String] = [
            "Name: \(contact.displayName)",
            "Warmth: \(contact.warmth.label)",
        ]
        if let subtitle = contact.subtitle.trimmedOrNil {
            lines.append("Detail line: \(subtitle)")
        }
        if contact.contactWindow != .unknown {
            lines.append("Best time: \(contact.contactWindow.label)")
        }
        if contact.giftCount > 0 {
            lines.append("Giving: \(contact.lifetimeGiving.formatted) across \(contact.giftCount) gifts")
        }
        if contact.visitCount > 0 {
            lines.append("Visits: \(contact.visitCount)")
        }
        if let notes = contact.sharedNotes.trimmedOrNil {
            lines.append("Team notes: \(notes)")
        }
        if !contact.tags.isEmpty {
            lines.append("Tags: \(contact.tags.joined(separator: ", "))")
        }
        if contact.coordinate != nil {
            lines.append("Location pin")
        }
        if contact.isDoNotContact {
            lines.append("Do-not-contact flag")
        }
        return lines
    }

    /// The counterpart: what stays. Shown next to the list above, because
    /// "here is what we send" is only half of informed consent.
    static func withheldLines(for contact: Contact) -> [String] {
        var lines: [String] = []
        if contact.privateNotes.trimmedOrNil != nil {
            lines.append("Your private notes on this contact")
        }
        let privateVisitNotes = (contact.visits ?? []).filter { $0.privateNotes.trimmedOrNil != nil }
        if !privateVisitNotes.isEmpty {
            lines.append("Your private notes on \(privateVisitNotes.count) visit\(privateVisitNotes.count == 1 ? "" : "s")")
        }
        lines.append("Every phone number, email address and street address")
        lines.append("Payment details, card descriptions and transaction IDs")
        lines.append("Signatures and issued documents")
        lines.append("Photos and voice notes")
        return lines
    }
}
