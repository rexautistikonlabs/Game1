//
//  Contact.swift
//  FieldForge
//
//  The lightweight CRM record. The design rule for this model: a usable
//  contact must be creatable from a single field. A staffer who only knows
//  "the taqueria on 5th" should be able to save that, attach a photo of the
//  sign, and fill in the rest whenever they feel like it — or never.
//

import CoreLocation
import Foundation
import SwiftData

@Model
final class Contact {

    // MARK: Identity

    var id: UUID = UUID()

    /// The only field the UI insists on. Business name, or a person's name.
    var name: String = ""

    /// Named human at the business — "ask for Dolores". Distinct from `name`
    /// because the letter is addressed to the business but handed to a person.
    var contactPersonName: String = ""
    var contactPersonTitle: String = ""

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var kindRawValue: String = ContactKind.business.rawValue
    var kind: ContactKind {
        get { ContactKind(rawValue: kindRawValue) ?? .business }
        set { kindRawValue = newValue.rawValue }
    }

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var sourceRawValue: String = ContactSource.manual.rawValue
    var source: ContactSource {
        get { ContactSource(rawValue: sourceRawValue) ?? .manual }
        set { sourceRawValue = newValue.rawValue }
    }

    // MARK: Reach

    var phone: String = ""
    var email: String = ""

    // MARK: Address — kept as components so letters address correctly

    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""
    var country: String = ""

    // MARK: Where on earth

    /// Stored separately from the address because coordinates are what we
    /// actually have offline. The address may be filled in later by a queued
    /// reverse-geocode; the pin works immediately either way.
    var latitude: Double?
    var longitude: Double?

    /// `true` once a reverse geocode has produced the address above, so the
    /// outbox does not keep re-requesting it.
    var hasResolvedAddress: Bool = false

    // MARK: The Warmth System

    /// Cached roll-up of this contact's visit ratings, recomputed whenever a
    /// visit is saved. Cached rather than computed so the map and the list can
    /// sort and filter on it without loading every visit.
    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var warmthRawValue: Int = Warmth.unrated.rawValue
    var warmth: Warmth {
        get { Warmth(rawValue: warmthRawValue) ?? .unrated }
        set { warmthRawValue = newValue.rawValue }
    }

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var contactWindowRawValue: String = ContactWindow.unknown.rawValue
    /// When someone actually manages to catch them. One of the most valuable
    /// things a team can share with itself.
    var contactWindow: ContactWindow {
        get { ContactWindow(rawValue: contactWindowRawValue) ?? .unknown }
        set { contactWindowRawValue = newValue.rawValue }
    }

    /// Free-form tags: "restaurant", "board prospect", "matches gifts",
    /// "spanish speaking". Stored as an array of strings, which SwiftData
    /// persists as a transformable and CloudKit accepts.
    var tags: [String] = []

    /// Notes that stay on this device and never appear in shared team memory,
    /// even on the paid tier. Somewhere to write "smells strongly of bleach,
    /// don't linger" without it becoming an organizational record.
    var privateNotes: String = ""

    /// Notes intended for whoever visits next. These are what sync.
    var sharedNotes: String = ""

    /// Hard stop. When true the app refuses to schedule follow-ups, greys the
    /// map pin, and warns before opening the capture flow. Respecting this is
    /// both decent and, for phone and email, legally relevant.
    var isDoNotContact: Bool = false
    var doNotContactReason: String = ""

    // MARK: Cached rollups (kept current by `ContactStatistics`)

    var lifetimeGivingMinorUnits: Int = 0
    var giftCount: Int = 0
    var visitCount: Int = 0
    var lastVisitAt: Date?
    var lastGiftAt: Date?
    var firstGiftAt: Date?

    // MARK: Sharing

    /// Pro tier. When true this record and its visits are readable by the whole
    /// organization; when false it stays on this staffer's device.
    var isSharedWithTeam: Bool = false

    /// Display name of whoever created the record, shown in shared memory so a
    /// staffer knows who to ask about a note. Not an auth identity.
    var createdByDisplayName: String = ""

    // MARK: Bookkeeping

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isArchived: Bool = false

    // MARK: Relationships

    /// Owning organization. No `inverse:` here — `Organization.contacts`
    /// declares it, and SwiftData wants the inverse named on exactly one side.
    var organization: Organization?

    @Relationship(deleteRule: .cascade, inverse: \Visit.contact)
    var visits: [Visit]? = []

    @Relationship(deleteRule: .cascade, inverse: \Gift.contact)
    var gifts: [Gift]? = []

    @Relationship(deleteRule: .cascade, inverse: \FollowUp.contact)
    var followUps: [FollowUp]? = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.contact)
    var attachments: [Attachment]? = []

    init(name: String = "", kind: ContactKind = .business, source: ContactSource = .manual) {
        self.name = name
        self.kindRawValue = kind.rawValue
        self.sourceRawValue = source.rawValue
    }

    // MARK: Derived

    var displayName: String {
        name.trimmedOrNil ?? contactPersonName.trimmedOrNil ?? "Unnamed contact"
    }

    /// The line under the name in lists: the human if we have one, else the
    /// street, else the city — whatever actually helps identify the place.
    var subtitle: String {
        if let person = contactPersonName.trimmedOrNil {
            if let title = contactPersonTitle.trimmedOrNil { return "\(person) · \(title)" }
            return person
        }
        return streetLine.trimmedOrNil ?? cityStateZipLine.trimmedOrNil ?? kind.label
    }

    var streetLine: String {
        [addressLine1, addressLine2].compactMap { $0.trimmedOrNil }.joined(separator: ", ")
    }

    var cityStateZipLine: String {
        let cityState = [city.trimmedOrNil, state.trimmedOrNil].compactMap { $0 }.joined(separator: ", ")
        return [cityState.trimmedOrNil, postalCode.trimmedOrNil].compactMap { $0 }.joined(separator: " ")
    }

    /// The recipient block for a formal letter, one string per printed line.
    var mailingAddressLines: [String] {
        var lines: [String] = []
        if let person = contactPersonName.trimmedOrNil {
            if let title = contactPersonTitle.trimmedOrNil {
                lines.append("\(person), \(title)")
            } else {
                lines.append(person)
            }
        }
        if let orgName = name.trimmedOrNil { lines.append(orgName) }
        if let street = streetLine.trimmedOrNil { lines.append(street) }
        if let cityZip = cityStateZipLine.trimmedOrNil { lines.append(cityZip) }
        if let country = country.trimmedOrNil, country.lowercased() != "united states" {
            lines.append(country)
        }
        return lines
    }

    /// "Dear Dolores," / "Dear Riverside Hardware," / "Dear Friend," — a letter
    /// that opens "Dear ," is worse than one that opens generically.
    var letterSalutation: String {
        if let person = contactPersonName.trimmedOrNil {
            let firstName = person.split(separator: " ").first.map(String.init) ?? person
            return "Dear \(firstName),"
        }
        if let orgName = name.trimmedOrNil { return "Dear \(orgName)," }
        return "Dear Friend,"
    }

    var lifetimeGiving: Money {
        Money(
            minorUnits: lifetimeGivingMinorUnits,
            currencyCode: organization?.defaultCurrencyCode ?? "USD"
        )
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        // (0, 0) is in the Atlantic. It is always a bug, never a donor.
        guard !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasAnyReachMethod: Bool {
        phone.trimmedOrNil != nil || email.trimmedOrNil != nil
    }

    /// Whether a mailed letter would actually arrive.
    var hasMailableAddress: Bool {
        streetLine.trimmedOrNil != nil && cityStateZipLine.trimmedOrNil != nil
    }

    func touch() { updatedAt = .now }

    /// Adds a tag, case-insensitively de-duplicated and trimmed, so "Restaurant"
    /// and "restaurant " do not become two facets of the same idea.
    func addTag(_ tag: String) {
        guard let cleaned = tag.trimmedOrNil else { return }
        let existing = Set(tags.map { $0.lowercased() })
        guard !existing.contains(cleaned.lowercased()) else { return }
        tags.append(cleaned)
        touch()
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        touch()
    }

    /// Recomputes the cached rollups and the warmth score from the record's own
    /// children. Called after any visit or gift changes; cheap enough to be
    /// called liberally, and the single source of truth for these fields.
    func recomputeRollups(now: Date = .now) {
        let allVisits = visits ?? []
        let allGifts = (gifts ?? []).filter { $0.countsTowardGiving }

        visitCount = allVisits.count
        lastVisitAt = allVisits.map(\.occurredAt).max()

        giftCount = allGifts.count
        lifetimeGivingMinorUnits = allGifts.reduce(0) { $0 + $1.amountMinorUnits }
        let giftDates = allGifts.map(\.receivedAt)
        lastGiftAt = giftDates.max()
        firstGiftAt = giftDates.min()

        // A gift is itself strong evidence of warmth, so it participates in the
        // roll-up alongside the explicit ratings.
        var signals: [(warmth: Warmth, date: Date)] = allVisits
            .filter { $0.warmth != .unrated }
            .map { ($0.warmth, $0.occurredAt) }
        signals.append(contentsOf: allGifts.map { (warmth: Warmth.champion, date: $0.receivedAt) })

        warmth = isDoNotContact ? .doNotReturn : Warmth.rollUp(signals, now: now)
        touch()
    }
}
