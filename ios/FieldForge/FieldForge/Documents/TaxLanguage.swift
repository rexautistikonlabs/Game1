//
//  TaxLanguage.swift
//  FieldForge
//
//  The substantiation language printed on acknowledgment letters and receipts.
//
//  This file is the one place in the app where wording is a compliance
//  question rather than a design question, so it is isolated, pure, unit
//  tested, and heavily commented with what each sentence is for.
//
//  What the rules actually require (IRS Publication 1771):
//
//    * A donor claiming a deduction for a single contribution of $250 or more
//      must have a contemporaneous written acknowledgment from the charity.
//    * That acknowledgment must state the amount of cash contributed, and
//      either that no goods or services were provided in return, or a
//      description and good-faith estimate of the value of what was.
//    * For noncash (in-kind) gifts the charity describes the property. The
//      charity does not value it — valuation is the donor's responsibility,
//      and stating a value on the charity's letterhead is the single most
//      common mistake in nonprofit acknowledgments.
//    * A "quid pro quo" contribution over $75 requires a written statement
//      that the deductible amount is limited to the excess of the payment over
//      the value of the goods or services provided.
//    * Noncash gifts over $500 involve Form 8283 for the donor; over $5,000
//      generally require a qualified appraisal and the charity's signature on
//      Section B.
//
//  This app produces correct, conservative language. It is not tax advice, and
//  `disclaimerFooter` says so on the page.
//

import Foundation

/// Builds the substantiation paragraphs for a document.
///
/// Pure functions over a small input struct: no models, no I/O, no dates from
/// the clock. That makes every sentence in this file testable, which is the
/// point — see `TaxLanguageTests`.
struct TaxLanguage {

    /// Everything the wording depends on, extracted from the gift and the
    /// organization so the renderer never reaches back into SwiftData.
    struct Input {
        var organizationName: String
        var isRecognized501c3: Bool
        var fiscalSponsorNote: String

        var isInKind: Bool
        var amount: Money
        var inKindDescription: String
        var donorEstimatedValue: Money
        var printDonorEstimatedValue: Bool

        var providedGoodsOrServices: Bool
        var goodsOrServicesDescription: String
        var goodsOrServicesValue: Money

        var isPledge: Bool
        var customNote: String

        init(
            organizationName: String,
            isRecognized501c3: Bool = true,
            fiscalSponsorNote: String = "",
            isInKind: Bool = false,
            amount: Money = .zero,
            inKindDescription: String = "",
            donorEstimatedValue: Money = .zero,
            printDonorEstimatedValue: Bool = false,
            providedGoodsOrServices: Bool = false,
            goodsOrServicesDescription: String = "",
            goodsOrServicesValue: Money = .zero,
            isPledge: Bool = false,
            customNote: String = ""
        ) {
            self.organizationName = organizationName
            self.isRecognized501c3 = isRecognized501c3
            self.fiscalSponsorNote = fiscalSponsorNote
            self.isInKind = isInKind
            self.amount = amount
            self.inKindDescription = inKindDescription
            self.donorEstimatedValue = donorEstimatedValue
            self.printDonorEstimatedValue = printDonorEstimatedValue
            self.providedGoodsOrServices = providedGoodsOrServices
            self.goodsOrServicesDescription = goodsOrServicesDescription
            self.goodsOrServicesValue = goodsOrServicesValue
            self.isPledge = isPledge
            self.customNote = customNote
        }
    }

    /// Thresholds, as minor units, named so the intent survives a reader who
    /// does not know the rules by heart.
    enum Threshold {
        /// Written acknowledgment required at or above this single-gift amount.
        static let writtenAcknowledgmentRequired = 25_000       // $250
        /// Quid pro quo disclosure required above this amount.
        static let quidProQuoDisclosure = 7_500                 // $75
        /// Donor files Form 8283 for noncash gifts above this amount.
        static let form8283 = 50_000                            // $500
        /// Qualified appraisal generally required above this amount.
        static let qualifiedAppraisal = 500_000                 // $5,000
    }

    let input: Input

    init(_ input: Input) { self.input = input }

    // MARK: - The paragraph that satisfies the rules

    /// The substantiation paragraph. This is the sentence or two that makes the
    /// document useful to the donor's accountant, and it is stored verbatim on
    /// the `GeneratedDocument` so a re-print years later reproduces exactly
    /// what was originally issued.
    var substantiationParagraph: String {
        if input.isPledge {
            // A pledge is a promise. Acknowledging it as a contribution would
            // be wrong, so the language explicitly declines to.
            return """
            This letter confirms your intention to contribute and is not a receipt for a \
            completed gift. A tax acknowledgment will be issued when the contribution is received.
            """
        }

        if input.isInKind {
            return inKindParagraph
        }

        if input.providedGoodsOrServices {
            return quidProQuoParagraph
        }

        // The plain, most common case, and the sentence the IRS specifically
        // looks for on a cash acknowledgment of $250 or more.
        return """
        No goods or services were provided in exchange for this contribution. \
        \(deductibilitySentence)
        """
    }

    /// Noncash gifts. Note what this does *not* say: it never asserts a value.
    private var inKindParagraph: String {
        var sentences: [String] = []

        let description = input.inKindDescription.trimmedOrNil ?? "the donated property described above"
        sentences.append(
            "\(input.organizationName) gratefully acknowledges the donation of \(description)."
        )

        // The critical sentence. The charity describes; the donor values.
        sentences.append(
            """
            In accordance with IRS requirements, this acknowledgment describes the donated \
            property but does not assign a value to it. Determining the fair market value of \
            a noncash contribution is the responsibility of the donor.
            """
        )

        // Only if the organization has explicitly opted in, and always framed
        // as the donor's own number rather than ours.
        if input.printDonorEstimatedValue, input.donorEstimatedValue.isPositive {
            sentences.append(
                """
                For your records, the donor stated an estimated value of \
                \(input.donorEstimatedValue.formatted). This figure was provided by the donor \
                and has not been verified or endorsed by \(input.organizationName).
                """
            )
        }

        if input.providedGoodsOrServices {
            sentences.append(goodsOrServicesSentence)
        } else {
            sentences.append("No goods or services were provided in exchange for this donation.")
        }

        if input.donorEstimatedValue.minorUnits > Threshold.qualifiedAppraisal {
            sentences.append(
                """
                Noncash contributions valued above $5,000 generally require a qualified appraisal \
                and IRS Form 8283, Section B, which we will be glad to sign. Please contact us.
                """
            )
        } else if input.donorEstimatedValue.minorUnits > Threshold.form8283 {
            sentences.append(
                "Noncash contributions valued above $500 are generally reported on IRS Form 8283."
            )
        }

        sentences.append(deductibilitySentence)
        return sentences.joined(separator: " ")
    }

    /// Quid pro quo: the donor got something, so only part of the payment is
    /// deductible, and the letter has to say so and show the arithmetic.
    private var quidProQuoParagraph: String {
        let deductible = deductibleAmount
        var sentences: [String] = [goodsOrServicesSentence]

        sentences.append(
            """
            Under IRS rules, the amount you may deduct as a charitable contribution is limited to \
            the excess of the amount you paid over the value of the goods or services you received. \
            Of your \(input.amount.formatted) payment, \(deductible.formatted) may be deductible as \
            a charitable contribution.
            """
        )

        if deductible.isZero {
            sentences.append(
                """
                Because the value of what you received equals or exceeds your payment, no portion of \
                this payment is deductible as a charitable contribution.
                """
            )
        }

        sentences.append(deductibilitySentence)
        return sentences.joined(separator: " ")
    }

    private var goodsOrServicesSentence: String {
        let description = input.goodsOrServicesDescription.trimmedOrNil ?? "goods or services"
        guard input.goodsOrServicesValue.isPositive else {
            return "In connection with this contribution you received \(description)."
        }
        return """
        In connection with this contribution you received \(description), for which we have made a \
        good-faith estimate of value of \(input.goodsOrServicesValue.formatted).
        """
    }

    /// The organization's tax status, stated once. Turned off for organizations
    /// that are not 501(c)(3) — printing deductibility language they are not
    /// entitled to would harm the donor, not just the org.
    private var deductibilitySentence: String {
        guard input.isRecognized501c3 else {
            return """
            \(input.organizationName) is not a 501(c)(3) organization, and contributions are not \
            deductible as charitable contributions for federal income tax purposes.
            """
        }
        let sponsor = input.fiscalSponsorNote.trimmedOrNil
        let entity = sponsor.map { "\(input.organizationName), a project of \($0)," } ?? "\(input.organizationName)"
        return """
        \(entity) is a tax-exempt organization under Section 501(c)(3) of the Internal Revenue Code, \
        and contributions are deductible to the extent allowed by law.
        """
    }

    /// The deductible portion. Never negative.
    var deductibleAmount: Money {
        guard input.providedGoodsOrServices else { return input.amount }
        let net = input.amount.minorUnits - input.goodsOrServicesValue.minorUnits
        return Money(minorUnits: max(0, net), currencyCode: input.amount.currencyCode)
    }

    // MARK: - Short forms

    /// The compact version for the bottom of a receipt, where there is one line
    /// of room rather than a paragraph. Still legally meaningful.
    var receiptFooterNote: String {
        if input.isPledge {
            return "Pledge confirmation — not a receipt for a completed contribution."
        }
        if input.isInKind {
            return """
            In-kind donation. \(input.organizationName) does not assign a value to donated property; \
            valuation is the donor's responsibility.
            """
        }
        if input.providedGoodsOrServices {
            return """
            Deductible portion: \(deductibleAmount.formatted) of \(input.amount.formatted) — the \
            remainder represents goods or services received.
            """
        }
        if input.isRecognized501c3 {
            return "No goods or services were provided in exchange for this contribution. Contributions are tax deductible to the extent allowed by law."
        }
        return "Contributions to \(input.organizationName) are not tax deductible."
    }

    /// Printed small at the very bottom of every document. An app that
    /// generates tax paperwork should say plainly that it is not a tax adviser.
    static let disclaimerFooter =
        "This document was prepared by the issuing organization. It is not tax advice; donors should consult their own tax adviser."

    /// The organization's own added sentence, if it set one.
    var customNoteParagraph: String? {
        input.customNote.trimmedOrNil
    }

    // MARK: - Warnings surfaced in the UI before rendering

    /// Things worth telling the staffer before the PDF exists. Advisory, not
    /// blocking — blocking conditions live on `Gift.blockersForDocument`.
    var advisories: [String] {
        var advisories: [String] = []

        if !input.isInKind,
           input.amount.minorUnits >= Threshold.writtenAcknowledgmentRequired,
           !input.isPledge {
            advisories.append("$250 or more — the donor needs this written acknowledgment to claim a deduction.")
        }

        if input.providedGoodsOrServices,
           input.amount.minorUnits > Threshold.quidProQuoDisclosure,
           !input.goodsOrServicesValue.isPositive {
            advisories.append("Enter the value of what the donor received; over $75 the disclosure is required.")
        }

        if input.isInKind, input.printDonorEstimatedValue, input.donorEstimatedValue.isPositive {
            advisories.append("The donor's estimated value will print, clearly labelled as their own estimate.")
        }

        if input.isInKind, input.donorEstimatedValue.minorUnits > Threshold.qualifiedAppraisal {
            advisories.append("Over $5,000 in-kind — mention Form 8283 Section B and a qualified appraisal.")
        }

        if !input.isRecognized501c3 {
            advisories.append("This organization is marked as not 501(c)(3) — the letter will say contributions are not deductible.")
        }

        return advisories
    }
}

// MARK: - Building the input from live records

extension TaxLanguage.Input {
    /// Bridges the models into the pure struct above. Kept as an extension so
    /// `TaxLanguage` itself has no dependency on SwiftData and stays trivially
    /// testable.
    init(gift: Gift, organization: Organization) {
        self.init(
            organizationName: organization.name,
            isRecognized501c3: organization.is501c3,
            fiscalSponsorNote: organization.fiscalSponsorNote,
            isInKind: gift.isInKind,
            amount: gift.amount,
            inKindDescription: gift.inKindDescription,
            donorEstimatedValue: gift.donorEstimatedValue,
            printDonorEstimatedValue: organization.printsDonorEstimatedValueOnInKind,
            providedGoodsOrServices: gift.providedGoodsOrServices,
            goodsOrServicesDescription: gift.goodsOrServicesDescription,
            goodsOrServicesValue: gift.goodsOrServicesValue,
            isPledge: gift.method == .pledge,
            customNote: organization.customTaxNote
        )
    }
}
