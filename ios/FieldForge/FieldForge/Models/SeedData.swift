//
//  SeedData.swift
//  FieldForge
//
//  Two jobs:
//
//  1. First launch — create the single empty Organization the app needs to
//     exist before anything else works. No fake donors: a real staffer opening
//     this app for the first time should see their own empty route, not sample
//     data they have to delete before they trust the numbers.
//
//  2. Previews and tests — a small, believable neighbourhood so every SwiftUI
//     preview renders something real and the map has pins in it.
//

import Foundation
import SwiftData

enum SeedData {

    /// Called on every launch. Creates the organization record if the store is
    /// empty and does nothing otherwise. Idempotent by design.
    @MainActor
    static func bootstrapIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Organization>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        let organization = Organization()
        organization.name = ""
        organization.defaultFundName = "General Fund"
        context.insert(organization)
        try? context.save()
        AppLog.persistence.info("Created initial empty organization")
    }

    /// Preview/test fixture. Never called from the shipping app path.
    @MainActor
    static func populate(context: ModelContext) {
        let organization = Organization(
            name: "Riverside Food Collective",
            ein: "36-4829107",
            city: "Rockford",
            state: "IL"
        )
        organization.legalName = "Riverside Food Collective, Inc."
        organization.addressLine1 = "412 South Water Street"
        organization.postalCode = "61104"
        organization.phone = "(779) 555-0142"
        organization.email = "give@riversidefood.example"
        organization.website = "riversidefood.example"
        organization.letterheadTagline = "Nobody in this county eats alone."
        organization.signatoryName = "Maritza Ocampo"
        organization.signatoryTitle = "Director of Development"
        organization.brandColorHex = "#1F5F5B"
        organization.defaultFundName = "Winter Meals Fund"
        context.insert(organization)

        let fixtures: [(String, ContactKind, String, String, Warmth, Double, Double, Int, String)] = [
            ("Delgado Hardware", .business, "Ana Delgado", "Owner", .champion, 42.2588, -89.0940, 50_000, "restaurant supply, matches employee gifts"),
            ("Third Street Taqueria", .business, "Hector Ruiz", "Manager", .warm, 42.2612, -89.0921, 25_000, "best after 2pm"),
            ("Kellerman Dental", .business, "", "", .neutral, 42.2634, -89.0967, 0, ""),
            ("Vine & Barrel", .business, "Priya Raman", "General Manager", .warm, 42.2601, -89.0898, 10_000, ""),
            ("First Presbyterian", .faithCommunity, "Rev. Tom Alder", "Pastor", .champion, 42.2649, -89.0955, 150_000, "hosts our winter drive"),
            ("Northtown Auto Body", .business, "", "", .cool, 42.2705, -89.0882, 0, ""),
            ("Halverson Family Foundation", .foundation, "Beth Halverson", "Trustee", .warm, 42.2570, -89.1002, 500_000, "board meets in March"),
            ("Corner Laundromat", .business, "", "", .doNotReturn, 42.2596, -89.0873, 0, "asked us not to come back"),
        ]

        var contacts: [Contact] = []
        for (index, fixture) in fixtures.enumerated() {
            let (name, kind, person, title, warmth, latitude, longitude, giftCents, note) = fixture
            let contact = Contact(name: name, kind: kind, source: index % 3 == 0 ? .signOCR : .manual)
            contact.organization = organization
            contact.contactPersonName = person
            contact.contactPersonTitle = title
            contact.addressLine1 = "\(100 + index * 37) South Main Street"
            contact.city = "Rockford"
            contact.state = "IL"
            contact.postalCode = "61104"
            contact.latitude = latitude
            contact.longitude = longitude
            contact.hasResolvedAddress = true
            contact.sharedNotes = note
            contact.isDoNotContact = (warmth == .doNotReturn)
            contact.doNotContactReason = contact.isDoNotContact ? "Owner asked to be removed from the route." : ""
            contact.email = person.isEmpty ? "" : "\(person.split(separator: " ").first?.lowercased() ?? "info")@example.com"
            contact.phone = "(779) 555-01\(String(format: "%02d", index))"
            contact.contactWindow = index % 2 == 0 ? .afternoon : .midMorning
            contact.tags = kind == .business ? ["main street", "walk route A"] : ["institutional"]
            context.insert(contact)
            contacts.append(contact)

            // A visit for everyone, so the map and the history have substance.
            let visit = Visit(
                occurredAt: Calendar.current.date(byAdding: .day, value: -index * 5 - 1, to: .now) ?? .now,
                outcome: giftCents > 0 ? .gaveNow : (warmth == .doNotReturn ? .declined : .askAgainLater),
                warmth: warmth
            )
            visit.contact = contact
            visit.latitude = latitude
            visit.longitude = longitude
            visit.locationAccuracyMeters = 12
            visit.resolvedAddress = "\(contact.addressLine1), Rockford, IL"
            visit.notes = note.isEmpty ? "Spoke with whoever was at the counter." : note
            visit.recordedByDisplayName = "Maritza"
            context.insert(visit)

            if giftCents > 0 {
                let gift = Gift(
                    amount: Money(minorUnits: giftCents),
                    method: index % 2 == 0 ? .applePay : .check,
                    receivedAt: visit.occurredAt
                )
                gift.contact = contact
                gift.organization = organization
                gift.visit = visit
                gift.fundName = organization.defaultFundName
                gift.isPaymentConfirmed = true
                gift.referenceNumber = gift.method == .check ? "10\(index)4" : ""
                gift.paymentInstrumentDescription = gift.method == .applePay ? "Visa 4242" : ""
                gift.recordedByDisplayName = "Maritza"
                context.insert(gift)

                let document = GeneratedDocument(
                    kind: index % 2 == 0 ? .receipt : .letter,
                    documentNumber: String(format: "%@-2026-%04d", index % 2 == 0 ? "RCT" : "ACK", index + 1)
                )
                document.gift = gift
                document.organization = organization
                document.recipientName = contact.displayName
                document.recipientAddressBlock = contact.mailingAddressLines.joined(separator: "\n")
                document.organizationName = organization.name
                document.organizationEIN = organization.ein
                document.organizationAddressBlock = organization.letterheadLines.joined(separator: "\n")
                document.signatoryName = organization.signatoryName
                document.signatoryTitle = organization.signatoryTitle
                document.amountMinorUnits = giftCents
                document.deductibleAmountMinorUnits = giftCents
                document.giftMethodLabel = gift.method.label
                document.giftDate = gift.receivedAt
                document.fundName = gift.fundName
                document.issuedAt = gift.receivedAt
                document.deliveryState = index % 3 == 0 ? .queued : .sent
                document.recipientEmail = contact.email
                context.insert(document)
            }

            contact.recomputeRollups()
        }

        // A couple of live follow-ups so the Today screen has work on it.
        if let champion = contacts.first {
            let followUp = FollowUp(
                kind: .thankYou,
                dueAt: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now,
                note: "Ana asked for a photo of the pantry for her staff newsletter."
            )
            followUp.contact = champion
            context.insert(followUp)
        }
        if contacts.count > 4 {
            let followUp = FollowUp(
                kind: .visitAgain,
                dueAt: Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now,
                note: "Pastor Alder wanted to talk about hosting the December drive."
            )
            followUp.contact = contacts[4]
            context.insert(followUp)
        }

        try? context.save()
    }
}
