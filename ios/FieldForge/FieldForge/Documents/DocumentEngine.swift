//
//  DocumentEngine.swift
//  FieldForge
//
//  The dual document engine: one call site, two outputs, identical data.
//
//  This is the piece the whole app is arranged around. Toggling between a
//  receipt and an acknowledgment letter must be instant and must never ask the
//  staffer to re-enter anything, because that toggle happens while a donor is
//  standing there saying "actually, could I get a letter for my accountant?"
//
//  Everything here works with no network. Nothing here talks to a server.
//

import CryptoKit
import Foundation
import PDFKit
import SwiftData
import UIKit

@MainActor
struct DocumentEngine {

    enum EngineError: LocalizedError {
        case organizationNotReady([String])
        case giftNotReady([String])
        case renderProducedNothing

        var errorDescription: String? {
            switch self {
            case .organizationNotReady(let missing):
                return "Finish setting up your organization first: \(missing.joined(separator: ", "))."
            case .giftNotReady(let blockers):
                return blockers.joined(separator: " ")
            case .renderProducedNothing:
                return "The document could not be rendered. Please try again."
            }
        }
    }

    // MARK: - Preview rendering (no records touched)

    /// Renders a PDF for the live preview in the capture flow.
    ///
    /// Deliberately does not mint a document number or write anything: the
    /// staffer flips between receipt and letter several times before choosing,
    /// and burning sequence numbers on previews would leave gaps in the books.
    static func renderPreview(
        kind: DocumentKind,
        gift: Gift,
        contact: Contact?,
        organization: Organization,
        signature: UIImage?,
        personalNote: String = "",
        signatoryNameOverride: String? = nil,
        signatoryTitleOverride: String? = nil
    ) -> Data {
        let content = DocumentContent(
            kind: kind,
            documentNumber: previewNumberPlaceholder(kind: kind, organization: organization),
            gift: gift,
            contact: contact,
            organization: organization,
            signature: signature,
            signatoryNameOverride: signatoryNameOverride,
            signatoryTitleOverride: signatoryTitleOverride
        )
        return render(content: content, personalNote: personalNote)
    }

    /// What the number *will* be, shown greyed in the preview so the staffer
    /// sees the real shape of the document. Reads the counter without moving it.
    private static func previewNumberPlaceholder(kind: DocumentKind, organization: Organization) -> String {
        DocumentNumberer.format(
            prefix: kind == .receipt
                ? (organization.receiptPrefix.trimmedOrNil ?? "RCT")
                : (organization.letterPrefix.trimmedOrNil ?? "ACK"),
            year: Calendar.current.component(.year, from: .now),
            sequence: kind == .receipt ? organization.nextReceiptSequence : organization.nextLetterSequence
        )
    }

    /// The dispatch that makes "dual engine" true: one content value, two
    /// templates, and the choice is a single enum.
    static func render(content: DocumentContent, personalNote: String = "") -> Data {
        switch content.kind {
        case .receipt:
            return ReceiptRenderer(content: content).render()
        case .letter:
            var renderer = LetterRenderer(content: content)
            renderer.personalNote = personalNote
            return renderer.render()
        }
    }

    // MARK: - Issuing for real

    /// Mints a number, renders the PDF, freezes the snapshot, and inserts the
    /// `GeneratedDocument`. This is the only function that creates a document
    /// record, so it is the only place that can burn a sequence number.
    ///
    /// - Returns: the inserted, saved document.
    @discardableResult
    static func issue(
        kind: DocumentKind,
        gift: Gift,
        contact: Contact?,
        organization: Organization,
        signature: UIImage?,
        personalNote: String = "",
        signatoryNameOverride: String? = nil,
        signatoryTitleOverride: String? = nil,
        recipientEmail: String? = nil,
        issuedBy: String = "",
        includeDeviceTagInNumber: Bool,
        context: ModelContext
    ) throws -> GeneratedDocument {

        let missing = organization.missingRequiredBrandingFields
        guard missing.isEmpty else { throw EngineError.organizationNotReady(missing) }

        let blockers = gift.blockersForDocument(kind: kind)
        guard blockers.isEmpty else { throw EngineError.giftNotReady(blockers) }

        let number = DocumentNumberer.nextAvailable(
            kind: kind,
            organization: organization,
            includeDeviceTag: includeDeviceTagInNumber,
            context: context
        )

        let content = DocumentContent(
            kind: kind,
            documentNumber: number,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: signature,
            signatoryNameOverride: signatoryNameOverride,
            signatoryTitleOverride: signatoryTitleOverride
        )

        let pdfData = render(content: content, personalNote: personalNote)
        guard !pdfData.isEmpty else { throw EngineError.renderProducedNothing }

        let document = GeneratedDocument(kind: kind, documentNumber: number)
        apply(content: content, to: document)
        document.pdfData = pdfData
        document.pdfChecksum = checksum(of: pdfData)
        document.signatureImageData = signature?.pngData()
        document.gift = gift
        document.organization = organization
        document.recipientEmail = recipientEmail?.trimmedOrNil ?? contact?.email ?? ""
        document.createdByDisplayName = issuedBy
        document.deliveryState = .saved

        context.insert(document)
        try context.save()

        AppLog.documents.info("Issued \(kind.rawValue, privacy: .public) \(number, privacy: .public), \(pdfData.count) bytes")
        return document
    }

    /// Re-issues a corrected document. The original is kept and marked
    /// superseded rather than edited, because it was already handed to a donor
    /// and the history should say so.
    @discardableResult
    static func reissue(
        _ original: GeneratedDocument,
        as kind: DocumentKind? = nil,
        signature: UIImage? = nil,
        personalNote: String = "",
        includeDeviceTagInNumber: Bool,
        context: ModelContext
    ) throws -> GeneratedDocument {
        guard let gift = original.gift, let organization = original.organization else {
            // Without the live records we can still re-render the snapshot, but
            // that is a re-print, not a re-issue. See `reprint`.
            throw EngineError.giftNotReady(["The original gift record is no longer available. Re-print the stored copy instead."])
        }

        let targetKind = kind ?? original.kind
        let revision = original.revision + 1
        let number = DocumentNumberer.revision(of: original.documentNumber, revision: revision)

        let content = DocumentContent(
            kind: targetKind,
            documentNumber: number,
            gift: gift,
            contact: gift.contact,
            organization: organization,
            signature: signature ?? original.signatureImageData.flatMap(UIImage.init(data:)),
            issuedAt: .now,
            revision: revision
        )

        let pdfData = render(content: content, personalNote: personalNote)
        guard !pdfData.isEmpty else { throw EngineError.renderProducedNothing }

        let document = GeneratedDocument(kind: targetKind, documentNumber: number)
        apply(content: content, to: document)
        document.revision = revision
        document.pdfData = pdfData
        document.pdfChecksum = checksum(of: pdfData)
        document.signatureImageData = content.signatureImage?.pngData()
        document.gift = gift
        document.organization = organization
        document.recipientEmail = original.recipientEmail
        document.supersedes = original
        document.deliveryState = .saved

        original.deliveryState = .superseded

        context.insert(document)
        try context.save()
        AppLog.documents.info("Re-issued as \(number, privacy: .public)")
        return document
    }

    /// Re-renders a stored document from its frozen snapshot, byte-for-byte
    /// equivalent to what was originally issued. Used when the PDF file itself
    /// has gone missing — for example after a restore that dropped external
    /// storage — and for "print again" with no new number.
    static func reprint(_ document: GeneratedDocument) -> Data {
        let content = DocumentContent(snapshot: document)
        return render(content: content)
    }

    /// Copies the resolved content onto the record. Everything the page says,
    /// frozen, so nothing on it can drift.
    private static func apply(content: DocumentContent, to document: GeneratedDocument) {
        document.issuedAt = content.issuedAt
        document.recipientName = content.displayRecipientName
        document.recipientAddressBlock = content.recipientAddressLines.joined(separator: "\n")
        document.organizationName = content.organizationName
        document.organizationEIN = content.einLine
            .replacingOccurrences(of: "EIN ", with: "")
        document.organizationAddressBlock = content.organizationAddressLines.joined(separator: "\n")
        document.signatoryName = content.signatoryName
        document.signatoryTitle = content.signatoryTitle
        document.amountMinorUnits = content.amount.minorUnits
        document.currencyCode = content.amount.currencyCode
        document.deductibleAmountMinorUnits = content.deductibleAmount.minorUnits
        document.giftMethodLabel = content.methodLabel
        document.giftDate = content.giftDate
        document.fundName = content.fundName
        document.inKindDescription = content.isInKind ? content.inKindDescription : ""
        document.taxLanguageUsed = content.substantiationParagraph
    }

    /// SHA-256, hex. Cheap tamper-evidence for the history screen.
    static func checksum(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Validation surfaced before rendering

    /// Everything worth showing the staffer on the document step, in one call:
    /// hard blockers, soft advisories, and the tax language they are about to
    /// print. Pure, so the UI can call it on every keystroke.
    struct Readiness {
        var blockers: [String]
        var advisories: [String]
        var substantiationPreview: String
        var deductibleAmount: Money

        var canIssue: Bool { blockers.isEmpty }
    }

    static func readiness(
        kind: DocumentKind,
        gift: Gift,
        organization: Organization
    ) -> Readiness {
        let language = TaxLanguage(TaxLanguage.Input(gift: gift, organization: organization))
        var blockers = gift.blockersForDocument(kind: kind)
        blockers.append(contentsOf: organization.missingRequiredBrandingFields.map {
            "Missing organization detail: \($0)."
        })
        return Readiness(
            blockers: blockers,
            advisories: language.advisories + gift.advisories,
            substantiationPreview: language.substantiationParagraph,
            deductibleAmount: language.deductibleAmount
        )
    }

    // MARK: - Files

    /// Writes the PDF to a temporary file so it can be shared, AirDropped,
    /// printed, or attached to mail. Named for the donor, not "document.pdf".
    static func temporaryFileURL(for document: GeneratedDocument) -> URL? {
        let data = document.pdfData ?? reprint(document)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FieldForge-Share", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: document.suggestedFileName)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            AppLog.documents.error("Could not stage PDF for sharing: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes staged share files. Called when the Documents screen disappears
    /// so the temporary directory does not accumulate donor PDFs.
    static func clearStagedFiles() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FieldForge-Share")
        try? FileManager.default.removeItem(at: directory)
    }

    /// A `PDFDocument` for on-screen preview. Falls back to re-rendering from
    /// the snapshot when the stored file is missing.
    static func pdfDocument(for document: GeneratedDocument) -> PDFDocument? {
        if let data = document.pdfData, let pdf = PDFDocument(data: data) { return pdf }
        return PDFDocument(data: reprint(document))
    }
}
