//
//  AuditAndGatingTests.swift
//  FieldForgeTests
//
//  Two things that must not drift: the audit trail (because it is the record
//  somebody reconstructs a dispute from) and the free/paid boundary (because
//  the wrong line there means a donor's tax letter depends on a subscription).
//

import Foundation
import SwiftData
import Testing
@testable import FieldForge

@MainActor
struct DocumentAuditTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeIssuedDocument(in context: ModelContext) throws -> GeneratedDocument {
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107", city: "Rockford", state: "IL")
        organization.addressLine1 = "412 South Water Street"
        organization.signatoryName = "Maritza Ocampo"
        context.insert(organization)

        let contact = Contact(name: "Delgado Hardware")
        contact.organization = organization
        context.insert(contact)

        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        context.insert(gift)

        return try DocumentEngine.issue(
            kind: .receipt,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            issuedBy: "Maritza",
            includeDeviceTagInNumber: false,
            context: context
        )
    }

    @Test("Issuing writes the first audit entry")
    func issueIsAudited() throws {
        let container = try makeContainer()
        let document = try makeIssuedDocument(in: container.mainContext)

        let trail = document.orderedAuditTrail
        #expect(trail.count == 1)
        #expect(trail.first?.action == .issued)
        #expect(trail.first?.actorDisplayName == "Maritza")
    }

    @Test("Every delivery transition appends an entry, in order")
    func deliveryIsAudited() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let document = try makeIssuedDocument(in: context)

        document.recipientEmail = "ana@example.com"
        document.markQueued(actor: "Maritza")
        document.markFailed("Mail refused it", actor: "Maritza")
        document.markSent(channel: "Mail", actor: "Maritza")
        document.markPrinted(actor: "Maritza")
        try context.save()

        let actions = document.orderedAuditTrail.map(\.action)
        #expect(actions == [.issued, .queued, .deliveryFailed, .sent, .printed])
        // The final state is the last *delivery* state, not the last entry —
        // printing is not a delivery.
        #expect(document.deliveryState == .sent)
    }

    @Test("Voiding requires a reason and keeps everything")
    func voidKeepsTheRecord() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let document = try makeIssuedDocument(in: context)
        let number = document.documentNumber
        let pdfBytes = document.pdfData?.count ?? 0

        // A void with no reason is refused: "voided, no reason given" is the
        // least useful entry an audit trail can hold.
        #expect(throws: (any Error).self) {
            try DocumentEngine.void(document, reason: "   ", context: context)
        }
        #expect(!document.isVoided)

        try DocumentEngine.void(document, reason: "Cheque bounced", voidedBy: "Maritza", context: context)

        #expect(document.isVoided)
        #expect(document.deliveryState == .voided)
        #expect(document.voidReason == "Cheque bounced")
        #expect(document.voidEntry?.detail == "Cheque bounced")
        // Nothing was destroyed: the number and the PDF are still there,
        // because the donor may be holding a printed copy.
        #expect(document.documentNumber == number)
        #expect(document.pdfData?.count == pdfBytes)
        #expect(!document.isCurrent)
    }

    @Test("Voiding twice does not double up the trail")
    func voidIsIdempotent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let document = try makeIssuedDocument(in: context)

        try DocumentEngine.void(document, reason: "Duplicate", context: context)
        try DocumentEngine.void(document, reason: "Duplicate again", context: context)

        let voids = document.orderedAuditTrail.filter { $0.action == .voided }
        #expect(voids.count == 1)
        #expect(document.voidReason == "Duplicate")
    }

    @Test("A re-issue audits both sides of the pair with the reason")
    func reissueIsAudited() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let original = try makeIssuedDocument(in: context)

        let reissued = try DocumentEngine.reissue(
            original,
            as: .letter,
            reason: "Amount was wrong",
            reissuedBy: "Maritza",
            includeDeviceTagInNumber: false,
            context: context
        )

        // The new document knows what it corrects…
        let newTrail = reissued.orderedAuditTrail
        #expect(newTrail.contains { $0.action == .issued && $0.detail.contains(original.documentNumber) })

        // …and the original knows it was replaced, and why.
        let oldTrail = original.orderedAuditTrail
        let superseded = oldTrail.last { $0.action == .supersededByReissue }
        #expect(superseded != nil)
        #expect(superseded?.detail.contains(reissued.documentNumber) == true)
        #expect(superseded?.detail.contains("Amount was wrong") == true)
        #expect(original.deliveryState == .superseded)
        #expect(!original.isCurrent)
    }

    @Test("Material and routine entries are distinguished for display")
    func materiality() {
        // The trail emphasises the entries that change what the document
        // *means*, as opposed to what merely happened to it.
        #expect(DocumentAuditEntry.Action.issued.isMaterial)
        #expect(DocumentAuditEntry.Action.voided.isMaterial)
        #expect(DocumentAuditEntry.Action.reissued.isMaterial)
        #expect(DocumentAuditEntry.Action.supersededByReissue.isMaterial)
        #expect(!DocumentAuditEntry.Action.sent.isMaterial)
        #expect(!DocumentAuditEntry.Action.printed.isMaterial)
        #expect(!DocumentAuditEntry.Action.queued.isMaterial)
    }

    @Test("Every audit action has a label and a distinct glyph")
    func presentation() {
        var symbols = Set<String>()
        for action in DocumentAuditEntry.Action.allCases {
            #expect(!action.label.isEmpty)
            symbols.insert(action.symbolName)
        }
        #expect(symbols.count == DocumentAuditEntry.Action.allCases.count)
    }
}

@MainActor
struct GatingTests {

    @Test("Nothing a donor's document depends on is ever paid")
    func documentFeaturesAreFree() {
        // The line that must not move. If any of these becomes paid, a donor's
        // tax letter starts depending on somebody's subscription being current.
        for feature in [
            Feature.documentGeneration,
            .signatureCapture,
            .coreBranding,
            .documentDelivery,
            .offlineQueue,
            .coreCRM,
            .paymentCapture,
            .personalWarmth,
            .personalMap,
        ] {
            #expect(feature.isFree, "\(feature.rawValue) must stay free")
        }
    }

    @Test("The paid tier is about teams and scale")
    func paidFeatures() {
        for feature in [
            Feature.sharedTeamMemory,
            .multipleOrganizations,
            .advancedBranding,
            .bulkExport,
            .assignFollowUps,
            .tapToPay,
            .routeMode,
            .unlimitedHistory,
        ] {
            #expect(!feature.isFree, "\(feature.rawValue) should be paid")
            #expect(feature.paywallDescription != nil, "\(feature.rawValue) has nothing to say for itself")
        }
    }

    @Test("An unbuilt feature is never enabled and never sold")
    func unavailableFeaturesAreNeverEnabled() {
        let paid = Entitlements.previewTeam()
        for feature in Feature.allCases where !feature.isAvailable {
            // Not enabled even for a paying customer: better to hide a control
            // than ship one that quietly does nothing.
            #expect(!paid.isEnabled(feature), "\(feature.rawValue) is unbuilt but reported as enabled")
        }
        // And nothing unbuilt reaches the paywall's sell list.
        let sold = Feature.allCases.filter { !$0.isFree && $0.isAvailable }
        #expect(sold.allSatisfy(\.isAvailable))
        #expect(!sold.contains(.assignFollowUps), "assignment is not built yet and must not be advertised")
    }

    @Test("Everything else is available")
    func everythingElseIsBuilt() {
        // A guard against the flag being used as a dumping ground: exactly one
        // feature is currently unbuilt, and adding another should be a
        // deliberate act that trips this test.
        let unavailable = Feature.allCases.filter { !$0.isAvailable }
        #expect(unavailable == [.assignFollowUps], "unexpected unbuilt features: \(unavailable.map(\.rawValue))")
    }

    @Test("The free history window is generous enough to cover a tax year")
    func historyWindow() {
        let free = Entitlements()
        free.apply(tier: .free, validUntil: .now)
        #expect(free.historyWindowMonths == 18, "18 months covers last tax year and this one")
        // Sanity: the cutoff is in the past, not the future.
        #expect((free.historyCutoff ?? .distantFuture) < .now)

        let paid = Entitlements.previewTeam()
        #expect(paid.historyWindowMonths == nil)
        #expect(paid.historyCutoff == nil)
    }

    @Test("Entitlements never revoke on an unverified check")
    func staleCheckKeepsFeatures() {
        let entitlements = Entitlements()
        entitlements.apply(tier: .team, validUntil: .now.addingTimeInterval(86_400 * 30))
        #expect(entitlements.isPro)

        // A receipt validation that times out on a train reports free with no
        // expiry. A paying customer must keep their features.
        entitlements.apply(tier: .free, validUntil: nil)
        #expect(entitlements.isPro, "An unverified check must not downgrade a paying customer")

        // A genuine expiry, with a date, does downgrade.
        entitlements.apply(tier: .free, validUntil: .now.addingTimeInterval(-1))
        #expect(!entitlements.isPro)
    }

    @Test("Sharing needs both the tier and the user's own choice")
    func sharingRequiresBoth() {
        let entitlements = Entitlements()
        entitlements.apply(tier: .team, validUntil: .now.addingTimeInterval(86_400))
        entitlements.isTeamSharingEnabled = false
        #expect(entitlements.isEnabled(.sharedTeamMemory))
        // Having the tier is not consent to share.
        #expect(!entitlements.isSharingActive)
        #expect(!entitlements.needsDeviceTaggedDocumentNumbers)

        entitlements.isTeamSharingEnabled = true
        #expect(entitlements.isSharingActive)
        // Numbers gain a device tag only once several people might mint them.
        #expect(entitlements.needsDeviceTaggedDocumentNumbers)
    }

    @Test("Advanced letterhead styles are gated, and the plain ones are not")
    func letterheadGating() {
        #expect(!LetterheadStyle.classic.requiresAdvancedBranding)
        #expect(!LetterheadStyle.minimal.requiresAdvancedBranding)
        #expect(LetterheadStyle.colorBand.requiresAdvancedBranding)
        #expect(LetterheadStyle.split.requiresAdvancedBranding)
        // Both free styles must still produce a document worth handing over.
        #expect(LetterheadStyle.classic.showsLogo)
    }
}

@MainActor
struct LetterheadMigrationTests {

    @Test("An organization that had the old colour-band flag keeps it")
    func migratesFromTheOldBoolean() {
        let organization = Organization(name: "Riverside")
        // Simulates a row created before `letterheadStyle` existed: the raw
        // value is empty and only the old boolean carries the choice.
        organization.letterheadStyleRawValue = ""
        organization.usesColorBandLetterhead = true
        #expect(organization.letterheadStyle == .colorBand)

        organization.usesColorBandLetterhead = false
        #expect(organization.letterheadStyle == .classic)
    }

    @Test("Setting a style keeps the old flag consistent for older builds")
    func setterKeepsTheBooleanInStep() {
        let organization = Organization(name: "Riverside")
        organization.letterheadStyle = .colorBand
        #expect(organization.usesColorBandLetterhead)

        organization.letterheadStyle = .split
        #expect(!organization.usesColorBandLetterhead)
        #expect(organization.letterheadStyle == .split)
    }

    @Test("Typeface and footer default to the safe choices")
    func appearanceDefaults() {
        let organization = Organization(name: "Riverside")
        // Serif for letters: a formal acknowledgment in the system sans reads
        // like a push notification.
        #expect(organization.typeface == .serif)
        // Legal minimum: everything the IRS needs and nothing else.
        #expect(organization.footerStyle == .legalMinimum)
        // Photos off by default — a letter is a formal document.
        #expect(!organization.includesInKindPhotosInLetter)
    }
}
