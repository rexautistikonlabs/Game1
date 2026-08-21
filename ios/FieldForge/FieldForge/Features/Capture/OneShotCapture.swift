//
//  OneShotCapture.swift
//  FieldForge
//
//  Sign in the camera to a saved contact **and** a saved visit, in one action.
//
//  This is the difference between an app someone tolerates and one they keep
//  open. The old path was: scan, review the fields, tap Next, choose an outcome,
//  save. Five interactions for "I walked past this place and talked to
//  somebody". The new path is: scan, tap Use — done, both records exist, GPS
//  stamped, and the flow lands on the gift step in case money changed hands.
//
//  The safety property that makes this acceptable: **nothing here is
//  destructive and everything is editable.** A wrong OCR read produces a
//  correctable contact with a "scanned" flag on it, not a wrong tax document.
//  Committing early is cheap; making the staffer confirm four times is not.
//

import CoreLocation
import Foundation
import SwiftData
import UIKit

@MainActor
struct OneShotCapture {

    /// What the caller gets back, so the capture flow can continue from here.
    struct Result {
        let contact: Contact
        let visit: Visit
        /// `true` when an existing contact was matched rather than created. The
        /// UI says "Back at Delgado Hardware" instead of "Added", which is a
        /// much better thing to read.
        let matchedExisting: Bool
        /// The fields OCR actually filled, for the confirmation line.
        let filledFields: [String]
    }

    enum CaptureError: LocalizedError {
        case noOrganization
        case nothingUsable

        var errorDescription: String? {
            switch self {
            case .noOrganization:
                return "Add your organization in Settings first."
            case .nothingUsable:
                return "Could not read a name from that. Try again closer in, or type it."
            }
        }
    }

    let context: ModelContext
    let organization: Organization
    let staffDisplayName: String
    let isSharingActive: Bool

    /// Commits a scan.
    ///
    /// - Parameters:
    ///   - candidate: parsed OCR output.
    ///   - source: whether it came from a sign or a card, so the record carries
    ///     an honest provenance flag.
    ///   - location: the fix at scan time, if one had arrived. Never waited for.
    ///   - attachmentData: the frame that was scanned, kept as evidence. A
    ///     photo of the storefront is worth more than the OCR guess it produced.
    @discardableResult
    func commit(
        candidate: ParsedContactCandidate,
        source: ContactSource,
        location: CLLocation?,
        attachmentData: Data? = nil
    ) throws -> Result {
        guard candidate.isUsable else { throw CaptureError.nothingUsable }

        let existing = findExisting(candidate)
        let contact = existing ?? makeContact(from: candidate, source: source)

        // An existing record's typed fields win; the scan only ever fills gaps.
        if existing != nil {
            fillGaps(on: contact, from: candidate)
        }
        if let location {
            // Only stamp coordinates onto a contact that has none. A business
            // does not move because somebody stood across the street.
            if contact.latitude == nil {
                contact.latitude = location.coordinate.latitude
                contact.longitude = location.coordinate.longitude
            }
        }
        contact.touch()

        // The visit. `droppedInfo` rather than `gaveNow`: at this instant no
        // gift has been recorded, and defaulting to "gave" would inflate the
        // conversion figures on the Today screen.
        let visit = Visit(occurredAt: .now, outcome: .droppedInfo, warmth: .unrated)
        visit.contact = contact
        visit.recordedByDisplayName = staffDisplayName
        visit.isSharedWithTeam = isSharingActive
        if let location { visit.applyLocation(location) }
        context.insert(visit)

        if let attachmentData {
            let attachment = Attachment(
                kind: source == .businessCard ? .businessCard : .locationProof,
                data: attachmentData,
                caption: source == .businessCard ? "Scanned card" : "Scanned sign"
            )
            attachment.isCapturedLive = true
            attachment.capturedAt = .now
            attachment.latitude = location?.coordinate.latitude
            attachment.longitude = location?.coordinate.longitude
            attachment.contact = contact
            attachment.visit = visit
            attachment.generateThumbnail()
            context.insert(attachment)
            visit.isVerifiedCheckIn = location != nil
        }

        contact.recomputeRollups()

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        AppLog.capture.info("One-shot capture: matched=\(existing != nil, privacy: .public)")
        return Result(
            contact: contact,
            visit: visit,
            matchedExisting: existing != nil,
            filledFields: describeFilled(candidate)
        )
    }

    // MARK: Pieces

    private func makeContact(from candidate: ParsedContactCandidate, source: ContactSource) -> Contact {
        let contact = Contact(
            name: candidate.name.trimmedOrNil ?? candidate.personName,
            kind: candidate.personName.trimmedOrNil != nil && candidate.name.trimmedOrNil == nil
                ? .individual
                : .business,
            source: source
        )
        contact.organization = organization
        contact.contactPersonName = candidate.personName
        contact.contactPersonTitle = candidate.personTitle
        contact.phone = candidate.phone
        contact.email = candidate.email
        contact.addressLine1 = candidate.addressLine1
        contact.city = candidate.city
        contact.state = candidate.state
        contact.postalCode = candidate.postalCode
        contact.createdByDisplayName = staffDisplayName
        contact.isSharedWithTeam = isSharingActive
        context.insert(contact)
        return contact
    }

    /// Fills only what is blank. A human's typing is always more trustworthy
    /// than a camera's guess, so nothing already present is overwritten.
    private func fillGaps(on contact: Contact, from candidate: ParsedContactCandidate) {
        if contact.contactPersonName.trimmedOrNil == nil { contact.contactPersonName = candidate.personName }
        if contact.contactPersonTitle.trimmedOrNil == nil { contact.contactPersonTitle = candidate.personTitle }
        if contact.phone.trimmedOrNil == nil { contact.phone = candidate.phone }
        if contact.email.trimmedOrNil == nil { contact.email = candidate.email }
        if contact.addressLine1.trimmedOrNil == nil { contact.addressLine1 = candidate.addressLine1 }
        if contact.city.trimmedOrNil == nil { contact.city = candidate.city }
        if contact.state.trimmedOrNil == nil { contact.state = candidate.state }
        if contact.postalCode.trimmedOrNil == nil { contact.postalCode = candidate.postalCode }
    }

    /// Duplicate detection. Deliberately conservative in one direction: a false
    /// *match* silently merges two businesses, which is worse than a false
    /// *miss* that leaves a duplicate the staffer can merge later.
    private func findExisting(_ candidate: ParsedContactCandidate) -> Contact? {
        guard let name = candidate.name.trimmedOrNil?.lowercased() else { return nil }
        let descriptor = FetchDescriptor<Contact>(
            predicate: #Predicate { $0.isArchived == false }
        )
        let all = (try? context.fetch(descriptor)) ?? []

        // Exact name match first — the common and safe case.
        if let exact = all.first(where: { $0.displayName.lowercased() == name }) {
            return exact
        }

        // Then a containment match, but only when the city agrees. Without that
        // guard, two different "Corner Store"s in one county become one record.
        if let city = candidate.city.trimmedOrNil?.lowercased() {
            return all.first { contact in
                let existing = contact.displayName.lowercased()
                guard existing.contains(name) || name.contains(existing) else { return false }
                return contact.city.lowercased() == city
            }
        }
        return nil
    }

    private func describeFilled(_ candidate: ParsedContactCandidate) -> [String] {
        [
            candidate.name.trimmedOrNil != nil ? "name" : nil,
            candidate.personName.trimmedOrNil != nil ? "contact person" : nil,
            candidate.addressLine1.trimmedOrNil != nil ? "address" : nil,
            candidate.phone.trimmedOrNil != nil ? "phone" : nil,
            candidate.email.trimmedOrNil != nil ? "email" : nil,
        ].compactMap { $0 }
    }
}

// MARK: - Turning a result into a draft

extension DocumentDraft {
    /// Seeds a draft from a completed one-shot capture, so the capture flow can
    /// resume at the gift step with the who-step already satisfied.
    static func continuing(from result: OneShotCapture.Result, defaultFund: String) -> DocumentDraft {
        var draft = DocumentDraft()
        draft.existingContactID = result.contact.id
        draft.fundName = defaultFund
        draft.recipientEmail = result.contact.email
        draft.latitude = result.visit.latitude
        draft.longitude = result.visit.longitude
        draft.locationAccuracyMeters = result.visit.locationAccuracyMeters
        // The visit already exists, so the flow must not create a second one.
        draft.committedVisitID = result.visit.id
        return draft
    }
}
