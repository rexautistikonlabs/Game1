//
//  TaxLanguageTests.swift
//  FieldForgeTests
//
//  The substantiation language is the part of this app where being wrong causes
//  a donor a real problem with the IRS, so it is the part with the most tests.
//
//  Each test names the rule it is protecting.
//

import Testing
@testable import FieldForge

struct TaxLanguageTests {

    private func input(
        amount: Money = Money(dollars: 250),
        isInKind: Bool = false,
        inKindDescription: String = "",
        donorEstimate: Money = .zero,
        printDonorEstimate: Bool = false,
        quidProQuo: Bool = false,
        benefitDescription: String = "",
        benefitValue: Money = .zero,
        is501c3: Bool = true,
        isPledge: Bool = false
    ) -> TaxLanguage.Input {
        TaxLanguage.Input(
            organizationName: "Riverside Food Collective",
            isRecognized501c3: is501c3,
            isInKind: isInKind,
            amount: amount,
            inKindDescription: inKindDescription,
            donorEstimatedValue: donorEstimate,
            printDonorEstimatedValue: printDonorEstimate,
            providedGoodsOrServices: quidProQuo,
            goodsOrServicesDescription: benefitDescription,
            goodsOrServicesValue: benefitValue,
            isPledge: isPledge
        )
    }

    // MARK: The required sentence

    @Test("A plain cash gift states that no goods or services were provided")
    func plainCashGift() {
        let language = TaxLanguage(input())
        let paragraph = language.substantiationParagraph
        // Publication 1771 requires this statement on an acknowledgment of
        // $250 or more. Its absence is the most common defect in real letters.
        #expect(paragraph.contains("No goods or services were provided"))
        #expect(paragraph.contains("501(c)(3)"))
        #expect(paragraph.contains("deductible"))
    }

    @Test("A non-501(c)(3) organization says contributions are NOT deductible")
    func nonCharitableOrganization() {
        let language = TaxLanguage(input(is501c3: false))
        let paragraph = language.substantiationParagraph
        #expect(paragraph.contains("not deductible"))
        #expect(!paragraph.contains("501(c)(3) of the Internal Revenue Code, and contributions are deductible"))
    }

    // MARK: In-kind

    @Test("An in-kind acknowledgment never assigns a value to the property")
    func inKindDoesNotValue() {
        let language = TaxLanguage(input(
            amount: .zero,
            isInKind: true,
            inKindDescription: "42 twin blankets, new in packaging",
            donorEstimate: Money(dollars: 900)
        ))
        let paragraph = language.substantiationParagraph

        #expect(paragraph.contains("does not assign a value"))
        #expect(paragraph.contains("responsibility of the donor"))
        #expect(paragraph.contains("42 twin blankets"))
        // The donor's own estimate must NOT appear unless the organization
        // explicitly opted in — that is the whole point of the setting.
        #expect(!paragraph.contains("900"))
    }

    @Test("An opted-in donor estimate is printed but attributed to the donor")
    func inKindWithOptedInEstimate() {
        let language = TaxLanguage(input(
            amount: .zero,
            isInKind: true,
            inKindDescription: "a used delivery van",
            donorEstimate: Money(dollars: 4_000),
            printDonorEstimate: true
        ))
        let paragraph = language.substantiationParagraph
        #expect(paragraph.contains("provided by the donor"))
        #expect(paragraph.contains("has not been verified"))
    }

    @Test("Noncash gifts over $5,000 mention an appraisal and Form 8283")
    func largeNoncashGift() {
        let language = TaxLanguage(input(
            amount: .zero,
            isInKind: true,
            inKindDescription: "a residential lot",
            donorEstimate: Money(dollars: 25_000),
            printDonorEstimate: true
        ))
        #expect(language.substantiationParagraph.contains("Form 8283"))
        #expect(language.substantiationParagraph.contains("qualified appraisal"))
    }

    @Test("Noncash gifts between $500 and $5,000 mention Form 8283 only")
    func mediumNoncashGift() {
        let language = TaxLanguage(input(
            amount: .zero,
            isInKind: true,
            inKindDescription: "office chairs",
            donorEstimate: Money(dollars: 1_200),
            printDonorEstimate: true
        ))
        let paragraph = language.substantiationParagraph
        #expect(paragraph.contains("Form 8283"))
        #expect(!paragraph.contains("qualified appraisal"))
    }

    // MARK: Quid pro quo

    @Test("Quid pro quo states the deductible portion and shows the arithmetic")
    func quidProQuoArithmetic() {
        let language = TaxLanguage(input(
            amount: Money(dollars: 200),
            quidProQuo: true,
            benefitDescription: "two dinner seats",
            benefitValue: Money(dollars: 75)
        ))
        #expect(language.deductibleAmount.minorUnits == 12_500)

        let paragraph = language.substantiationParagraph
        #expect(paragraph.contains("two dinner seats"))
        #expect(paragraph.contains("good-faith estimate"))
        #expect(paragraph.contains("excess of the amount you paid"))
    }

    @Test("A benefit worth more than the payment leaves nothing deductible, never a negative")
    func benefitExceedsPayment() {
        let language = TaxLanguage(input(
            amount: Money(dollars: 50),
            quidProQuo: true,
            benefitDescription: "a gala seat",
            benefitValue: Money(dollars: 60)
        ))
        #expect(language.deductibleAmount.minorUnits == 0)
        #expect(language.substantiationParagraph.contains("no portion of"))
    }

    // MARK: Pledges

    @Test("A pledge is explicitly not acknowledged as a completed gift")
    func pledgeIsNotAGift() {
        let language = TaxLanguage(input(isPledge: true))
        let paragraph = language.substantiationParagraph
        #expect(paragraph.contains("not a receipt for a completed gift"))
        #expect(!paragraph.contains("No goods or services were provided"))
    }

    // MARK: Receipt short form

    @Test("The receipt footer carries real meaning, not just a thank-you")
    func receiptFooter() {
        #expect(TaxLanguage(input()).receiptFooterNote.contains("No goods or services"))
        #expect(TaxLanguage(input(isInKind: true, inKindDescription: "blankets"))
            .receiptFooterNote.contains("does not assign a value"))
        #expect(TaxLanguage(input(is501c3: false)).receiptFooterNote.contains("not tax deductible"))
    }

    // MARK: Advisories

    @Test("A gift at the $250 threshold advises that a written acknowledgment is needed")
    func thresholdAdvisory() {
        let atThreshold = TaxLanguage(input(amount: Money(dollars: 250)))
        #expect(atThreshold.advisories.contains { $0.contains("$250 or more") })

        let below = TaxLanguage(input(amount: Money(dollars: 249, cents: 99)))
        #expect(!below.advisories.contains { $0.contains("$250 or more") })
    }

    @Test("A quid pro quo over $75 with no stated benefit value is flagged")
    func missingBenefitValueAdvisory() {
        let language = TaxLanguage(input(
            amount: Money(dollars: 100),
            quidProQuo: true,
            benefitDescription: "a tote bag"
        ))
        #expect(language.advisories.contains { $0.contains("over $75") })
    }

    @Test("Thresholds match the published figures")
    func thresholdsAreCorrect() {
        #expect(TaxLanguage.Threshold.writtenAcknowledgmentRequired == 25_000)   // $250
        #expect(TaxLanguage.Threshold.quidProQuoDisclosure == 7_500)             // $75
        #expect(TaxLanguage.Threshold.form8283 == 50_000)                        // $500
        #expect(TaxLanguage.Threshold.qualifiedAppraisal == 500_000)             // $5,000
    }

    @Test("Every document carries the not-tax-advice disclaimer")
    func disclaimerExists() {
        #expect(TaxLanguage.disclaimerFooter.contains("not tax advice"))
    }
}
