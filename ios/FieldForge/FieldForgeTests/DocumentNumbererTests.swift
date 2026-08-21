//
//  DocumentNumbererTests.swift
//  FieldForgeTests
//
//  Document numbers are how a donor's phone call gets resolved in ten seconds,
//  and how two staffers working offline avoid minting the same number. Both
//  properties are tested here.
//

import Foundation
import SwiftData
import Testing
@testable import FieldForge

@MainActor
struct DocumentNumbererTests {

    // MARK: Formatting

    @Test("Numbers are readable aloud and sort chronologically")
    func formatting() {
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 42) == "RCT-2026-0042")
        #expect(DocumentNumberer.format(prefix: "ack", year: 2026, sequence: 7) == "ACK-2026-0007")
        // Zero padding keeps a plain string sort in issue order.
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 1) < DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 2))
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 9) < DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 10))
    }

    @Test("Sequences past four digits are not truncated")
    func largeSequence() {
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 12_345) == "RCT-2026-12345")
    }

    @Test("A device tag is appended only when asked for")
    func deviceTag() {
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 42, deviceTag: "K7") == "RCT-2026-0042-K7")
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 42, deviceTag: "") == "RCT-2026-0042")
        #expect(DocumentNumberer.format(prefix: "RCT", year: 2026, sequence: 42, deviceTag: nil) == "RCT-2026-0042")
    }

    @Test("Device tags avoid characters that are misread aloud")
    func deviceTagAlphabet() {
        // Read over a phone, I/l/1 and O/0 are the same sound. Twenty samples
        // is plenty to catch an alphabet that includes them.
        for _ in 0..<20 {
            let tag = Organization.makeDeviceTag()
            #expect(tag.count == 2)
            #expect(!tag.contains("I"))
            #expect(!tag.contains("O"))
            #expect(!tag.contains("0"))
            #expect(!tag.contains("1"))
        }
    }

    // MARK: Revisions

    @Test("A revision keeps the original number visible")
    func revision() {
        #expect(DocumentNumberer.revision(of: "RCT-2026-0042", revision: 1) == "RCT-2026-0042-R1")
    }

    @Test("A second revision does not stack suffixes")
    func secondRevision() {
        let first = DocumentNumberer.revision(of: "RCT-2026-0042", revision: 1)
        let second = DocumentNumberer.revision(of: first, revision: 2)
        #expect(second == "RCT-2026-0042-R2")
    }

    @Test("A revision of a device-tagged number keeps the tag")
    func revisionWithDeviceTag() {
        #expect(DocumentNumberer.revision(of: "RCT-2026-0042-K7", revision: 1) == "RCT-2026-0042-K7-R1")
    }

    // MARK: Counters

    @Test("Taking a number advances only that document type's counter")
    func countersAreIndependent() throws {
        let organization = Organization(name: "Test Org")
        organization.sequenceYear = 2026
        organization.nextReceiptSequence = 1
        organization.nextLetterSequence = 1

        let receipt = DocumentNumberer.next(
            kind: .receipt,
            organization: organization,
            includeDeviceTag: false,
            now: date(year: 2026)
        )
        #expect(receipt == "RCT-2026-0001")
        #expect(organization.nextReceiptSequence == 2)
        #expect(organization.nextLetterSequence == 1)

        let letter = DocumentNumberer.next(
            kind: .letter,
            organization: organization,
            includeDeviceTag: false,
            now: date(year: 2026)
        )
        #expect(letter == "ACK-2026-0001")
        #expect(organization.nextLetterSequence == 2)
    }

    @Test("Counters reset on the first document of a new year")
    func yearRollover() {
        let organization = Organization(name: "Test Org")
        organization.sequenceYear = 2026
        organization.nextReceiptSequence = 148
        organization.nextLetterSequence = 91

        let number = DocumentNumberer.next(
            kind: .receipt,
            organization: organization,
            includeDeviceTag: false,
            now: date(year: 2027)
        )
        #expect(number == "RCT-2027-0001")
        #expect(organization.sequenceYear == 2027)
        // Both counters reset, so the letter series restarts too.
        #expect(organization.nextLetterSequence == 1)
    }

    @Test("A blank prefix falls back to a sensible default rather than an empty number")
    func blankPrefix() {
        let organization = Organization(name: "Test Org")
        organization.receiptPrefix = "   "
        organization.letterPrefix = ""

        let receipt = DocumentNumberer.next(kind: .receipt, organization: organization, includeDeviceTag: false)
        let letter = DocumentNumberer.next(kind: .letter, organization: organization, includeDeviceTag: false)
        #expect(receipt.hasPrefix("RCT-"))
        #expect(letter.hasPrefix("ACK-"))
    }

    // MARK: Collision avoidance against the store

    @Test("A number already in the store is skipped")
    func collisionIsAvoided() throws {
        let container = try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let organization = Organization(name: "Test Org")
        organization.sequenceYear = 2026
        organization.nextReceiptSequence = 1
        context.insert(organization)

        // Simulate a restored backup that replayed a counter: RCT-2026-0001
        // already exists even though the counter says 1.
        let existing = GeneratedDocument(kind: .receipt, documentNumber: "RCT-2026-0001")
        context.insert(existing)
        try context.save()

        let minted = DocumentNumberer.nextAvailable(
            kind: .receipt,
            organization: organization,
            includeDeviceTag: false,
            context: context,
            now: date(year: 2026)
        )
        #expect(minted != "RCT-2026-0001")
        #expect(minted == "RCT-2026-0002")
    }

    // MARK: Helper

    private func date(year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 6
        components.day = 15
        components.hour = 12
        return Calendar.current.date(from: components) ?? .now
    }
}
