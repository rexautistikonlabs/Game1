//
//  ProductPassTests.swift
//  FieldForgeTests
//
//  Gift vs document statuses, required next action, pay-by-link only in
//  capture, and launch rules (no CloudKit, no sk_).
//

import Foundation
import SwiftData
import Testing
@testable import FieldForge

@MainActor
struct GiftAndDocumentStatusTests {

    @Test("Promised does not count as Raised")
    func promisedIsCommitmentNotRaised() {
        let pledge = Gift(amount: Money(dollars: 100), method: .pledge)
        #expect(pledge.giftStatus == .promised)
        #expect(!pledge.countsTowardGiving)
        #expect(pledge.countsAsCommitment)

        let unpaid = Gift(amount: Money(dollars: 100), method: .textPayLink)
        unpaid.isPaymentConfirmed = false
        #expect(unpaid.giftStatus == .promised)
        #expect(!unpaid.countsTowardGiving)
        #expect(unpaid.countsAsCommitment)
    }

    @Test("Cash and succeeded pay links count as received Raised")
    func receivedCountsAsRaised() {
        let cash = Gift(amount: Money(dollars: 100), method: .cash)
        #expect(cash.giftStatus == .received)
        #expect(cash.countsTowardGiving)
        #expect(!cash.countsAsCommitment)

        let link = Gift(amount: Money(dollars: 100), method: .emailPayLink)
        link.isPaymentConfirmed = true
        link.paymentIntentStatus = "succeeded"
        #expect(link.giftStatus == .received)
        #expect(link.countsTowardGiving)
    }

    @Test("A tax letter needs received or deposited, plus Stripe succeeded for pay links")
    func taxLetterGates() {
        let promised = Gift(amount: Money(dollars: 250), method: .textPayLink)
        #expect(!promised.blockersForDocument(kind: .letter).isEmpty)

        let unpaid = Gift(amount: Money(dollars: 250), method: .emailPayLink)
        unpaid.giftStatus = .received
        unpaid.isPaymentConfirmed = true
        unpaid.paymentIntentStatus = "processing"
        #expect(unpaid.blockersForDocument(kind: .letter).contains { $0.lowercased().contains("succeeded") })

        let paid = Gift(amount: Money(dollars: 250), method: .textPayLink)
        paid.giftStatus = .received
        paid.isPaymentConfirmed = true
        paid.paymentIntentStatus = "succeeded"
        #expect(paid.blockersForDocument(kind: .letter).isEmpty)

        let cash = Gift(amount: Money(dollars: 250), method: .cash)
        cash.giftStatus = .received
        #expect(cash.blockersForDocument(kind: .letter).isEmpty)

        let recorded = Gift(amount: Money(dollars: 250), method: .cardManual)
        recorded.giftStatus = .received
        recorded.referenceNumber = "4242"
        #expect(recorded.blockersForDocument(kind: .letter).isEmpty)
    }

    @Test("Voiding a document does not void the gift")
    func voidDocumentLeavesGift() throws {
        let container = try ModelContainer(
            for: Persistence.schema,
            configurations: Persistence.inMemoryConfiguration
        )
        let context = container.mainContext
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107", city: "Rockford", state: "IL")
        organization.addressLine1 = "412 South Water Street"
        organization.signatoryName = "Maritza"
        context.insert(organization)
        let contact = Contact(name: "Delgado Hardware")
        context.insert(contact)
        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.contact = contact
        gift.organization = organization
        gift.giftStatus = .received
        context.insert(gift)
        let document = try DocumentEngine.issue(
            kind: .receipt,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )
        #expect(document.documentStatus == .draft)
        try DocumentEngine.void(document, reason: "Wrong template", context: context)
        #expect(document.documentStatus == .voided)
        #expect(gift.giftStatus == .received)
        #expect(!gift.isVoided)
    }
}

struct VisitNextActionTests {

    @Test("Capture cannot finish without a next action")
    func nextActionRequired() {
        var draft = DocumentDraft()
        draft.newContact.name = "Delgado Hardware"
        #expect(!draft.hasRequiredNextAction)

        draft.nextAction = .followUp
        #expect(!draft.hasRequiredNextAction)

        draft.returnAt = Calendar.current.date(byAdding: .day, value: 7, to: .now)
        #expect(draft.hasRequiredNextAction)

        draft.nextAction = .noInterest
        #expect(draft.hasRequiredNextAction)

        draft.nextAction = .returnDate
        draft.returnAt = nil
        #expect(!draft.hasRequiredNextAction)
    }

    @Test("Legacy visit outcomes map onto next actions")
    func legacyMapping() {
        #expect(VisitNextAction.fromStored("gaveNow") == .donationReceived)
        #expect(VisitNextAction.fromStored("pledged") == .donationPromised)
        #expect(VisitNextAction.fromStored("wrongPerson") == .decisionMakerUnavailable)
        #expect(VisitNextAction.fromStored("declined") == .noInterest)
        #expect(VisitNextAction.fromStored("doNotSolicit") == .doNotSolicit)
        #expect(VisitNextAction.fromStored("") == nil)
    }

    @Test("Do not solicit excludes them from Who to see")
    func doNotSolicitExcludes() {
        let contact = Contact(name: "Corner Laundromat")
        let visit = Visit(nextAction: .doNotSolicit)
        visit.contact = contact
        contact.visits = [visit]
        contact.isDoNotContact = visit.nextAction?.excludesFromRoute == true
        #expect(contact.isDoNotContact)
        #expect(VisitNextAction.doNotSolicit.excludesFromRoute)
    }
}

@MainActor
struct StatusMigrationTests {

    @Test("Succeeded Stripe or cash becomes Gift received; sent letter becomes Document delivered")
    func migratesExistingRows() throws {
        let container = try ModelContainer(
            for: Persistence.schema,
            configurations: Persistence.inMemoryConfiguration
        )
        let context = container.mainContext

        let cash = Gift(amount: Money(dollars: 40), method: .cash)
        cash.isPaymentConfirmed = true
        context.insert(cash)

        let paid = Gift(amount: Money(dollars: 25), method: .textPayLink)
        paid.isPaymentConfirmed = true
        paid.paymentIntentStatus = "succeeded"
        context.insert(paid)

        let pledge = Gift(amount: Money(dollars: 100), method: .pledge)
        context.insert(pledge)

        let sent = GeneratedDocument(kind: .letter, documentNumber: "ACK-1")
        sent.deliveryState = .sent
        context.insert(sent)

        let draft = GeneratedDocument(kind: .receipt, documentNumber: "RCT-1")
        draft.deliveryState = .saved
        context.insert(draft)

        let visit = Visit()
        visit.outcomeRawValue = "gaveNow"
        context.insert(visit)

        StatusMigration.migrateIfNeeded(context: context)

        #expect(cash.giftStatus == .received)
        #expect(paid.giftStatus == .received)
        #expect(pledge.giftStatus == .promised)
        #expect(sent.documentStatus == .delivered)
        #expect(draft.documentStatus == .draft)
        #expect(visit.nextAction == .donationReceived)
    }
}

@MainActor
struct CapturePaymentPathTests {

    @Test("Capture method tiles are pay link plus manual; no staff Apple Pay")
    func noStaffApplePayInCapture() {
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
        let coordinator = PaymentCoordinator(reachability: Reachability())
        #expect(!coordinator.methodOptions.contains { $0.method == .applePay })
        #expect(coordinator.methodOptions.contains { $0.method == .textPayLink })
        #expect(coordinator.methodOptions.contains { $0.method == .emailPayLink })
        #expect(coordinator.methodOptions.contains { $0.method == .cash })
        #expect(coordinator.methodOptions.contains { $0.method == .check })
        #expect(coordinator.methodOptions.contains { $0.method == .cardManual })
        #expect(coordinator.methodOptions.contains { $0.method == .inKind })
        #expect(coordinator.methodOptions.contains { $0.method == .pledge })
        let tap = coordinator.methodOptions.first { $0.method == .tapToPay }
        #expect(tap != nil)
        // Selectable: Collect / Next is what starts Terminal (or the alert).
        #expect(tap?.isEnabled == true)
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
    }

    @Test("Collecting Apple Pay from capture is refused")
    func collectApplePayIsOff() async {
        let coordinator = PaymentCoordinator(reachability: Reachability())
        let outcome = await coordinator.collect(
            method: .applePay,
            request: PaymentRequest(
                amount: Money(dollars: 1),
                summaryLabel: "Donation",
                merchantName: "Riverside",
                fundName: "General"
            )
        )
        if case .failed(let failure) = outcome {
            #expect(failure.diagnosticCode == "staff-apple-pay-off")
        } else {
            Issue.record("staff Apple Pay must not charge from capture")
        }
    }

    @Test("Launch does not attach CloudKit and never stores sk_")
    func launchRules() {
        #expect(!Persistence.attachesCloudKitAtLaunch)
        #expect(!StripePaymentSettings.isPublishableKey("sk_live_abc12345"))
        #expect(!StripePaymentSettings.isPublishableKey("sk_test_abc12345"))
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
        #expect(TapToPayCollectUI.timeoutSeconds == 60)
        #expect(
            TapToPayCollectUI.missingLocationMessage.contains("STRIPE_TERMINAL_LOCATION_ID")
        )
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
    }
}
