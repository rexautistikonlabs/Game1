//
//  DraftCommitter.swift
//  FieldForge
//
//  Turns a finished draft into real records, in one transaction.
//
//  This is the moment the whole app exists for, so it is written defensively:
//  either everything lands — contact, visit, gift, document, follow-up, warmth
//  roll-up, outbox entry — or nothing does and the draft survives untouched for
//  the staffer to retry. There is no half-committed state where a receipt exists
//  and the gift behind it does not.
//

import Foundation
import SwiftData
import UIKit

@MainActor
struct DraftCommitter {

    /// What was created, so the delivery step can act on it.
    struct Result {
        var contact: Contact
        var visit: Visit
        var gift: Gift?
        var document: GeneratedDocument?
        var followUp: FollowUp?
    }

    enum CommitError: LocalizedError {
        case noOrganization
        case nothingToSave
        case documentFailed(String)

        var errorDescription: String? {
            switch self {
            case .noOrganization:
                return "No organization is set up yet. Add one in Settings first."
            case .nothingToSave:
                return "There is nothing to save yet."
            case .documentFailed(let reason):
                return reason
            }
        }
    }

    let context: ModelContext
    let organization: Organization
    let staffDisplayName: String
    let entitlements: Entitlements

    /// Commits the draft.
    ///
    /// - Parameter issueDocument: `false` records the visit and gift without
    ///   producing a PDF — used when the staffer chose "just log the visit".
    func commit(
        draft: DocumentDraft,
        issueDocument: Bool,
        personalNote: String = ""
    ) throws -> Result {
        guard draft.hasWho else { throw CommitError.nothingToSave }

        // 1. Contact — found or created.
        let contact = try resolveContact(draft: draft)

        // 2. Visit — reuse the one a one-shot scan already committed, or make
        //    one. Always exactly one: even a declined door is worth a record,
        //    and a doorstep must never be counted twice.
        let visit: Visit
        if let existing = draft.committedVisitID.flatMap(findVisit) {
            updateVisit(existing, from: draft)
            visit = existing
        } else {
            let fresh = makeVisit(draft: draft, contact: contact)
            context.insert(fresh)
            visit = fresh
        }

        // 3. Gift — only when there is actually something given.
        var gift: Gift?
        if !draft.isVisitOnly {
            let newGift = makeGift(draft: draft, contact: contact, visit: visit)
            context.insert(newGift)
            visit.gift = newGift
            gift = newGift
        }

        // 4. Document — only on request, and only when there is a gift.
        var document: GeneratedDocument?
        if issueDocument, let gift {
            do {
                document = try DocumentEngine.issue(
                    kind: draft.documentKind,
                    gift: gift,
                    contact: contact,
                    organization: organization,
                    signature: signatureImage(for: draft),
                    personalNote: personalNote,
                    signatoryNameOverride: draft.signatoryNameOverride.trimmedOrNil,
                    signatoryTitleOverride: draft.signatoryTitleOverride.trimmedOrNil,
                    recipientEmail: draft.recipientEmail.trimmedOrNil,
                    issuedBy: staffDisplayName,
                    includeDeviceTagInNumber: entitlements.needsDeviceTaggedDocumentNumbers,
                    context: context
                )
            } catch {
                // Roll back everything this call inserted. A failed document
                // must not leave an orphan gift that inflates the totals.
                context.rollback()
                throw CommitError.documentFailed(error.localizedDescription)
            }
        }

        // 5. Follow-up.
        var followUp: FollowUp?
        if draft.wantsFollowUp {
            let reminder = FollowUp(
                kind: draft.followUpKind,
                dueAt: draft.followUpDate,
                note: draft.followUpNote.trimmedOrNil ?? draft.visitNotes
            )
            reminder.contact = contact
            reminder.isSharedWithTeam = entitlements.isSharingActive
            reminder.assignedToDisplayName = staffDisplayName
            context.insert(reminder)
            followUp = reminder
        }

        // 6. Apply the draft's relationship data to the contact, then roll up.
        applyRelationshipUpdates(draft: draft, to: contact)
        contact.recomputeRollups()

        // 7. Attach anything already saved (photos, in-kind item shots).
        attachExistingAttachments(draft: draft, contact: contact, visit: visit, gift: gift)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw CommitError.documentFailed("Could not save: \(error.localizedDescription)")
        }

        AppLog.app.info("Committed a draft: gift=\(gift != nil, privacy: .public) document=\(document != nil, privacy: .public)")
        return Result(contact: contact, visit: visit, gift: gift, document: document, followUp: followUp)
    }

    // MARK: Pieces

    private func resolveContact(draft: DocumentDraft) throws -> Contact {
        if let id = draft.existingContactID {
            var descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let found = try? context.fetch(descriptor).first {
                return found
            }
            // The contact was deleted between steps. Fall through and create a
            // new one from whatever the draft holds rather than failing.
            AppLog.app.warning("Draft referenced a contact that no longer exists")
        }

        let fields = draft.newContact
        let contact = Contact(
            name: fields.name.trimmedOrNil ?? fields.contactPersonName,
            kind: fields.kind,
            source: fields.source
        )
        contact.organization = organization
        contact.contactPersonName = fields.contactPersonName
        contact.contactPersonTitle = fields.contactPersonTitle
        contact.phone = fields.phone
        contact.email = fields.email
        contact.addressLine1 = fields.addressLine1
        contact.addressLine2 = fields.addressLine2
        contact.city = fields.city
        contact.state = fields.state
        contact.postalCode = fields.postalCode
        contact.latitude = draft.latitude
        contact.longitude = draft.longitude
        contact.createdByDisplayName = staffDisplayName
        contact.isSharedWithTeam = entitlements.isSharingActive
        context.insert(contact)
        return contact
    }

    private func makeVisit(draft: DocumentDraft, contact: Contact) -> Visit {
        let visit = Visit(
            occurredAt: draft.giftDate,
            outcome: draft.isVisitOnly ? nonGivingOutcome(draft) : draft.outcome,
            warmth: draft.warmth
        )
        visit.contact = contact
        visit.notes = draft.visitNotes
        visit.notesWereDictated = draft.visitNotesWereDictated
        visit.latitude = draft.latitude
        visit.longitude = draft.longitude
        visit.locationAccuracyMeters = draft.locationAccuracyMeters
        visit.recordedByDisplayName = staffDisplayName
        visit.isSharedWithTeam = entitlements.isSharingActive
        visit.isVerifiedCheckIn = draft.latitude != nil && !draft.attachmentIDs.isEmpty
        return visit
    }

    private func findVisit(_ id: UUID) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Folds the draft's later answers onto a visit that already exists.
    ///
    /// Only the fields the flow actually collects afterwards: the outcome, the
    /// warmth reading and the notes. The location and the timestamp are left
    /// alone, because they are facts about the moment of the scan and not
    /// something a later screen gets to revise.
    private func updateVisit(_ visit: Visit, from draft: DocumentDraft) {
        visit.outcome = draft.isVisitOnly ? nonGivingOutcome(draft) : draft.outcome
        if draft.warmth != .unrated { visit.warmth = draft.warmth }
        if let notes = draft.visitNotes.trimmedOrNil {
            visit.notes = notes
            visit.notesWereDictated = draft.visitNotesWereDictated
        }
        visit.isSharedWithTeam = entitlements.isSharingActive
        visit.touch()
    }

    /// A visit with no gift should not be recorded as "gave today" just because
    /// that is the draft's default.
    private func nonGivingOutcome(_ draft: DocumentDraft) -> VisitOutcome {
        draft.outcome == .gaveNow ? .droppedInfo : draft.outcome
    }

    private func makeGift(draft: DocumentDraft, contact: Contact, visit: Visit) -> Gift {
        let gift = Gift(
            amount: draft.amount,
            method: draft.method,
            receivedAt: draft.giftDate
        )
        gift.contact = contact
        gift.organization = organization
        gift.visit = visit
        gift.fundName = draft.fundName.trimmedOrNil ?? organization.defaultFundName
        gift.referenceNumber = draft.referenceNumber
        gift.notes = draft.giftNotes
        gift.currencyCode = organization.defaultCurrencyCode

        gift.transactionIdentifier = draft.confirmedTransactionIdentifier
        gift.paymentInstrumentDescription = draft.confirmedInstrumentDescription
        gift.payerNameFromNetwork = draft.confirmedPayerName
        // A manual gift is in hand; an electronic one is only confirmed when the
        // processor said so. This flag gates tax documents, so it is not a
        // convenience — it is the guard.
        gift.isPaymentConfirmed = draft.method.requiresNetwork
            ? draft.isPaymentConfirmed
            : (draft.method != .pledge)

        if draft.isInKind {
            gift.inKindDescription = draft.inKindDescription
            gift.inKindQuantity = draft.inKindQuantity
            gift.donorEstimatedValueMinorUnits = draft.donorEstimatedValue.minorUnits
        }

        gift.providedGoodsOrServices = draft.providedGoodsOrServices
        gift.goodsOrServicesDescription = draft.goodsOrServicesDescription
        gift.goodsOrServicesValueMinorUnits = draft.goodsOrServicesValue.minorUnits

        gift.recordedByDisplayName = staffDisplayName
        gift.isSharedWithTeam = entitlements.isSharingActive
        return gift
    }

    private func applyRelationshipUpdates(draft: DocumentDraft, to contact: Contact) {
        for tag in draft.tagsToAdd { contact.addTag(tag) }
        if draft.contactWindow != .unknown {
            contact.contactWindow = draft.contactWindow
        }
        if draft.warmth == .doNotReturn {
            contact.isDoNotContact = true
            contact.doNotContactReason = draft.visitNotes.trimmedOrNil ?? "Asked not to be contacted again."
        }
        // Email volunteered through Apple Pay or typed in the delivery step is
        // worth keeping on the record for next time.
        if contact.email.trimmedOrNil == nil, let email = draft.recipientEmail.trimmedOrNil {
            contact.email = email
        }
        contact.touch()
    }

    private func attachExistingAttachments(
        draft: DocumentDraft,
        contact: Contact,
        visit: Visit,
        gift: Gift?
    ) {
        guard !draft.attachmentIDs.isEmpty else { return }
        let ids = draft.attachmentIDs
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let attachments = (try? context.fetch(descriptor)) ?? []
        for attachment in attachments {
            attachment.contact = contact
            switch attachment.kind {
            case .inKindItem:
                attachment.gift = gift
            case .locationProof, .photo:
                attachment.visit = visit
            case .businessCard, .signature, .voiceNote, .documentPDF:
                break
            }
        }
    }

    private func signatureImage(for draft: DocumentDraft) -> UIImage? {
        if let png = draft.signaturePNG, let image = UIImage(data: png) {
            return image
        }
        guard draft.useSavedSignature,
              let saved = organization.defaultSignatureData else { return nil }
        return UIImage(data: saved)
    }
}
