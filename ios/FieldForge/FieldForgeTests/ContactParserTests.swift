//
//  ContactParserTests.swift
//  FieldForgeTests
//
//  The OCR parser is heuristics, and heuristics need tests more than exact code
//  does — a regression here quietly puts the wrong business name on a tax
//  letter. The bar is not perfection: it is "saves most of the typing, and
//  prefers a blank field to a wrong one".
//

import CoreGraphics
import Testing
@testable import FieldForge

struct ContactParserTests {

    /// Builds a synthetic OCR result. `height` stands in for type size, which is
    /// the signal the sign parser leans on.
    private func block(_ text: String, height: CGFloat, y: CGFloat = 0.5, confidence: Float = 0.9) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            confidence: confidence,
            boundingBox: CGRect(x: 0.1, y: y, width: 0.8, height: height)
        )
    }

    // MARK: Signs

    @Test("The largest text on a sign becomes the business name")
    func signNameFromLargestText() {
        let candidate = ContactParser.parseSign([
            block("OPEN MON-SAT 8-6", height: 0.04),
            block("DELGADO HARDWARE", height: 0.18),
            block("128 River Street, Rockford, IL 61104", height: 0.05),
            block("(779) 555-0142", height: 0.05),
        ])
        #expect(candidate.name == "Delgado Hardware")
        #expect(candidate.phone.contains("555"))
        #expect(candidate.isUsable)
    }

    @Test("All-caps signage is title-cased, mixed case is left exactly as printed")
    func nameTidying() {
        #expect(ContactParser.tidyBusinessName("DELGADO HARDWARE") == "Delgado Hardware")
        #expect(ContactParser.tidyBusinessName("THE CORNER STORE") == "The Corner Store")
        // Small words stay lower after the first position.
        #expect(ContactParser.tidyBusinessName("HOUSE OF PIES") == "House of Pies")
        // A brand that is deliberately mixed case must not be "corrected".
        #expect(ContactParser.tidyBusinessName("iRepair Phones") == "iRepair Phones")
        #expect(ContactParser.tidyBusinessName("McDonagh & Sons") == "McDonagh & Sons")
        // Leading bullets and rules from signage are trimmed.
        #expect(ContactParser.tidyBusinessName("• VINE & BARREL •") == "Vine & Barrel")
    }

    @Test("Opening hours and phone numbers are never mistaken for a name")
    func hoursAreNotNames() {
        // The hours are physically the biggest text here, which is exactly the
        // case that breaks a naive "largest text wins".
        let candidate = ContactParser.parseSign([
            block("OPEN 24 HOURS", height: 0.25),
            block("Northtown Auto Body", height: 0.10),
        ])
        #expect(candidate.name == "Northtown Auto Body")
    }

    @Test("Shape tests behave", arguments: [
        ("(779) 555-0142", true),
        ("779-555-0142", true),
        ("Delgado Hardware", false),
        ("Suite 300", false),
    ])
    func phoneShape(text: String, isPhone: Bool) {
        #expect(ContactParser.looksLikePhone(text) == isPhone)
    }

    @Test("URLs are recognised and excluded from names")
    func urlShape() {
        #expect(ContactParser.looksLikeURL("www.delgado.com"))
        #expect(ContactParser.looksLikeURL("https://delgado.org"))
        #expect(ContactParser.looksLikeURL("delgado.net"))
        // An email contains a dot and a com but is not a website.
        #expect(!ContactParser.looksLikeURL("ana@delgado.com"))
    }

    @Test("Company suffixes are detected so the org line can be told from the person")
    func companySuffixes() {
        #expect(ContactParser.hasCompanySuffix("Delgado Hardware Inc."))
        #expect(ContactParser.hasCompanySuffix("Riverside LLC"))
        #expect(ContactParser.hasCompanySuffix("Halverson & Sons"))
        #expect(!ContactParser.hasCompanySuffix("Ana Delgado"))
    }

    // MARK: Business cards

    @Test("A card's job title anchors the person's name on the line above it")
    func businessCardParsing() {
        let candidate = ContactParser.parseBusinessCard([
            block("Delgado Hardware Inc.", height: 0.10, y: 0.80),
            block("Ana Delgado", height: 0.09, y: 0.60),
            block("Owner", height: 0.05, y: 0.50),
            block("ana@delgado-hardware.com", height: 0.04, y: 0.30),
            block("(779) 555-0142", height: 0.04, y: 0.20),
        ])
        #expect(candidate.personName == "Ana Delgado")
        #expect(candidate.personTitle == "Owner")
        #expect(candidate.name == "Delgado Hardware Inc.")
        #expect(candidate.email == "ana@delgado-hardware.com")
        #expect(candidate.phone.contains("555"))
    }

    @Test("A minimalist card falls back to the email domain for the company")
    func emailDomainFallback() {
        let candidate = ContactParser.parseBusinessCard([
            block("Priya Raman", height: 0.10, y: 0.70),
            block("priya@vinebarrel.com", height: 0.05, y: 0.40),
        ])
        #expect(candidate.personName == "Priya Raman")
        #expect(candidate.name == "Vinebarrel")
    }

    @Test("A personal email domain is not treated as a company name")
    func consumerDomainIsIgnored() {
        let candidate = ContactParser.parseBusinessCard([
            block("Tom Alder", height: 0.10, y: 0.70),
            block("tomalder@gmail.com", height: 0.05, y: 0.40),
        ])
        #expect(candidate.name != "Gmail")
    }

    @Test("Person-name detection rejects the things that are not names")
    func personNameShape() {
        #expect(ContactParser.looksLikePersonName("Ana Delgado"))
        #expect(ContactParser.looksLikePersonName("Rev. Tom Alder"))
        #expect(!ContactParser.looksLikePersonName("Delgado Hardware Inc."))
        #expect(!ContactParser.looksLikePersonName("128 River Street"))
        #expect(!ContactParser.looksLikePersonName("Owner"))
        #expect(!ContactParser.looksLikePersonName(""))
    }

    // MARK: Applying to a draft

    @Test("Applying to a draft fills blanks and never overwrites typed values")
    func applyDoesNotOverwrite() {
        var fields = DocumentDraft.NewContactFields()
        fields.name = "What I actually typed"

        var candidate = ParsedContactCandidate()
        candidate.name = "OCR GUESS"
        candidate.phone = "(779) 555-0142"
        candidate.city = "Rockford"

        candidate.apply(to: &fields, source: .signOCR)

        // The typed name survives; the blank fields get filled.
        #expect(fields.name == "What I actually typed")
        #expect(fields.phone == "(779) 555-0142")
        #expect(fields.city == "Rockford")
        // And the record remembers it was machine-read, so the UI can flag it.
        #expect(fields.source == .signOCR)
        #expect(fields.source.needsHumanReview)
    }

    @Test("An unreadable sign produces an unusable candidate rather than nonsense")
    func unreadableSign() {
        let candidate = ContactParser.parseSign([])
        #expect(!candidate.isUsable)
        #expect(candidate.name.isEmpty)

        let lowConfidence = ContactParser.parseSign([
            block("░▒▓", height: 0.2, confidence: 0.1)
        ])
        #expect(!lowConfidence.isUsable)
    }

    @Test("Text the parser could not place is kept rather than discarded")
    func unmatchedLinesArePreserved() {
        let candidate = ContactParser.parseSign([
            block("VINE & BARREL", height: 0.20),
            block("Est. 1974 — ask about the wine club", height: 0.05),
        ])
        #expect(candidate.unmatchedLines.contains { $0.contains("wine club") })
    }
}
