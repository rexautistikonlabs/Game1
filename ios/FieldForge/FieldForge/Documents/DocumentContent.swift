//
//  DocumentContent.swift
//  FieldForge
//
//  The frozen, renderer-ready description of a document.
//
//  Both templates take one of these and nothing else. That is the whole point:
//  the renderers cannot accidentally read a live relationship, so a document
//  re-rendered in 2029 from a stored snapshot is byte-for-byte the document
//  that was handed over in 2026.
//

import Foundation
import SwiftUI
import UIKit

/// Everything that appears on the page, already resolved to strings.
struct DocumentContent {

    // MARK: What kind of paper this is

    var kind: DocumentKind
    var documentNumber: String
    var issuedAt: Date
    var revision: Int

    // MARK: Issuer

    var organizationName: String
    var organizationLegalName: String
    var organizationAddressLines: [String]
    var einLine: String
    var tagline: String
    var footerNote: String
    var logo: UIImage?
    var brandColor: UIColor
    var usesColorBandLetterhead: Bool

    // MARK: Recipient

    var recipientName: String
    var recipientAddressLines: [String]
    var salutation: String
    var isAnonymous: Bool

    // MARK: The gift

    var amount: Money
    var deductibleAmount: Money
    var isInKind: Bool
    var inKindDescription: String
    var inKindQuantity: Int
    var donorEstimatedValue: Money
    var showsDonorEstimatedValue: Bool
    var methodLabel: String
    var referenceNumber: String
    var transactionIdentifier: String
    var instrumentDescription: String
    var giftDate: Date
    var fundName: String
    var providedGoodsOrServices: Bool
    var goodsOrServicesDescription: String
    var goodsOrServicesValue: Money

    // MARK: Language

    /// The full substantiation paragraph from `TaxLanguage`.
    var substantiationParagraph: String
    /// The compact one-liner used on the receipt.
    var receiptFooterNote: String
    /// The organization's own extra sentence, if any.
    var customNote: String?

    // MARK: Signature

    var signatureImage: UIImage?
    var signatoryName: String
    var signatoryTitle: String

    // MARK: Page

    var pageSize: PageSize = .forCurrentLocale

    // MARK: Derived text used by both templates

    /// "Receipt" / "Donation Acknowledgment", plus a revision marker.
    var documentTitle: String {
        let base = kind == .receipt ? "Donation Receipt" : "Acknowledgment of Gift"
        return revision > 0 ? "\(base) — Revised" : base
    }

    var formattedIssuedDate: String {
        issuedAt.formatted(date: .long, time: .omitted)
    }

    var formattedGiftDate: String {
        giftDate.formatted(date: .long, time: .omitted)
    }

    var displayRecipientName: String {
        isAnonymous ? "Anonymous donor" : recipientName
    }

    /// Line items for the receipt's amount table. Built here rather than in the
    /// template so both templates agree on what the money means.
    struct LineItem {
        var label: String
        var detail: String
        var amountText: String
        var isEmphasized: Bool = false
    }

    var lineItems: [LineItem] {
        var items: [LineItem] = []

        if isInKind {
            let quantityPrefix = inKindQuantity > 0 ? "\(inKindQuantity) × " : ""
            items.append(LineItem(
                label: "In-kind contribution",
                detail: quantityPrefix + (inKindDescription.trimmedOrNil ?? "Donated goods"),
                amountText: showsDonorEstimatedValue && donorEstimatedValue.isPositive
                    ? "\(donorEstimatedValue.formatted)*"
                    : "—"
            ))
        } else {
            items.append(LineItem(
                label: "Contribution",
                detail: fundName.trimmedOrNil ?? "General support",
                amountText: amount.formatted
            ))
        }

        if providedGoodsOrServices {
            items.append(LineItem(
                label: "Less goods or services received",
                detail: goodsOrServicesDescription.trimmedOrNil ?? "Goods or services",
                amountText: "−\(goodsOrServicesValue.formatted)"
            ))
            items.append(LineItem(
                label: "Tax-deductible portion",
                detail: "",
                amountText: deductibleAmount.formatted,
                isEmphasized: true
            ))
        }

        return items
    }

    /// Payment detail rows, omitting anything blank so the receipt never shows
    /// an empty "Reference:" line.
    var paymentDetailRows: [(String, String)] {
        var rows: [(String, String)] = [("Method", methodLabel)]
        if let reference = referenceNumber.trimmedOrNil {
            rows.append((methodLabel.lowercased().contains("check") ? "Check number" : "Reference", reference))
        }
        if let instrument = instrumentDescription.trimmedOrNil {
            rows.append(("Card", instrument))
        }
        if let transaction = transactionIdentifier.trimmedOrNil {
            // Truncated: a full processor identifier is 40 characters of noise
            // to a donor, and the first eight are enough to look one up.
            rows.append(("Transaction", String(transaction.prefix(8)).uppercased()))
        }
        if let fund = fundName.trimmedOrNil, !isInKind {
            rows.append(("Designated for", fund))
        }
        return rows
    }

    /// True when the in-kind footnote marker (*) appears in the table and needs
    /// explaining below it.
    var needsDonorEstimateFootnote: Bool {
        isInKind && showsDonorEstimatedValue && donorEstimatedValue.isPositive
    }
}

// MARK: - Building content from records

extension DocumentContent {

    /// The single place live records become a document. Called once, at issue
    /// time, by `DocumentEngine`.
    init(
        kind: DocumentKind,
        documentNumber: String,
        gift: Gift,
        contact: Contact?,
        organization: Organization,
        signature: UIImage?,
        signatoryNameOverride: String? = nil,
        signatoryTitleOverride: String? = nil,
        issuedAt: Date = .now,
        revision: Int = 0
    ) {
        let language = TaxLanguage(TaxLanguage.Input(gift: gift, organization: organization))

        self.kind = kind
        self.documentNumber = documentNumber
        self.issuedAt = issuedAt
        self.revision = revision

        self.organizationName = organization.name
        self.organizationLegalName = organization.printableLegalName
        self.organizationAddressLines = organization.letterheadLines
        self.einLine = organization.einLine
        self.tagline = organization.letterheadTagline
        self.footerNote = organization.letterFooterNote
        self.logo = organization.logoData.flatMap(UIImage.init(data:))
        self.brandColor = UIColor(organization.brandColor)
        self.usesColorBandLetterhead = organization.usesColorBandLetterhead

        self.recipientName = contact?.displayName ?? "Friend"
        self.recipientAddressLines = contact?.mailingAddressLines ?? []
        self.salutation = contact?.letterSalutation ?? "Dear Friend,"
        self.isAnonymous = gift.isAnonymousDonor

        self.amount = gift.amount
        self.deductibleAmount = gift.deductibleAmount
        self.isInKind = gift.isInKind
        self.inKindDescription = gift.inKindDescription
        self.inKindQuantity = gift.inKindQuantity
        self.donorEstimatedValue = gift.donorEstimatedValue
        self.showsDonorEstimatedValue = organization.printsDonorEstimatedValueOnInKind
        self.methodLabel = gift.method.label
        self.referenceNumber = gift.referenceNumber
        self.transactionIdentifier = gift.transactionIdentifier
        self.instrumentDescription = gift.paymentInstrumentDescription
        self.giftDate = gift.receivedAt
        self.fundName = gift.fundName.trimmedOrNil ?? organization.defaultFundName
        self.providedGoodsOrServices = gift.providedGoodsOrServices
        self.goodsOrServicesDescription = gift.goodsOrServicesDescription
        self.goodsOrServicesValue = gift.goodsOrServicesValue

        self.substantiationParagraph = language.substantiationParagraph
        self.receiptFooterNote = language.receiptFooterNote
        self.customNote = language.customNoteParagraph

        self.signatureImage = signature
        self.signatoryName = signatoryNameOverride?.trimmedOrNil ?? organization.signatoryName
        self.signatoryTitle = signatoryTitleOverride?.trimmedOrNil ?? organization.signatoryTitle
    }

    /// Rebuilds content from a stored document, for re-printing without a
    /// re-issue. Uses only the snapshot, never the live records.
    init(snapshot document: GeneratedDocument) {
        self.kind = document.kind
        self.documentNumber = document.documentNumber
        self.issuedAt = document.issuedAt
        self.revision = document.revision

        self.organizationName = document.organizationName
        self.organizationLegalName = document.organizationName
        self.organizationAddressLines = document.organizationAddressBlock
            .components(separatedBy: "\n")
            .compactMap { $0.trimmedOrNil }
        self.einLine = document.organizationEIN.trimmedOrNil.map { "EIN \($0)" } ?? ""
        self.tagline = ""
        self.footerNote = ""
        self.logo = document.organization?.logoData.flatMap(UIImage.init(data:))
        self.brandColor = UIColor(document.organization?.brandColor ?? .accentColor)
        self.usesColorBandLetterhead = document.organization?.usesColorBandLetterhead ?? false

        self.recipientName = document.recipientName
        self.recipientAddressLines = document.recipientAddressBlock
            .components(separatedBy: "\n")
            .compactMap { $0.trimmedOrNil }
        self.salutation = "Dear \(document.recipientName),"
        self.isAnonymous = false

        self.amount = document.amount
        self.deductibleAmount = document.deductibleAmount
        self.isInKind = document.inKindDescription.trimmedOrNil != nil
        self.inKindDescription = document.inKindDescription
        self.inKindQuantity = 0
        self.donorEstimatedValue = .zero
        self.showsDonorEstimatedValue = false
        self.methodLabel = document.giftMethodLabel
        self.referenceNumber = ""
        self.transactionIdentifier = ""
        self.instrumentDescription = ""
        self.giftDate = document.giftDate
        self.fundName = document.fundName
        self.providedGoodsOrServices = document.deductibleAmountMinorUnits != document.amountMinorUnits
        self.goodsOrServicesDescription = ""
        self.goodsOrServicesValue = Money(
            minorUnits: max(0, document.amountMinorUnits - document.deductibleAmountMinorUnits),
            currencyCode: document.currencyCode
        )

        self.substantiationParagraph = document.taxLanguageUsed
        self.receiptFooterNote = document.taxLanguageUsed
        self.customNote = nil

        self.signatureImage = document.signatureImageData.flatMap(UIImage.init(data:))
        self.signatoryName = document.signatoryName
        self.signatoryTitle = document.signatoryTitle
    }
}
