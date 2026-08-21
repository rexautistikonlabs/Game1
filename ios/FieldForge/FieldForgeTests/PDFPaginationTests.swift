//
//  PDFPaginationTests.swift
//  FieldForgeTests
//
//  Multi-page letters, in-kind photographs, and the arithmetic that keeps them
//  on the page.
//
//  This is the closest thing to device testing that can be written here: it
//  renders real PDFs through the real templates and inspects them with PDFKit.
//  If the Core Text pagination drifts — the failure mode that produces
//  overlapping paragraphs or a signature block orphaned onto page three — these
//  assertions catch it, because a drifting layout changes the page count and
//  loses text off the bottom.
//

import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
@testable import FieldForge

@MainActor
struct PDFPaginationTests {

    // MARK: Fixtures

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeOrganization(in context: ModelContext) -> Organization {
        let organization = Organization(
            name: "Riverside Food Collective",
            ein: "36-4829107",
            city: "Rockford",
            state: "IL"
        )
        organization.addressLine1 = "412 South Water Street"
        organization.postalCode = "61104"
        organization.signatoryName = "Maritza Ocampo"
        organization.signatoryTitle = "Director of Development"
        organization.includesInKindPhotosInLetter = true
        context.insert(organization)
        return organization
    }

    private func makeContact(in context: ModelContext, organization: Organization) -> Contact {
        let contact = Contact(name: "Delgado Hardware", kind: .business)
        contact.organization = organization
        contact.contactPersonName = "Ana Delgado"
        contact.addressLine1 = "128 River Street"
        contact.city = "Rockford"
        contact.state = "IL"
        contact.postalCode = "61104"
        context.insert(contact)
        return contact
    }

    /// A distinctly coloured test image, so a rendered grid can be reasoned
    /// about and a missing photo is not mistaken for a white one.
    private func makeImage(_ index: Int, size: CGSize = CGSize(width: 800, height: 600)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let hue = CGFloat(index % 6) / 6
            UIColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func attachPhotos(
        count: Int,
        to gift: Gift,
        in context: ModelContext,
        portrait: Bool = false
    ) {
        for index in 0..<count {
            let size = portrait
                ? CGSize(width: 600, height: 900)
                : CGSize(width: 900, height: 600)
            let attachment = Attachment(
                kind: .inKindItem,
                data: makeImage(index, size: size).jpegData(compressionQuality: 0.8),
                caption: "Pallet \(index + 1)"
            )
            attachment.capturedAt = Date().addingTimeInterval(Double(index))
            attachment.gift = gift
            context.insert(attachment)
        }
    }

    /// Long enough to force a page break on its own.
    private var longPersonalNote: String {
        (1...14).map { paragraph in
            "Paragraph \(paragraph). Thank you again for the donation, which arrived at exactly the "
            + "moment we had run out of shelf space in the back room, and which the Tuesday volunteers "
            + "distributed the same afternoon to families who had been waiting since the previous week."
        }
        .joined(separator: "\n")
    }

    // MARK: Single page

    @Test("A short letter with no photos is one page and keeps its signature")
    func shortLetterIsOnePage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        context.insert(gift)

        let data = DocumentEngine.renderPreview(
            kind: .letter, gift: gift, contact: contact,
            organization: organization, signature: nil
        )
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)

        let text = pdf.string ?? ""
        // The signatory must be on the page, not pushed off the bottom.
        #expect(text.contains("Maritza Ocampo"))
        #expect(text.contains("No goods or services were provided"))
    }

    // MARK: Multi-page with photographs

    @Test("A long letter with six photos paginates without losing the ending")
    func longLetterWithPhotos() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)

        let gift = Gift(amount: .zero, method: .inKind)
        gift.contact = contact
        gift.organization = organization
        gift.inKindDescription = "42 twin blankets, new in packaging, on three pallets"
        gift.inKindQuantity = 42
        context.insert(gift)
        attachPhotos(count: 6, to: gift, in: context)
        try context.save()

        let data = DocumentEngine.renderPreview(
            kind: .letter, gift: gift, contact: contact,
            organization: organization, signature: nil,
            personalNote: longPersonalNote
        )
        let pdf = try #require(PDFDocument(data: data))

        // It must actually run to more than one page, or this test is not
        // exercising pagination at all.
        #expect(pdf.pageCount > 1, "expected a multi-page letter, got \(pdf.pageCount)")
        // And not explode: drift in the height arithmetic shows up as an
        // implausible page count long before it becomes visible by eye.
        #expect(pdf.pageCount <= 6, "page count of \(pdf.pageCount) suggests layout drift")

        let text = pdf.string ?? ""
        // Everything after the photographs must survive: the tax paragraph, the
        // closing and the signatory. Losing these is exactly what a pagination
        // bug does.
        #expect(text.contains("does not assign a value"))
        #expect(text.contains("With gratitude"))
        #expect(text.contains("Maritza Ocampo"))
        #expect(text.contains("42 twin blankets"))
        // First and last body paragraphs both present, so nothing was dropped
        // in the middle of the flow.
        #expect(text.contains("Paragraph 1."))
        #expect(text.contains("Paragraph 14."))
    }

    @Test("Portrait and landscape photos both render without changing the page count")
    func mixedOrientations() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)

        func render(portrait: Bool) throws -> Int {
            let gift = Gift(amount: .zero, method: .inKind)
            gift.contact = contact
            gift.organization = organization
            gift.inKindDescription = "Donated goods"
            context.insert(gift)
            attachPhotos(count: 4, to: gift, in: context, portrait: portrait)
            try context.save()

            let data = DocumentEngine.renderPreview(
                kind: .letter, gift: gift, contact: contact,
                organization: organization, signature: nil
            )
            return try #require(PDFDocument(data: data)).pageCount
        }

        // The grid aspect-fills into fixed cells, so orientation must not
        // change the layout. If it does, the cells are sizing to content.
        #expect(try render(portrait: false) == (try render(portrait: true)))
    }

    @Test("Photos are omitted when the organization has not opted in")
    func photosRespectTheSetting() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        organization.includesInKindPhotosInLetter = false
        let contact = makeContact(in: context, organization: organization)

        let gift = Gift(amount: .zero, method: .inKind)
        gift.contact = contact
        gift.organization = organization
        gift.inKindDescription = "Donated goods"
        context.insert(gift)
        attachPhotos(count: 4, to: gift, in: context)
        try context.save()

        let data = DocumentEngine.renderPreview(
            kind: .letter, gift: gift, contact: contact,
            organization: organization, signature: nil
        )
        let text = try #require(PDFDocument(data: data)).string ?? ""
        #expect(!text.contains("The donated items"))
        // The caption disclaimer must not appear either — it would be a
        // statement about photographs that are not there.
        #expect(!text.contains("donor's own estimate"))
    }

    @Test("Page numbering appears once a letter runs to two pages")
    func pageNumbering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = Gift(amount: Money(dollars: 500), method: .check)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        context.insert(gift)

        let data = DocumentEngine.renderPreview(
            kind: .letter, gift: gift, contact: contact,
            organization: organization, signature: nil,
            personalNote: longPersonalNote
        )
        let pdf = try #require(PDFDocument(data: data))
        guard pdf.pageCount > 1 else { return }

        let text = pdf.string ?? ""
        // Two passes exist precisely so the footer can say "of N" rather than
        // counting up blindly.
        #expect(text.contains("Page 1 of \(pdf.pageCount)"))
        #expect(text.contains("Page \(pdf.pageCount) of \(pdf.pageCount)"))
    }

    // MARK: Every appearance combination renders

    @Test("Every letterhead and typeface combination produces a readable page")
    func allAppearanceCombinationsRender() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        context.insert(gift)

        for style in LetterheadStyle.allCases {
            for typeface in DocumentTypeface.allCases {
                for footer in FooterStyle.allCases {
                    organization.letterheadStyle = style
                    organization.typeface = typeface
                    organization.footerStyle = footer

                    let data = DocumentEngine.renderPreview(
                        kind: .letter, gift: gift, contact: contact,
                        organization: organization, signature: nil
                    )
                    let label = "\(style.rawValue)/\(typeface.rawValue)/\(footer.rawValue)"
                    let pdf = try #require(PDFDocument(data: data), "no PDF for \(label)")
                    #expect(pdf.pageCount >= 1, "no pages for \(label)")

                    let text = pdf.string ?? ""
                    // Whatever the styling, the substance has to be on the page.
                    #expect(text.contains("Delgado Hardware"), "recipient missing for \(label)")
                    #expect(text.contains("Maritza Ocampo"), "signatory missing for \(label)")
                }
            }
        }
    }

    @Test("Receipts stay to a single page across every appearance")
    func receiptsAreAlwaysOnePage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = makeOrganization(in: context)
        let contact = makeContact(in: context, organization: organization)
        let gift = Gift(amount: Money(dollars: 1_250), method: .applePay)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        gift.paymentInstrumentDescription = "Visa 4242"
        gift.providedGoodsOrServices = true
        gift.goodsOrServicesDescription = "Two dinner seats at the winter gala"
        gift.goodsOrServicesValueMinorUnits = 7_500
        context.insert(gift)

        for style in LetterheadStyle.allCases {
            organization.letterheadStyle = style
            let data = DocumentEngine.renderPreview(
                kind: .receipt, gift: gift, contact: contact,
                organization: organization, signature: nil
            )
            let pdf = try #require(PDFDocument(data: data))
            // A receipt that runs to two pages means something upstream is
            // wrong — it is meant to be handed across a counter.
            #expect(pdf.pageCount == 1, "receipt ran to \(pdf.pageCount) pages with \(style.rawValue)")
        }
    }

    // MARK: Page size

    @Test("Both page sizes render at the right physical dimensions")
    func pageSizes() {
        // 8.5 x 11 inches and 210 x 297 mm, in points.
        #expect(PageSize.usLetter.size == CGSize(width: 612, height: 792))
        #expect(abs(PageSize.a4.size.width - 595.28) < 0.01)
        #expect(abs(PageSize.a4.size.height - 841.89) < 0.01)
    }

    @Test("The page ceiling is high enough for real documents and low enough to stop a runaway")
    func pageCeiling() {
        #expect(PDFCanvas.maximumPages >= 20)
        #expect(PDFCanvas.maximumPages <= 100)
    }
}
