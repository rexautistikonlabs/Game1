//
//  Gift.swift
//  FieldForge
//
//  A contribution: cash, card, cheque, or a pallet of canned peaches. This is
//  the record the document engine reads from, so its fields are shaped by what
//  a defensible receipt and a defensible IRS acknowledgment each need.
//

import Foundation
import SwiftData

@Model
final class Gift {

    var id: UUID = UUID()

    /// The date the organization took possession. For a card payment this is
    /// the authorization time; for a mailed cheque, the postmark rule may put
    /// it in the prior year, which is why this is editable and not derived.
    var receivedAt: Date = Date.now

    // MARK: Amount

    /// Minor units — cents. Zero for an in-kind gift that has no stated value,
    /// which is the recommended handling. See `Money` for why this is an Int.
    var amountMinorUnits: Int = 0
    var currencyCode: String = "USD"

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var methodRawValue: String = GiftMethod.cash.rawValue
    var method: GiftMethod {
        get { GiftMethod(rawValue: methodRawValue) ?? .cash }
        set { methodRawValue = newValue.rawValue }
    }

    /// Attribution — "Winter Coat Drive", "General Fund". Prints on both
    /// documents and is what a finance director will ask about first.
    var fundName: String = ""

    /// Cheque number, or the last four of a card. Never a full card number:
    /// this app is not in scope for PCI and must never be.
    var referenceNumber: String = ""

    // MARK: Electronic payment details

    /// Processor transaction identifier, when a payment cleared through one.
    /// Written by `PaymentCoordinator`, not by hand.
    var transactionIdentifier: String = ""

    /// "Visa 4242", "Mastercard 5100" — what PassKit hands back. Enough for a
    /// donor to recognise the charge on a statement; nothing more.
    var paymentInstrumentDescription: String = ""

    /// Name from the payment network, when supplied. Used to prefill a contact
    /// so a tap-to-pay donor does not have to spell their name.
    var payerNameFromNetwork: String = ""

    /// `true` once the money is actually settled or authorized. A queued or
    /// failed payment must never produce a tax acknowledgment, and the document
    /// step enforces that.
    var isPaymentConfirmed: Bool = false

    // MARK: In-kind

    /// Required for an in-kind gift: a specific description of the property.
    /// "42 twin-size blankets, new in packaging" — not "goods".
    var inKindDescription: String = ""

    /// The value the *donor* stated, if any. Labelled as the donor's own
    /// estimate everywhere it appears, and omitted from the letter entirely
    /// unless the organization has opted in. The charity valuing donated
    /// property on its own acknowledgment is the classic mistake here.
    var donorEstimatedValueMinorUnits: Int = 0

    /// Count of items, when countable. Prints in the description table.
    var inKindQuantity: Int = 0

    // MARK: Quid pro quo (goods or services given in return)

    /// True when the donor received something — a gala seat, a tote bag, an ad
    /// in the programme. Triggers the quid pro quo paragraph, which is
    /// required by the IRS when a payment over $75 is partly a purchase.
    var providedGoodsOrServices: Bool = false
    var goodsOrServicesDescription: String = ""
    var goodsOrServicesValueMinorUnits: Int = 0

    // MARK: Notes and bookkeeping

    var notes: String = ""
    var isAnonymousDonor: Bool = false

    /// Set when a gift is voided (a bounced cheque, a mistaken entry). The
    /// record is kept and excluded from totals rather than deleted, because a
    /// receipt was already handed over and the history should show that.
    var voidedAt: Date?
    var voidReason: String = ""

    var isSharedWithTeam: Bool = false
    var recordedByDisplayName: String = ""

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    // MARK: Relationships

    /// Inverses for these two are declared on `Contact.gifts` and
    /// `Organization.gifts`.
    var contact: Contact?
    var organization: Organization?

    /// Set when the gift came out of a door-to-door interaction.
    var visit: Visit?

    @Relationship(deleteRule: .cascade, inverse: \GeneratedDocument.gift)
    var documents: [GeneratedDocument]? = []

    @Relationship(deleteRule: .cascade, inverse: \Attachment.gift)
    var attachments: [Attachment]? = []

    init(
        amount: Money = .zero,
        method: GiftMethod = .cash,
        receivedAt: Date = .now
    ) {
        self.amountMinorUnits = amount.minorUnits
        self.currencyCode = amount.currencyCode
        self.methodRawValue = method.rawValue
        self.receivedAt = receivedAt
    }

    // MARK: Derived

    var amount: Money {
        get { Money(minorUnits: amountMinorUnits, currencyCode: currencyCode) }
        set {
            amountMinorUnits = newValue.minorUnits
            currencyCode = newValue.currencyCode
        }
    }

    var donorEstimatedValue: Money {
        get { Money(minorUnits: donorEstimatedValueMinorUnits, currencyCode: currencyCode) }
        set { donorEstimatedValueMinorUnits = newValue.minorUnits }
    }

    var goodsOrServicesValue: Money {
        get { Money(minorUnits: goodsOrServicesValueMinorUnits, currencyCode: currencyCode) }
        set { goodsOrServicesValueMinorUnits = newValue.minorUnits }
    }

    var isVoided: Bool { voidedAt != nil }

    var isInKind: Bool { method.isInKind }

    /// Pledges and voided gifts are promises and mistakes respectively.
    /// Neither belongs in a lifetime giving total.
    var countsTowardGiving: Bool {
        !isVoided && method != .pledge
    }

    /// The deductible portion after subtracting anything the donor received.
    /// Never negative — a donor who paid $50 for a $60 dinner deducts nothing,
    /// they do not deduct minus ten dollars.
    var deductibleAmount: Money {
        guard providedGoodsOrServices else { return amount }
        let net = amountMinorUnits - goodsOrServicesValueMinorUnits
        return Money(minorUnits: max(0, net), currencyCode: currencyCode)
    }

    /// The IRS requires a written acknowledgment for any single contribution of
    /// $250 or more if the donor intends to deduct it. Below that a receipt is
    /// courteous; at or above it, it is the donor's proof.
    var requiresWrittenAcknowledgment: Bool {
        !isInKind && amountMinorUnits >= 25_000
    }

    /// Quid pro quo disclosure is required above $75.
    var requiresQuidProQuoDisclosure: Bool {
        providedGoodsOrServices && amountMinorUnits > 7_500
    }

    /// Noncash gifts over $5,000 generally need a qualified appraisal and
    /// Section B of Form 8283, which the charity has to sign. Worth telling the
    /// staffer at the door rather than in April.
    var mayNeedForm8283: Bool {
        isInKind && donorEstimatedValueMinorUnits > 500_000
    }

    /// Anything that must be true before a tax document may be issued. The
    /// document step shows these instead of quietly rendering something wrong.
    func blockersForDocument(kind: DocumentKind) -> [String] {
        var blockers: [String] = []
        if isVoided {
            blockers.append("This gift is voided.")
        }
        if method == .pledge && kind == .letter {
            blockers.append("A pledge is not yet a contribution — issue a pledge confirmation instead of a tax acknowledgment.")
        }
        if method.requiresNetwork && !isPaymentConfirmed {
            blockers.append("The payment has not cleared yet.")
        }
        if isInKind {
            if inKindDescription.trimmedOrNil == nil {
                blockers.append("Describe the donated items — the description is what makes the acknowledgment valid.")
            }
        } else if amountMinorUnits <= 0 {
            blockers.append("Enter an amount.")
        }
        if providedGoodsOrServices && goodsOrServicesDescription.trimmedOrNil == nil {
            blockers.append("Describe what the donor received in return.")
        }
        return blockers
    }

    /// Advisory notes — worth surfacing, never blocking.
    var advisories: [String] {
        var notes: [String] = []
        if mayNeedForm8283 {
            notes.append("Noncash gifts over $5,000 usually need Form 8283 Section B and a qualified appraisal.")
        }
        if requiresQuidProQuoDisclosure {
            notes.append("Over $75 with goods or services provided — the letter will state the deductible portion.")
        }
        if isInKind && donorEstimatedValueMinorUnits > 0 {
            notes.append("The value shown will be labelled as the donor's own estimate.")
        }
        return notes
    }

    /// One line for lists: "$250.00 · Apple Pay" or "In-kind · 42 blankets".
    var summaryLine: String {
        if isInKind {
            let description = inKindDescription.trimmedOrNil ?? "In-kind gift"
            return "In-kind · \(description)"
        }
        return "\(amount.formatted) · \(method.label)"
    }

    func touch() { updatedAt = .now }

    func void(reason: String) {
        voidedAt = .now
        voidReason = reason
        touch()
        contact?.recomputeRollups()
    }
}
