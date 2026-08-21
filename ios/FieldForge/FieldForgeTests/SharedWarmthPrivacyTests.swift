//
//  SharedWarmthPrivacyTests.swift
//  FieldForgeTests
//
//  The fourth mechanism protecting private notes.
//
//  The other three are compile-time: the projection type has no field for
//  private notes, the CloudKit record is built from the projection rather than
//  from a `Contact`, and the two live in separate store files. This file is the
//  runtime backstop — it writes a sentinel string into every private field it
//  can find, runs a full projection, and fails if that string appears anywhere
//  in the output.
//
//  If somebody later adds `privateNotes` to the projection "just for
//  convenience", these tests break loudly and immediately.
//

import CloudKit
import Foundation
import SwiftData
import Testing
@testable import FieldForge

@MainActor
struct SharedWarmthPrivacyTests {

    /// Distinctive enough that a substring search cannot produce a false
    /// negative, and obviously a test value if it ever does leak into a log.
    private static let sentinel = "ZZZ-PRIVATE-CANARY-8f21-DO-NOT-SHARE"

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
    }

    /// A contact with a sentinel in every private field, plus plenty of
    /// legitimate shared content so the test is not passing by accident on an
    /// empty record.
    private func makeSaturatedContact(in context: ModelContext) -> Contact {
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107")
        context.insert(organization)

        let contact = Contact(name: "Delgado Hardware", kind: .business)
        contact.organization = organization
        contact.contactPersonName = "Ana Delgado"
        contact.contactPersonTitle = "Owner"
        contact.sharedNotes = "Ana is happy to host the winter drive."
        contact.tags = ["main street", "matches gifts"]
        contact.contactWindow = .afternoon
        contact.latitude = 42.2588
        contact.longitude = -89.0940
        contact.isSharedWithTeam = true

        // Everything that must never leave the device.
        contact.privateNotes = Self.sentinel
        contact.phone = Self.sentinel
        contact.email = Self.sentinel
        contact.addressLine1 = Self.sentinel
        contact.addressLine2 = Self.sentinel
        contact.postalCode = Self.sentinel
        contact.doNotContactReason = Self.sentinel
        context.insert(contact)

        let visit = Visit(occurredAt: .now, outcome: .gaveNow, warmth: .champion)
        visit.contact = contact
        visit.notes = "Spoke with Ana for twenty minutes."
        visit.privateNotes = Self.sentinel
        visit.resolvedAddress = Self.sentinel
        context.insert(visit)

        let gift = Gift(amount: Money(dollars: 500), method: .applePay)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        gift.transactionIdentifier = Self.sentinel
        gift.paymentInstrumentDescription = Self.sentinel
        gift.referenceNumber = Self.sentinel
        gift.notes = Self.sentinel
        context.insert(gift)

        contact.recomputeRollups()
        return contact
    }

    // MARK: The guarantee

    @Test("No private field survives the projection")
    func projectionCarriesNoPrivateData() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contact = makeSaturatedContact(in: context)
        try context.save()

        let projection = SharedContactProjection(contactID: contact.id, teamZoneName: "TeamWarmth")
        projection.update(from: contact, updatedBy: "Maritza")

        // Every string-shaped property on the projection, checked by hand
        // rather than by reflection so a new field forces a decision here.
        let strings = [
            projection.displayName,
            projection.subtitleLine,
            projection.kindRawValue,
            projection.contactWindowRawValue,
            projection.sharedNotes,
            projection.currencyCode,
            projection.lastUpdatedByDisplayName,
            projection.teamZoneName,
            projection.lastKnownChangeTag,
        ] + projection.tags

        for value in strings {
            #expect(
                !value.contains(Self.sentinel),
                "The sentinel reached a projection field: \(value)"
            )
        }
    }

    @Test("No private field survives into the CloudKit record")
    func recordCarriesNoPrivateData() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contact = makeSaturatedContact(in: context)
        try context.save()

        let projection = SharedContactProjection(contactID: contact.id, teamZoneName: "TeamWarmth")
        projection.update(from: contact, updatedBy: "Maritza")

        let zoneID = CKRecordZone.ID(zoneName: "TeamWarmth", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(
            recordType: SharedContactProjection.recordType,
            recordID: CKRecord.ID(recordName: projection.recordName, zoneID: zoneID)
        )
        projection.apply(to: record)

        // Walk every key actually present on the record, not just the ones we
        // expected to write. If `apply(to:)` ever sets something extra, this
        // catches it.
        for key in record.allKeys() {
            let described = String(describing: record[key] as Any)
            #expect(
                !described.contains(Self.sentinel),
                "The sentinel reached CloudKit under key '\(key)'"
            )
        }
    }

    @Test("The record writes only the declared keys, and nothing else")
    func recordKeysAreExactlyTheDeclaredSet() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contact = makeSaturatedContact(in: context)
        try context.save()

        let projection = SharedContactProjection(contactID: contact.id, teamZoneName: "TeamWarmth")
        projection.update(from: contact, updatedBy: "Maritza")

        let record = CKRecord(recordType: SharedContactProjection.recordType)
        projection.apply(to: record)

        let declared = Set(SharedContactProjection.Key.all)
        let written = Set(record.allKeys())
        let undeclared = written.subtracting(declared)
        #expect(undeclared.isEmpty, "Undeclared keys written to CloudKit: \(undeclared)")
    }

    @Test("There is no key whose name suggests private content")
    func noPrivateSoundingKeys() {
        // A crude but genuinely useful guard: somebody adding a private field
        // to the projection would almost certainly name it recognisably.
        let forbidden = ["private", "phone", "email", "address", "transaction", "card", "signature", "payment"]
        for key in SharedContactProjection.Key.all {
            let lower = key.lowercased()
            for word in forbidden {
                #expect(!lower.contains(word), "Key '\(key)' looks like private data")
            }
        }
    }

    @Test("The disclosure shown to the staffer matches what is actually sent")
    func disclosureIsHonest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contact = makeSaturatedContact(in: context)
        try context.save()

        let disclosed = SharedContactProjection.disclosureLines(for: contact)
        // The disclosure must not itself leak the private fields it is
        // describing — a consent screen that prints the secret is worse than
        // no consent screen.
        for line in disclosed {
            #expect(!line.contains(Self.sentinel), "The disclosure leaked private content: \(line)")
        }
        // And it has to actually mention the things that do go.
        #expect(disclosed.contains { $0.contains("Delgado Hardware") })
        #expect(disclosed.contains { $0.lowercased().contains("warmth") })
        #expect(disclosed.contains { $0.lowercased().contains("giving") })

        let withheld = SharedContactProjection.withheldLines(for: contact)
        #expect(withheld.contains { $0.lowercased().contains("private notes") })
        #expect(withheld.contains { $0.lowercased().contains("phone") })
    }

    // MARK: Merge behaviour

    @Test("Do-not-contact is sticky across a merge, even from a stale record")
    func doNotContactIsSticky() {
        let local = SharedContactProjection(contactID: UUID(), teamZoneName: "TeamWarmth")
        local.displayName = "Corner Laundromat"
        local.isDoNotContact = true
        local.updatedAt = Date(timeIntervalSince1970: 1_000)

        // A teammate's record that is newer but does not know about the request.
        let remote = SharedContactProjection(contactID: local.contactID, teamZoneName: "TeamWarmth")
        remote.displayName = "Corner Laundromat"
        remote.isDoNotContact = false
        remote.warmthRawValue = Warmth.warm.rawValue
        remote.updatedAt = Date(timeIntervalSince1970: 9_999)

        local.merge(remote: remote)

        // The newer record wins on everything else…
        #expect(local.warmth == .warm)
        // …but nothing resurrects a contact who asked to be left alone.
        #expect(local.isDoNotContact)
    }

    @Test("A newer local record is not overwritten by a stale remote one")
    func lastWriterWins() {
        let local = SharedContactProjection(contactID: UUID(), teamZoneName: "TeamWarmth")
        local.sharedNotes = "Newer local note"
        local.warmthRawValue = Warmth.champion.rawValue
        local.updatedAt = Date(timeIntervalSince1970: 9_999)

        let remote = SharedContactProjection(contactID: local.contactID, teamZoneName: "TeamWarmth")
        remote.sharedNotes = "Older remote note"
        remote.warmthRawValue = Warmth.cool.rawValue
        remote.updatedAt = Date(timeIntervalSince1970: 1_000)

        local.merge(remote: remote)
        #expect(local.sharedNotes == "Newer local note")
        #expect(local.warmth == .champion)
        // A merge always clears the dirty flag: the two sides have now been
        // reconciled, whichever one won.
        #expect(!local.needsUpload)
    }

    @Test("A record with no join key is rejected rather than orphaned")
    func recordWithoutContactIDIsRejected() {
        let record = CKRecord(recordType: SharedContactProjection.recordType)
        record[SharedContactProjection.Key.displayName] = "Mystery" as CKRecordValue
        #expect(SharedContactProjection.fromRecord(record, teamZoneName: "TeamWarmth") == nil)
    }

    @Test("A round trip through CloudKit preserves the shared facts")
    func roundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let contact = makeSaturatedContact(in: context)
        try context.save()

        let original = SharedContactProjection(contactID: contact.id, teamZoneName: "TeamWarmth")
        original.update(from: contact, updatedBy: "Maritza")

        let record = CKRecord(recordType: SharedContactProjection.recordType)
        original.apply(to: record)

        let decoded = try #require(
            SharedContactProjection.fromRecord(record, teamZoneName: "TeamWarmth")
        )
        #expect(decoded.contactID == original.contactID)
        #expect(decoded.displayName == original.displayName)
        #expect(decoded.warmth == original.warmth)
        #expect(decoded.contactWindow == original.contactWindow)
        #expect(decoded.sharedNotes == original.sharedNotes)
        #expect(decoded.tags == original.tags)
        #expect(decoded.lifetimeGivingMinorUnits == original.lifetimeGivingMinorUnits)
        #expect(decoded.giftCount == original.giftCount)
        #expect(decoded.isRemote)
        #expect(!decoded.needsUpload)
    }

    @Test("The two stores are separate files, so the boundary is physical")
    func storesAreSeparate() {
        let shared = Persistence.sharedWarmthConfiguration
        // The projection store is its own file, separate from the private one.
        // (Whether SwiftData mirrors it is asserted by construction rather than
        // here: `ModelConfiguration.CloudKitDatabase` is not documented as
        // Equatable, so comparing it would be testing the SDK, not this app.)
        #expect(shared.url.lastPathComponent.contains("Shared"))
        #expect(shared.url != URL.applicationSupportDirectory.appending(path: "FieldForge.store"))
        // And the private schema does not contain the projection, nor the
        // shared schema the private models.
        let sharedTypes = Persistence.sharedSchema.entities.map(\.name)
        #expect(sharedTypes.contains("SharedContactProjection"))
        #expect(!sharedTypes.contains("Contact"))
        #expect(!sharedTypes.contains("Visit"))

        let privateTypes = Persistence.privateSchema.entities.map(\.name)
        #expect(privateTypes.contains("Contact"))
        #expect(!privateTypes.contains("SharedContactProjection"))
    }
}
