//
//  DraftAndGiftRuleTests.swift
//  FieldForgeTests
//
//  The business rules that keep the books honest: what counts toward giving,
//  what a draft considers "enough to proceed", and that a draft survives being
//  written to disk and read back.
//

import Foundation
import Testing
@testable import FieldForge

struct GiftRuleTests {

    @Test("Pledges and voided gifts do not count toward lifetime giving")
    func countsTowardGiving() {
        let cash = Gift(amount: Money(dollars: 100), method: .cash)
        #expect(cash.countsTowardGiving)

        let pledge = Gift(amount: Money(dollars: 100), method: .pledge)
        #expect(!pledge.countsTowardGiving)

        let voided = Gift(amount: Money(dollars: 100), method: .check)
        voided.void(reason: "Cheque bounced")
        #expect(!voided.countsTowardGiving)
        #expect(voided.isVoided)
        // Voiding keeps the record rather than deleting it — a receipt was
        // already handed over and the history should show that.
        #expect(voided.voidReason == "Cheque bounced")
    }

    @Test("The deductible amount is never negative")
    func deductibleFloor() {
        let gift = Gift(amount: Money(dollars: 50), method: .cash)
        gift.providedGoodsOrServices = true
        gift.goodsOrServicesValueMinorUnits = 6_000
        #expect(gift.deductibleAmount.minorUnits == 0)
    }

    @Test("Substantiation thresholds are applied to the right gifts")
    func thresholds() {
        let small = Gift(amount: Money(dollars: 100), method: .cash)
        #expect(!small.requiresWrittenAcknowledgment)

        let large = Gift(amount: Money(dollars: 250), method: .cash)
        #expect(large.requiresWrittenAcknowledgment)

        // In-kind gifts have no cash amount, so the cash threshold cannot apply.
        let inKind = Gift(amount: .zero, method: .inKind)
        inKind.donorEstimatedValueMinorUnits = 100_000
        #expect(!inKind.requiresWrittenAcknowledgment)
        #expect(!inKind.mayNeedForm8283)

        let bigInKind = Gift(amount: .zero, method: .inKind)
        bigInKind.donorEstimatedValueMinorUnits = 600_000
        #expect(bigInKind.mayNeedForm8283)
    }

    @Test("Quid pro quo disclosure kicks in above $75, not at it")
    func quidProQuoThreshold() {
        let atThreshold = Gift(amount: Money(dollars: 75), method: .cash)
        atThreshold.providedGoodsOrServices = true
        #expect(!atThreshold.requiresQuidProQuoDisclosure)

        let above = Gift(amount: Money(dollars: 75, cents: 1), method: .cash)
        above.providedGoodsOrServices = true
        #expect(above.requiresQuidProQuoDisclosure)
    }

    @Test("A zero-amount cash gift is blocked, an in-kind one is not")
    func zeroAmountRules() {
        let zeroCash = Gift(amount: .zero, method: .cash)
        #expect(zeroCash.blockersForDocument(kind: .receipt).contains { $0.contains("amount") })

        let inKind = Gift(amount: .zero, method: .inKind)
        inKind.inKindDescription = "12 crates of tinned peaches"
        #expect(inKind.blockersForDocument(kind: .receipt).isEmpty)
    }
}

struct DocumentDraftTests {

    @Test("A name alone is enough to proceed past the first step")
    func hasWho() {
        var draft = DocumentDraft()
        #expect(!draft.hasWho)

        draft.newContact.name = "The taqueria on 5th"
        #expect(draft.hasWho)

        var chosen = DocumentDraft()
        chosen.existingContactID = UUID()
        #expect(chosen.hasWho)
    }

    @Test("A visit with no gift is a valid thing to record")
    func visitOnly() {
        var draft = DocumentDraft()
        draft.newContact.name = "Kellerman Dental"
        #expect(draft.isVisitOnly)
        #expect(!draft.hasWhat)

        draft.amountText = "2500"
        #expect(!draft.isVisitOnly)
        #expect(draft.hasWhat)
        #expect(draft.amount.minorUnits == 250_000)
    }

    @Test("An in-kind draft needs a description rather than an amount")
    func inKindDraft() {
        var draft = DocumentDraft()
        draft.newContact.name = "Vine & Barrel"
        draft.method = .inKind
        #expect(!draft.hasWhat)

        draft.inKindDescription = "Six cases of sparkling water"
        #expect(draft.hasWhat)
        #expect(draft.isInKind)
    }

    @Test("A draft survives a round trip through the resume file")
    func roundTrip() throws {
        var draft = DocumentDraft()
        draft.newContact.name = "Delgado Hardware"
        draft.amountText = "25000"
        draft.documentKind = .letter
        draft.warmth = .champion
        draft.method = .applePay
        draft.isPaymentConfirmed = true
        draft.confirmedInstrumentDescription = "Visa 4242"
        draft.signaturePNG = Data([0x89, 0x50, 0x4E, 0x47])
        draft.tagsToAdd = ["main street", "matches gifts"]
        draft.latitude = 42.2588
        draft.longitude = -89.0940

        let encoded = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(DocumentDraft.self, from: encoded)

        #expect(decoded.newContact.name == "Delgado Hardware")
        #expect(decoded.amount.minorUnits == 2_500_000)
        #expect(decoded.documentKind == .letter)
        #expect(decoded.warmth == .champion)
        #expect(decoded.isPaymentConfirmed)
        #expect(decoded.confirmedInstrumentDescription == "Visa 4242")
        #expect(decoded.signaturePNG == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(decoded.tagsToAdd == ["main street", "matches gifts"])
        #expect(decoded.latitude == 42.2588)
    }

    @Test("Quantity parsing tolerates whatever gets typed")
    func quantityParsing() {
        var draft = DocumentDraft()
        draft.inKindQuantityText = "42"
        #expect(draft.inKindQuantity == 42)

        draft.inKindQuantityText = "about 12 crates"
        #expect(draft.inKindQuantity == 12)

        draft.inKindQuantityText = "several"
        #expect(draft.inKindQuantity == 0)
    }
}

struct EntitlementRuleTests {

    @Test("Everything a donor's document depends on is free")
    func documentFeaturesAreFree() {
        // If any of these ever becomes paid, a donor's tax letter starts
        // depending on somebody's subscription. That is the line.
        #expect(Feature.documentGeneration.isFree)
        #expect(Feature.signatureCapture.isFree)
        #expect(Feature.coreBranding.isFree)
        #expect(Feature.documentDelivery.isFree)
        #expect(Feature.offlineQueue.isFree)
        #expect(Feature.coreCRM.isFree)
        #expect(Feature.paymentCapture.isFree)
    }

    @Test("Team features are the ones about teams and scale")
    func paidFeaturesArePaid() {
        #expect(!Feature.sharedTeamMemory.isFree)
        #expect(!Feature.multipleOrganizations.isFree)
        #expect(!Feature.bulkExport.isFree)
    }

    @Test("Every paid feature can explain itself on the paywall")
    func paidFeaturesHaveCopy() {
        for feature in Feature.allCases where !feature.isFree {
            #expect(feature.paywallDescription != nil, "\(feature.rawValue) has nothing to say for itself")
            #expect(!feature.lockedExplanation.isEmpty)
        }
    }
}

struct OutboxItemTests {

    @Test("Backoff grows and then caps")
    func backoff() {
        let item = OutboxItem(kind: .emailDocument, subjectID: UUID())
        let created = item.createdAt

        // Never attempted: retry immediately.
        #expect(item.nextRetryAllowedAt == created)

        item.recordFailure("first")
        let firstDelay = item.nextRetryAllowedAt.timeIntervalSince(item.lastAttemptAt ?? created)
        item.recordFailure("second")
        let secondDelay = item.nextRetryAllowedAt.timeIntervalSince(item.lastAttemptAt ?? created)
        #expect(secondDelay > firstDelay)
        #expect(secondDelay <= 3_600)
    }

    @Test("Five failures gives up, and the record survives")
    func abandonment() {
        let item = OutboxItem(kind: .emailDocument, subjectID: UUID())
        for index in 1...5 {
            item.recordFailure("attempt \(index)")
        }
        #expect(item.hasExhaustedRetries)
        #expect(item.isAbandoned)
        #expect(!item.isPending)
        // The failure reason is kept so the UI can explain rather than shrug.
        #expect(item.lastError == "attempt 5")
    }

    @Test("Success clears the error and stops the item being pending")
    func success() {
        let item = OutboxItem(kind: .reverseGeocode, subjectID: UUID())
        item.recordFailure("no network")
        item.recordSuccess()
        #expect(!item.isPending)
        #expect(item.lastError.isEmpty)
        #expect(item.completedAt != nil)
    }

    @Test("Payloads round trip through JSON")
    func payloads() {
        let payload = OutboxItem.EmailPayload(
            recipient: "ana@example.com",
            subject: "Your receipt",
            body: "Thank you",
            fileName: "Receipt-RCT-2026-0001.pdf"
        )
        let item = OutboxItem(
            kind: .emailDocument,
            subjectID: UUID(),
            payload: OutboxItem.encodePayload(payload)
        )
        let decoded = item.decodePayload(OutboxItem.EmailPayload.self)
        #expect(decoded?.recipient == "ana@example.com")
        #expect(decoded?.fileName == "Receipt-RCT-2026-0001.pdf")
    }
}
