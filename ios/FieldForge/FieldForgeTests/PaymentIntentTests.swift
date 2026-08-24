//
//  PaymentIntentTests.swift
//  FieldForgeTests
//
//  Stripe Apple Pay wiring: secret keys never stick, real Apple Pay needs a
//  backend URL plus a pk_ key, and a tax letter waits for PaymentIntent
//  succeeded.
//

import Foundation
import SwiftData
import Testing
@testable import FieldForge

struct StripeSettingsTests {

    @Test("Publishable keys are pk_, secret keys are rejected")
    func publishableKeyShape() {
        #expect(StripePaymentSettings.isPublishableKey("pk_test_abc12345"))
        #expect(StripePaymentSettings.isPublishableKey("pk_live_abc12345"))
        #expect(!StripePaymentSettings.isPublishableKey("sk_test_abc12345"))
        #expect(!StripePaymentSettings.isPublishableKey("sk_live_abc12345"))
        #expect(!StripePaymentSettings.isPublishableKey(""))
        #expect(!StripePaymentSettings.isPublishableKey("pk_"))
    }

    @Test("Pasting a secret key is discarded and never stored")
    @MainActor
    func secretKeyIsNotPersisted() {
        let suiteName = "fieldforge.tests.stripe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = StripePaymentSettings(defaults: defaults)

        settings.setPublishableKey("sk_test_this_must_never_land_on_ios")
        #expect(settings.rejectedSecretKey)
        #expect(settings.publishableKey.isEmpty)
        #expect(defaults.string(forKey: "fieldforge.stripe.publishableKey") == nil)

        settings.setPublishableKey("pk_test_validkeyvalue")
        #expect(!settings.rejectedSecretKey)
        #expect(settings.publishableKey.hasPrefix("pk_test_"))
        #expect(defaults.string(forKey: "fieldforge.stripe.publishableKey") == "pk_test_validkeyvalue")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Backend URL can be the Function App origin or the full path")
    func resolveCreateIntentURL() {
        let fromOrigin = StripePaymentSettings.resolveCreateIntentURL(
            "https://fieldforge-pay.azurewebsites.net"
        )
        #expect(fromOrigin?.absoluteString == "https://fieldforge-pay.azurewebsites.net/api/create-payment-intent")

        let full = "https://fieldforge-pay.azurewebsites.net/api/create-payment-intent"
        #expect(StripePaymentSettings.resolveCreateIntentURL(full)?.absoluteString == full)

        #expect(StripePaymentSettings.resolveCreateIntentURL("") == nil)
        #expect(StripePaymentSettings.resolveCreateIntentURL("not a url") == nil)
    }

    @Test("Live Apple Pay requires a pk_ key; empty URL uses the platform origin")
    @MainActor
    func configuredRequiresBoth() {
        let suiteName = "fieldforge.tests.stripe.cfg.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = StripePaymentSettings(defaults: defaults)
        #expect(!settings.isConfigured)

        settings.backendURLString = "https://fieldforge-pay.azurewebsites.net"
        #expect(!settings.isConfigured)

        settings.setPublishableKey("pk_test_abcdefgh")
        #expect(settings.isConfigured)

        // Clearing the override must not break the platform origin.
        settings.backendURLString = ""
        #expect(settings.isConfigured)
        #expect(
            settings.createPaymentIntentURL?.absoluteString
                == "\(StripePaymentSettings.platformBackendOrigin)/api/create-payment-intent"
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Sibling Azure functions resolve off a stored create-payment-intent URL")
    func siblingAPIURLs() {
        let full = "https://fieldforge-pay.azurewebsites.net/api/create-payment-intent"
        #expect(
            StripePaymentSettings.resolveAPIURL(full, path: "/api/public-config")?.absoluteString
                == "https://fieldforge-pay.azurewebsites.net/api/public-config"
        )
        #expect(
            StripePaymentSettings.resolveAPIURL(
                "https://fieldforge-pay.azurewebsites.net",
                path: "/api/connect/oauth/start"
            )?.absoluteString
                == "https://fieldforge-pay.azurewebsites.net/api/connect/oauth/start"
        )
        #expect(
            StripePaymentSettings.resolveAPIURL(full, path: "/api/create-payment-link")?.absoluteString
                == "https://fieldforge-pay.azurewebsites.net/api/create-payment-link"
        )
        #expect(
            StripePaymentSettings.resolveAPIURL(full, path: "/api/payment-status")?.absoluteString
                == "https://fieldforge-pay.azurewebsites.net/api/payment-status"
        )
        #expect(
            StripePaymentSettings.resolveAPIURL(full, path: "/api/connection-token")?.absoluteString
                == "https://fieldforge-pay.azurewebsites.net/api/connection-token"
        )
    }

    @Test("Connected Stripe accounts are acct_ ids, never keys")
    func connectAccountShape() {
        #expect(StripeConnectAccount.isValidIdentifier("acct_123ABCdef"))
        #expect(!StripeConnectAccount.isValidIdentifier("sk_test_abc"))
        #expect(!StripeConnectAccount.isValidIdentifier("pk_test_abc"))
        #expect(!StripeConnectAccount.isValidIdentifier(""))
        #expect(!StripeConnectAccount.isValidIdentifier("not-an-account"))
    }

    @Test("OAuth callback stores acct_ and ignores junk")
    func oauthCallbackParsesAccount() {
        let good = URL(string: "fieldforge://stripe-connect?account=acct_99XYZ&state=abc")!
        if case .connected(let id) = StripeConnectOAuth.parseCallback(good, expectedState: "abc") {
            #expect(id == "acct_99XYZ")
        } else {
            Issue.record("expected a connected account")
        }

        let denied = URL(string: "fieldforge://stripe-connect?error=access_denied")!
        #expect(StripeConnectOAuth.parseCallback(denied, expectedState: nil) == .cancelled)

        let secret = URL(string: "fieldforge://stripe-connect?account=sk_test_nope")!
        if case .failed = StripeConnectOAuth.parseCallback(secret, expectedState: nil) {
            // ok
        } else {
            Issue.record("a secret key must never look like a connected account")
        }
    }

    @Test("Tap to Pay missing entitlement uses the registered-iPhone sentence")
    func tapToPayEntitlementCopy() {
        #expect(PaymentUnavailableReason.tapToPayEntitlementMissing.shortLabel == "Not enabled")
        #expect(
            PaymentUnavailableReason.tapToPayEntitlementMissing.explanation
                == TapToPayCollectUI.deviceOrEntitlementMessage
        )
        #expect(TapToPayCollectUI.deviceOrEntitlementMessage.contains("registered iPhone"))
        #expect(!TapToPayEntitlement.canAcceptContactlessOnThisBuild || TapToPayEntitlement.isPresentInSignature)
    }

    @Test("USD amount bounds match the Azure function")
    func amountBounds() {
        #expect(StripeAmountLimits.minimumCents == 50)
        #expect(StripeAmountLimits.maximumCents == 10_000_000)
        #expect(StripeAmountLimits.rejectionMessage(forCents: 49) != nil)
        #expect(StripeAmountLimits.rejectionMessage(forCents: 50) == nil)
        #expect(StripeAmountLimits.rejectionMessage(forCents: 10_000_000) == nil)
        #expect(StripeAmountLimits.rejectionMessage(forCents: 10_000_001) != nil)
    }

    @Test("Client secret parsing keeps the PaymentIntent id")
    func paymentIntentIDFromSecret() {
        #expect(
            StripePaymentIntentGateway.paymentIntentID(from: "pi_abc123_secret_xyz") == "pi_abc123"
        )
        #expect(StripePaymentIntentGateway.paymentIntentID(from: "not-a-secret") == nil)
        #expect(StripePaymentIntentGateway.paymentIntentID(from: "tok_abc_secret_xyz") == nil)
    }

    @Test("Merchant ID is the Apple Pay identifier already on this app")
    func merchantIdentifier() {
        #expect(
            StripePaymentSettings.defaultMerchantIdentifier
                == "merchant.org.rexautistikonlabs.fieldforge"
        )
        #expect(
            PaymentGatewayRegistry.defaultMerchantIdentifier
                == "merchant.org.rexautistikonlabs.fieldforge"
        )
    }
}

@MainActor
struct TaxLetterPaymentIntentTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: Persistence.inMemoryConfiguration
        )
    }

    private func seededGift(
        in context: ModelContext,
        method: GiftMethod = .applePay,
        confirmed: Bool,
        intentStatus: String
    ) throws -> (Organization, Contact, Gift) {
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107", city: "Rockford", state: "IL")
        organization.addressLine1 = "412 South Water Street"
        organization.signatoryName = "Maritza Ocampo"
        context.insert(organization)

        let contact = Contact(name: "Delgado Hardware")
        contact.organization = organization
        context.insert(contact)

        let gift = Gift(amount: Money(dollars: 250), method: method)
        gift.organization = organization
        gift.contact = contact
        gift.isPaymentConfirmed = confirmed
        gift.paymentIntentStatus = intentStatus
        context.insert(gift)
        return (organization, contact, gift)
    }

    @Test("A simulated Apple Pay cannot produce a tax letter")
    func simulatedPaymentCannotIssueLetter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (organization, contact, gift) = try seededGift(
            in: context,
            confirmed: true,
            intentStatus: "simulated"
        )

        let readiness = DocumentEngine.readiness(kind: .letter, gift: gift, organization: organization)
        #expect(!readiness.canIssue)
        #expect(readiness.blockers.contains { $0.lowercased().contains("succeeded") })

        #expect(throws: (any Error).self) {
            try DocumentEngine.issue(
                kind: .letter,
                gift: gift,
                contact: contact,
                organization: organization,
                signature: nil,
                includeDeviceTagInNumber: false,
                context: context
            )
        }
    }

    @Test("A tax letter issues only after PaymentIntent succeeded")
    func letterAfterSucceededIntent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (organization, contact, gift) = try seededGift(
            in: context,
            confirmed: true,
            intentStatus: "succeeded"
        )

        let readiness = DocumentEngine.readiness(kind: .letter, gift: gift, organization: organization)
        #expect(readiness.canIssue)

        let document = try DocumentEngine.issue(
            kind: .letter,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: nil,
            includeDeviceTagInNumber: false,
            context: context
        )
        #expect(document.kind == .letter)
        #expect(document.pdfData != nil)
    }

    @Test("An unconfirmed Apple Pay still cannot produce a receipt")
    func unconfirmedReceiptStillBlocked() {
        let gift = Gift(amount: Money(dollars: 250), method: .applePay)
        gift.isPaymentConfirmed = false
        gift.paymentIntentStatus = ""
        #expect(gift.blockersForDocument(kind: .receipt).contains { $0.lowercased().contains("cleared") })
        #expect(gift.blockersForDocument(kind: .letter).contains { $0.lowercased().contains("succeeded") })
    }

    @Test("Cash letters do not wait on a PaymentIntent")
    func cashLetterUnaffected() {
        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.isPaymentConfirmed = true
        #expect(gift.blockersForDocument(kind: .letter).isEmpty)
    }

    @Test("Tap to Pay letters also wait for PaymentIntent succeeded")
    func tapToPayLetterWaitsForSucceeded() {
        let gift = Gift(amount: Money(dollars: 250), method: .tapToPay)
        gift.isPaymentConfirmed = true
        gift.paymentIntentStatus = "processing"
        #expect(gift.blockersForDocument(kind: .letter).contains { $0.lowercased().contains("succeeded") })

        gift.paymentIntentStatus = "succeeded"
        #expect(gift.blockersForDocument(kind: .letter).isEmpty)
    }

    @Test("Document stays blocked until Tap to Pay, text, or email pay link succeeded")
    func cardLikeMethodsBlockDocumentUntilSucceeded() {
        var tap = DocumentDraft()
        tap.method = .tapToPay
        tap.amountText = "25.00"
        #expect(tap.hasWhat)
        #expect(!tap.canAdvanceToDocument)
        tap.isPaymentConfirmed = true
        tap.paymentIntentStatus = "processing"
        #expect(!tap.canAdvanceToDocument)
        tap.paymentIntentStatus = "succeeded"
        #expect(tap.canAdvanceToDocument)

        var link = DocumentDraft()
        link.method = .textPayLink
        link.amountText = "25.00"
        #expect(!link.canAdvanceToDocument)
        link.isPaymentConfirmed = true
        link.paymentIntentStatus = "succeeded"
        #expect(link.canAdvanceToDocument)

        var email = DocumentDraft()
        email.method = .emailPayLink
        email.amountText = "25.00"
        #expect(!email.canAdvanceToDocument)

        var cash = DocumentDraft()
        cash.method = .cash
        cash.amountText = "25.00"
        #expect(cash.canAdvanceToDocument)

        var check = DocumentDraft()
        check.method = .check
        check.amountText = "25.00"
        #expect(check.canAdvanceToDocument)

        var inKind = DocumentDraft()
        inKind.method = .inKind
        inKind.inKindDescription = "blankets"
        #expect(inKind.canAdvanceToDocument)

        var pledge = DocumentDraft()
        pledge.method = .pledge
        pledge.amountText = "25.00"
        #expect(pledge.canAdvanceToDocument)

        var recorded = DocumentDraft()
        recorded.method = .cardManual
        recorded.amountText = "25.00"
        #expect(recorded.canAdvanceToDocument)
    }

    @Test("A texted pay link cannot produce a letter until Stripe succeeded")
    func textPayLinkLetterWaitsForSucceeded() {
        let gift = Gift(amount: Money(dollars: 250), method: .textPayLink)
        gift.isPaymentConfirmed = false
        gift.paymentIntentStatus = ""
        #expect(gift.blockersForDocument(kind: .receipt).contains { $0.lowercased().contains("cleared") })
        #expect(gift.blockersForDocument(kind: .letter).contains { $0.lowercased().contains("succeeded") })

        gift.isPaymentConfirmed = true
        gift.paymentIntentStatus = "open"
        #expect(gift.blockersForDocument(kind: .letter).contains { $0.lowercased().contains("succeeded") })

        gift.paymentIntentStatus = "succeeded"
        #expect(gift.blockersForDocument(kind: .letter).isEmpty)
    }
}

/// DidFinish seam: after the Wallet sheet dismisses, never before.
struct ApplePaySheetSeamTests {

    @Test("Closing the Wallet sheet without paying is a cancel, not a paid gift")
    func cancelLeavesGiftUnpaid() {
        #expect(ApplePaySheetSeam.outcomeAfterDismiss(nil) == .cancelled)
        #expect(!ApplePaySheetSeam.shouldMarkPaid(.cancelled))
    }

    @Test("A gift is marked paid only when PaymentIntent succeeded")
    func succeededMarksPaid() {
        let succeeded = PaymentReceipt(
            amount: Money(dollars: 1),
            isSettled: true,
            paymentIntentStatus: "succeeded"
        )
        let captured = PaymentOutcome.captured(succeeded)
        #expect(ApplePaySheetSeam.outcomeAfterDismiss(captured) == captured)
        #expect(ApplePaySheetSeam.shouldMarkPaid(captured))

        let processing = PaymentReceipt(
            amount: Money(dollars: 1),
            isSettled: true,
            paymentIntentStatus: "processing"
        )
        #expect(!ApplePaySheetSeam.shouldMarkPaid(.captured(processing)))

        let simulated = PaymentReceipt(
            amount: Money(dollars: 1),
            isSettled: true,
            paymentIntentStatus: "simulated"
        )
        #expect(!ApplePaySheetSeam.shouldMarkPaid(.captured(simulated)))
    }

    @Test("A failed charge after DidFinish does not mark paid")
    func failureDoesNotMarkPaid() {
        let failed = PaymentOutcome.failed(PaymentFailure(
            message: "The card was declined.",
            isRetryable: true,
            diagnosticCode: "declined"
        ))
        #expect(ApplePaySheetSeam.outcomeAfterDismiss(failed) == failed)
        #expect(!ApplePaySheetSeam.shouldMarkPaid(failed))
    }
}

struct TextPayLinkTests {

    @Test("SMS body is org, amount, and URL — never a key")
    func smsBodyShape() {
        let url = URL(string: "https://checkout.stripe.com/c/pay/cs_test_abc")!
        let body = PayLinkMessage.body(
            organizationName: "Riverside Food Collective",
            amount: Money(dollars: 25),
            url: url
        )
        #expect(body.hasPrefix("Riverside Food Collective — tap to give"))
        #expect(body.contains("25"))
        #expect(body.contains(url.absoluteString))
        #expect(!body.contains("sk_"))
        #expect(PayLinkMessage.sessionID(from: url) == "cs_test_abc")
    }

    @Test("A missing phone is unusable; digits-only sms: URLs encode the body")
    func phoneAndSMSURL() {
        #expect(!PayLinkMessage.isUsablePhone(""))
        #expect(!PayLinkMessage.isUsablePhone("123"))
        #expect(PayLinkMessage.isUsablePhone("(904) 555-0100"))
        let url = PayLinkMessage.smsURL(
            phone: "(904) 555-0100",
            body: "Riverside — tap to give $25.00: https://example.test/pay"
        )
        #expect(url?.absoluteString.hasPrefix("sms:9045550100") == true)
        #expect(url?.absoluteString.contains("body=") == true)
        #expect(url?.absoluteString.contains("sk_") == false)
    }

    @Test("Email subject and body are org, amount, and URL — never a key")
    func emailCopyShape() {
        let url = URL(string: "https://checkout.stripe.com/c/pay/cs_test_abc")!
        let amount = Money(dollars: 25)
        let subject = PayLinkMessage.emailSubject(
            organizationName: "Riverside Food Collective",
            amount: amount
        )
        let body = PayLinkMessage.emailBody(
            organizationName: "Riverside Food Collective",
            amount: amount,
            url: url
        )
        #expect(subject == "Riverside Food Collective — gift of \(amount.formatted)")
        #expect(body.contains("gift of"))
        #expect(body.contains(amount.formatted))
        #expect(body.contains(url.absoluteString))
        #expect(!subject.contains("sk_"))
        #expect(!body.contains("sk_"))
    }

    @Test("A missing email is unusable; mailto: encodes subject and body")
    func emailAndMailtoURL() {
        #expect(!PayLinkMessage.isUsableEmail(""))
        #expect(!PayLinkMessage.isUsableEmail("not-an-email"))
        #expect(!PayLinkMessage.isUsableEmail("ana@"))
        #expect(PayLinkMessage.isUsableEmail("ana@example.com"))
        let url = PayLinkMessage.mailtoURL(
            email: "ana@example.com",
            subject: "Riverside Food Collective — gift of $25.00",
            body: "Pay here: https://checkout.stripe.com/c/pay/cs_test_abc"
        )
        #expect(url?.scheme == "mailto")
        #expect(url?.path == "ana@example.com")
        #expect(url?.absoluteString.contains("subject=") == true)
        #expect(url?.absoluteString.contains("body=") == true)
        #expect(url?.absoluteString.contains("sk_") == false)
    }

    @Test("Sending a second pay link keeps the latest session id and leaves the gift unpaid")
    @MainActor
    func latestSessionWins() {
        var draft = DocumentDraft()
        draft.method = .textPayLink
        draft.amountText = "25.00"
        let coordinator = PaymentCoordinator(reachability: Reachability())
        let first = PayLink(
            url: URL(string: "https://checkout.stripe.com/c/pay/cs_first")!,
            sessionID: "cs_first"
        )
        coordinator.applyPayLink(first, to: &draft)
        #expect(draft.checkoutSessionID == "cs_first")
        #expect(!draft.isPaymentConfirmed)

        let second = PayLink(
            url: URL(string: "https://checkout.stripe.com/c/pay/cs_second")!,
            sessionID: "cs_second"
        )
        coordinator.applyPayLink(second, to: &draft)
        #expect(draft.checkoutSessionID == "cs_second")
        #expect(draft.paymentLinkURL == second.url.absoluteString)
        #expect(!draft.isPaymentConfirmed)
        #expect(draft.paymentIntentStatus != "succeeded")

        let gift = Gift(amount: Money(dollars: 25), method: .textPayLink)
        gift.checkoutSessionID = "cs_first"
        let paidOnLatest = PayLinkStatus(
            paid: true,
            status: "succeeded",
            sessionID: "cs_second",
            paymentIntentID: "pi_second",
            paymentIntentStatus: "succeeded",
            amountMinorUnits: 2500,
            url: nil
        )
        coordinator.apply(paidOnLatest, to: gift)
        #expect(gift.checkoutSessionID == "cs_second")
        #expect(gift.isPaymentConfirmed)
        #expect(gift.paymentIntentStatus == "succeeded")
    }

    @Test("Staff Wallet is not a capture control")
    func staffWalletLabel() {
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
        #expect(PaymentUnavailableReason.tapToPayEntitlementMissing.shortLabel == "Not enabled")
    }

    @Test("Collect times out after 60 seconds")
    func collectTimeoutIsSixtySeconds() {
        #expect(TapToPayCollectUI.timeoutSeconds == 60)
    }

    @Test("Tap to Pay ships off, so nothing in capture can reach Stripe Terminal")
    @MainActor
    func tapToPayIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "fieldforge.tests.tapToPayDefault")!
        defaults.removePersistentDomain(forName: "fieldforge.tests.tapToPayDefault")
        let settings = StripePaymentSettings(defaults: defaults)
        #expect(!settings.isTapToPayEnabled)

        settings.isTapToPayEnabled = true
        let reopened = StripePaymentSettings(defaults: defaults)
        #expect(reopened.isTapToPayEnabled)
        defaults.removePersistentDomain(forName: "fieldforge.tests.tapToPayDefault")
    }

    @Test("The off state explains itself instead of failing on tap")
    func tapToPayOffStateExplainsItself() {
        #expect(PaymentUnavailableReason.tapToPayTurnedOff.shortLabel == "Off")
        #expect(PaymentUnavailableReason.tapToPayTurnedOff.explanation
            == TapToPayCollectUI.turnedOffMessage)
        #expect(TapToPayCollectUI.turnedOffMessage.contains("pay link"))
    }

    @Test("Keyboard settles before Collect starts Terminal")
    func keyboardResignsBeforeCollect() {
        #expect(TapToPayKeyboard.resignSettlingMilliseconds == 400)
    }

    @Test("App.init launch recovery is recoverIfDirty")
    func appInitClearsCollectInFlight() {
        // FieldForgeApp.init and BootSession.start both call this before paint.
        TapToPaySession.markStarted()
        #expect(TapToPaySession.collectInFlight)
        #expect(TapToPaySession.recoverIfDirty())
        #expect(!TapToPaySession.collectInFlight)
    }

    @Test("Missing Terminal location uses the Dashboard sentence")
    func missingTerminalLocationCopy() {
        #expect(
            TapToPayCollectUI.missingLocationMessage
                == "Create a Terminal location in Stripe Dashboard and set STRIPE_TERMINAL_LOCATION_ID on Azure."
        )
        #expect(TapToPayCollectError.missingLocation.localizedDescription == TapToPayCollectUI.missingLocationMessage)
        #expect(TapToPayCollectUI.missingLocationCode == "tap-to-pay-location")
        #expect(!TapToPayCollectUI.missingLocationMessage.contains("tml_"))
        #expect(!TapToPayCollectUI.missingLocationMessage.contains("sk_"))
    }

    @Test("Staff capture never presents Wallet; pay links stay")
    func staffWalletOffPayLinksStay() {
        #expect(!PaymentCoordinator.presentsStaffApplePayInCapture)
        #expect(GiftMethod.textPayLink.isPayLink)
        #expect(GiftMethod.emailPayLink.isPayLink)
        #expect(GiftMethod.tapToPay.requiresClearedPaymentBeforeDocument)
        #expect(GiftMethod.textPayLink.requiresClearedPaymentBeforeDocument)
        #expect(!GiftMethod.cash.requiresClearedPaymentBeforeDocument)
        #expect(!GiftMethod.check.requiresClearedPaymentBeforeDocument)
        #expect(!GiftMethod.inKind.requiresClearedPaymentBeforeDocument)
    }

    @Test("A dirty collectInFlight flag discards the draft at launch")
    func dirtySessionIsDiscardedAtLaunch() {
        defer {
            TapToPaySession.markFinished()
            DraftStore.clear()
        }
        TapToPaySession.markStarted()
        var draft = DocumentDraft()
        draft.newContact.name = "Delgado Hardware"
        draft.amountText = "25.00"
        draft.method = .tapToPay
        DraftStore.save(draft)
        #expect(TapToPaySession.collectInFlight)
        #expect(DraftStore.hasDraft)

        let dirty = TapToPaySession.recoverIfDirty()
        #expect(dirty)
        #expect(!TapToPaySession.collectInFlight)
        #expect(!DraftStore.hasDraft)

        #expect(!TapToPaySession.recoverIfDirty())
        #expect(!TapToPaySession.collectInFlight)
    }

    @Test("Launch always clears collectInFlight so Today can paint")
    func launchClearsCollectInFlightEvenWhenClean() {
        TapToPaySession.markFinished()
        #expect(!TapToPaySession.collectInFlight)
        #expect(!TapToPaySession.recoverIfDirty())
        #expect(!TapToPaySession.collectInFlight)

        TapToPaySession.markStarted()
        #expect(TapToPaySession.collectInFlight)
        _ = TapToPaySession.recoverIfDirty()
        #expect(!TapToPaySession.collectInFlight)
    }

    @Test("Tap to Pay collect refuses before it can reach Stripe Terminal")
    @MainActor
    func tapToPayCollectRefusesWithoutDevice() async {
        let coordinator = PaymentCoordinator(reachability: Reachability(startImmediately: false))
        let outcome = await coordinator.collect(
            method: .tapToPay,
            request: PaymentRequest(
                amount: Money(dollars: 25),
                summaryLabel: "Donation",
                merchantName: "Riverside",
                fundName: "General"
            )
        )
        guard case .failed(let failure) = outcome else {
            Issue.record("Tap to Pay off / Simulator / missing grant must not start Terminal collect")
            return
        }
        // Off is the shipped default and is checked first, before anything can
        // construct the Stripe Terminal backend. With it on, Simulator and a
        // build without Apple's grant still refuse.
        if !StripePaymentSettings.shared.isTapToPayEnabled {
            #expect(failure.diagnosticCode == TapToPayCollectUI.turnedOffCode)
        } else if TapToPayProvider.shouldRefuseCollectOnThisRuntime {
            #expect(failure.diagnosticCode == TapToPayCollectUI.deviceOrEntitlementCode)
            #expect(failure.message == TapToPayCollectUI.deviceOrEntitlementMessage)
        }
    }

    @Test("Applying a Tap to Pay receipt only marks received after succeeded")
    @MainActor
    func tapToPayApplyWaitsForSucceeded() {
        var draft = DocumentDraft()
        draft.method = .tapToPay
        draft.amountText = "25.00"
        let coordinator = PaymentCoordinator(reachability: Reachability(startImmediately: false))
        let processing = PaymentReceipt(
            amount: Money(dollars: 25),
            transactionIdentifier: "pi_processing",
            method: .tapToPay,
            isSettled: true,
            paymentIntentStatus: "processing"
        )
        coordinator.apply(processing, to: &draft)
        #expect(!draft.isPaymentConfirmed)
        #expect(!draft.canAdvanceToDocument)

        let succeeded = PaymentReceipt(
            amount: Money(dollars: 25),
            transactionIdentifier: "pi_ok",
            method: .tapToPay,
            isSettled: true,
            paymentIntentStatus: "succeeded"
        )
        coordinator.apply(succeeded, to: &draft)
        #expect(draft.isPaymentConfirmed)
        #expect(draft.paymentIntentStatus == "succeeded")
        #expect(draft.canAdvanceToDocument)
    }

    @Test("An open Checkout session does not mark the gift paid")
    @MainActor
    func openSessionLeavesGiftUnpaid() {
        var draft = DocumentDraft()
        draft.method = .textPayLink
        draft.amountText = "25.00"
        let open = PayLinkStatus(
            paid: false,
            status: "open",
            sessionID: "cs_test_1",
            paymentIntentID: "",
            paymentIntentStatus: "",
            amountMinorUnits: 2500,
            url: nil
        )
        PaymentCoordinator(reachability: Reachability()).apply(open, to: &draft)
        #expect(!draft.isPaymentConfirmed)
        #expect(draft.paymentIntentStatus != "succeeded")
    }

    @Test("Succeeded status marks paid and unlocks a letter")
    @MainActor
    func succeededMarksPaid() {
        var draft = DocumentDraft()
        draft.method = .textPayLink
        draft.amountText = "25.00"
        let paid = PayLinkStatus(
            paid: true,
            status: "succeeded",
            sessionID: "cs_test_1",
            paymentIntentID: "pi_test_1",
            paymentIntentStatus: "succeeded",
            amountMinorUnits: 2500,
            url: nil
        )
        PaymentCoordinator(reachability: Reachability()).apply(paid, to: &draft)
        #expect(draft.isPaymentConfirmed)
        #expect(draft.paymentIntentStatus == "succeeded")
        #expect(draft.confirmedTransactionIdentifier == "pi_test_1")
        #expect(draft.amount.minorUnits == 2500)
    }
}
