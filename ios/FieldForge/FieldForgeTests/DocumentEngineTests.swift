//
//  DocumentEngineTests.swift
//  FieldForgeTests
//
//  End-to-end tests for the dual document engine: that both templates render
//  real PDFs, that the snapshot is frozen, and — most importantly — that the
//  engine refuses to issue a tax document for money that has not arrived.
//

import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
@testable import FieldForge

@MainActor
struct DocumentEngineTests {

    // MARK: Fixtures

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeOrganization(in context: ModelContext) -> Organization {
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107", city: "Rockford", state: "IL")
        organization.addressLine1 = "412 South Water Street"
        organization.postalCode = "61104"
        organization.signatoryName = "Maritza Ocampo"
        organization.signatoryTitle = "Director of Development"
        context.insert(organization)
        return organization
    }

    private func makeContact(in context: ModelContext, organization: Organization) -> Contact {
        let contact = Contact(name: "Delgado Hardware", kind: .business)
        contact.organization = organization
        contact.contactPersonName = "Ana Delgado"
        contact.contactPersonTitle = "Owner"
        contact.addressLine1 = "128 River Street"
        contact.city = "Rockford"
        contact.state = "IL"
        contact.postalCode = "61104"
        contact.email = "ana@example.com"
        context.insert(contact)
        return contact
    }

    private func makeGift(
        in context: ModelContext,
        organization: Organization,
        contact: Contact,
        amount: Money = Money(dollars: 250),
        method: GiftMethod = .cash
    ) -> Gift {
        let gift = Gift(amount: amount, method: method)
        gift.organization = organization
        gift.contact = contact
        gift.fundName = "Winter Meals Fund"
        gift.isPaymentConfirmed = !method.requiresNetwork
        context.insert(gift)
        return gift
    }

    // MARK: Rendering

    @Test("Both templates produce a readable one-page PDF from the same gift")
    func bothTemplatesRender() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        for kind in DocumentKind.allCases {
            let data = DocumentEngine.renderPreview(
                kind: kind,
                gift: gift,
                contact: contact,
                organization: organization,
                signature: nil
            )
            #expect(!data.isEmpty, "\(kind) produced no bytes")

            let pdf = PDFDocument(data: data)
            #expect(pdf != nil, "\(kind) produced something PDFKit cannot open")
            #expect((pdf?.pageCount ?? 0) >= 1)

            // The text has to be real text, not a picture of text — an
            // accountant should be able to copy the amount out of it.
            let text = pdf?.string ?? ""
            #expect(text.contains("Riverside Food Collective"))
            #expect(text.contains("Delgado Hardware"))
            #expect(text.contains("36-4829107"))
        }
    }

    @Test("A preview does not advance the document counters")
    func previewDoesNotBurnNumbers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let before = (organization.nextReceiptSequence, organization.nextLetterSequence)
        for _ in 0..<5 {
            _ = DocumentEngine.renderPreview(kind: .receipt, gift: gift, contact: contact, organization: organization, signature: nil)
            _ = DocumentEngine.renderPreview(kind: .letter, gift: gift, contact: contact, organization: organization, signature: nil)
        }
        #expect(organization.nextReceiptSequence == before.0)
        #expect(organization.nextLetterSequence == before.1)
    }

    // MARK: Issuing

    @Test("Issuing freezes a snapshot that later edits cannot change")
    func snapshotIsFrozen() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let document = try DocumentEngine.issue(
            kind: .letter,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )

        #expect(document.recipientName == "Delgado Hardware")
        #expect(document.amountMinorUnits == 25_000)
        let originalNumber = document.documentNumber

        // The donor moves and the organization rebrands.
        contact.name = "Delgado Hardware & Garden"
        contact.city = "Chicago"
        organization.name = "Riverside Collective"
        gift.amountMinorUnits = 99_999
        try context.save()

        // The issued document is unchanged, because it is a historical fact.
        #expect(document.recipientName == "Delgado Hardware")
        #expect(document.organizationName == "Riverside Food Collective")
        #expect(document.amountMinorUnits == 25_000)
        #expect(document.documentNumber == originalNumber)
    }

    @Test("A re-print reproduces the document as issued, not as the records are now")
    func reprintUsesSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let document = try DocumentEngine.issue(
            kind: .receipt,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )

        contact.name = "Something Else Entirely"
        try context.save()

        let reprint = DocumentEngine.reprint(document)
        let text = PDFDocument(data: reprint)?.string ?? ""
        #expect(text.contains("Delgado Hardware"))
        #expect(!text.contains("Something Else Entirely"))
    }

    @Test("A checksum is recorded and matches the stored bytes")
    func checksum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let document = try DocumentEngine.issue(
            kind: .receipt,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )
        let data = try #require(document.pdfData)
        #expect(document.pdfChecksum == DocumentEngine.checksum(of: data))
        #expect(document.pdfChecksum.count == 64)   // SHA-256, hex
    }

    // MARK: Refusals — the important ones

    @Test("An unconfirmed card payment cannot produce a tax document")
    func unconfirmedPaymentIsRefused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(
            in: context,
            organization: organization,
            contact: contact,
            method: .applePay
        )
        gift.isPaymentConfirmed = false

        // This is the guard that stops a receipt existing for money that never
        // arrived.
        #expect(throws: (any Error).self) {
            try DocumentEngine.issue(
                kind: .receipt,
                gift: gift,
                contact: contact,
                organization: organization,
                signature: nil,
                includeDeviceTagInNumber: false,
                context: context
            )
        }
    }

    @Test("A pledge cannot be acknowledged as a completed contribution")
    func pledgeIsRefused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact, method: .pledge)

        let readiness = DocumentEngine.readiness(kind: .letter, gift: gift, organization: organization)
        #expect(!readiness.canIssue)
        #expect(readiness.blockers.contains { $0.contains("pledge") })
    }

    @Test("An in-kind gift with no description is refused")
    func inKindWithoutDescriptionIsRefused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact, amount: .zero, method: .inKind)

        let readiness = DocumentEngine.readiness(kind: .letter, gift: gift, organization: organization)
        #expect(!readiness.canIssue)
        // The description IS the acknowledgment for a noncash gift, so its
        // absence is fatal rather than cosmetic.
        #expect(readiness.blockers.contains { $0.contains("Describe") })
    }

    @Test("An organization missing its EIN cannot issue documents")
    func incompleteOrganizationIsRefused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = Organization(name: "Half Set Up")
        context.insert(organization)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        #expect(throws: (any Error).self) {
            try DocumentEngine.issue(
                kind: .receipt,
                gift: gift,
                contact: contact,
                organization: organization,
                signature: nil,
                includeDeviceTagInNumber: false,
                context: context
            )
        }
    }

    // MARK: Re-issue

    @Test("Re-issuing supersedes the original and keeps both")
    func reissue() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let original = try DocumentEngine.issue(
            kind: .receipt,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )
        let originalNumber = original.documentNumber

        // The donor asks for the letter instead.
        let reissued = try DocumentEngine.reissue(
            original,
            as: .letter,
            includeDeviceTagInNumber: false,
            context: context
        )

        #expect(reissued.kind == .letter)
        #expect(reissued.revision == 1)
        #expect(reissued.documentNumber == "\(originalNumber)-R1")
        #expect(reissued.supersedes?.id == original.id)
        #expect(original.deliveryState == .superseded)
        // Nothing was deleted.
        let all = try context.fetch(FetchDescriptor<GeneratedDocument>())
        #expect(all.count == 2)
    }

    // MARK: Quid pro quo arithmetic on the page

    @Test("A quid pro quo letter prints the deductible portion, not the payment")
    func quidProQuoOnThePage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact, amount: Money(dollars: 200))
        gift.providedGoodsOrServices = true
        gift.goodsOrServicesDescription = "two dinner seats"
        gift.goodsOrServicesValueMinorUnits = 7_500

        #expect(gift.deductibleAmount.minorUnits == 12_500)

        let data = DocumentEngine.renderPreview(
            kind: .letter,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil
        )
        let text = PDFDocument(data: data)?.string ?? ""
        #expect(text.contains("two dinner seats"))
        #expect(text.contains("125"))   // the deductible amount appears
    }

    // MARK: Filenames

    @Test("Exported filenames are recognisable months later")
    func fileNaming() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = makeGift(in: context, organization: organization, contact: contact)

        let document = try DocumentEngine.issue(
            kind: .letter,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )
        let name = document.suggestedFileName
        #expect(name.hasSuffix(".pdf"))
        #expect(name.contains("Acknowledgment"))
        #expect(name.contains("Delgado"))
        // No characters that break a filesystem or an email attachment.
        #expect(!name.contains("/"))
        #expect(!name.contains(" "))
    }
}
