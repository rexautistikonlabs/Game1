//
//  DocumentNumberer.swift
//  FieldForge
//
//  Mints human-readable, non-repeating document numbers.
//
//  A document number has one job: when a donor calls in October about "the
//  receipt from the spring", somebody has to find it in ten seconds. So the
//  number is short, readable aloud, sorts chronologically, and says what kind
//  of document it is.
//
//      RCT-2026-0042        receipt, 42nd of 2026
//      ACK-2026-0007        acknowledgment letter, 7th of 2026
//      RCT-2026-0042-K7     the same, on a team with shared numbering
//      RCT-2026-0042-R1     a corrected re-issue of that receipt
//
//  The device tag is the interesting part. Two staffers offline in different
//  neighbourhoods will both take the next sequence number from their own
//  device and both mint "0042". Appending a per-install tag makes the
//  collision impossible without needing a server to hand out numbers — which
//  is the whole design constraint of an offline-first field app.
//

import Foundation
import SwiftData

struct DocumentNumberer {

    /// Pure formatting, extracted so it can be tested without a store.
    static func format(
        prefix: String,
        year: Int,
        sequence: Int,
        deviceTag: String? = nil,
        revision: Int = 0
    ) -> String {
        var parts = [
            prefix.uppercased(),
            String(year),
            String(format: "%04d", sequence),
        ]
        if let tag = deviceTag?.trimmedOrNil {
            parts.append(tag.uppercased())
        }
        if revision > 0 {
            parts.append("R\(revision)")
        }
        return parts.joined(separator: "-")
    }

    /// Takes the next number for a document kind and advances the counter.
    ///
    /// Mutates the organization, so the caller is expected to save. Rolls the
    /// counter over on 1 January without any scheduled work: the year is
    /// compared at mint time, which is the only moment it matters.
    ///
    /// - Parameter includeDeviceTag: pass `true` when team sync is on. Solo
    ///   users get the shorter number.
    @MainActor
    static func next(
        kind: DocumentKind,
        organization: Organization,
        includeDeviceTag: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let year = calendar.component(.year, from: now)

        if organization.sequenceYear != year {
            organization.sequenceYear = year
            organization.nextReceiptSequence = 1
            organization.nextLetterSequence = 1
        }

        let prefix: String
        let sequence: Int
        switch kind {
        case .receipt:
            prefix = organization.receiptPrefix.trimmedOrNil ?? "RCT"
            sequence = organization.nextReceiptSequence
            organization.nextReceiptSequence += 1
        case .letter:
            prefix = organization.letterPrefix.trimmedOrNil ?? "ACK"
            sequence = organization.nextLetterSequence
            organization.nextLetterSequence += 1
        }

        organization.touch()

        return format(
            prefix: prefix,
            year: year,
            sequence: sequence,
            deviceTag: includeDeviceTag ? organization.deviceTag : nil
        )
    }

    /// The number for a corrected re-issue. Keeps the original number visible —
    /// a donor holding both copies can see they are the same gift — and adds a
    /// revision suffix so the current one is unambiguous.
    static func revision(of original: String, revision: Int) -> String {
        // Strip any existing -Rn so a second correction reads R2, not R1-R2.
        let base = original
            .split(separator: "-")
            .filter { !($0.count >= 2 && $0.first == "R" && Int($0.dropFirst()) != nil) }
            .joined(separator: "-")
        return "\(base)-R\(revision)"
    }

    /// Belt-and-braces check used before saving a document. Local uniqueness is
    /// all we can guarantee offline, and it catches the real-world case: a
    /// restored backup replaying counters that were already used.
    @MainActor
    static func isAvailable(_ number: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<GeneratedDocument>(
            predicate: #Predicate { $0.documentNumber == number }
        )
        descriptor.fetchLimit = 1
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        return existing == 0
    }

    /// Mints a number that is definitely free, advancing past any collision.
    /// Bounded so a corrupted counter cannot spin.
    @MainActor
    static func nextAvailable(
        kind: DocumentKind,
        organization: Organization,
        includeDeviceTag: Bool,
        context: ModelContext,
        now: Date = .now
    ) -> String {
        for _ in 0..<50 {
            let candidate = next(
                kind: kind,
                organization: organization,
                includeDeviceTag: includeDeviceTag,
                now: now
            )
            if isAvailable(candidate, in: context) { return candidate }
            AppLog.documents.warning("Document number collision; advancing counter")
        }
        // Fifty collisions means the counter is badly out of step with reality.
        // Fall back to something guaranteed unique rather than refusing to
        // issue a document to the donor standing there.
        let suffix = UUID().uuidString.prefix(6).uppercased()
        return "\(kind == .receipt ? "RCT" : "ACK")-\(Calendar.current.component(.year, from: now))-\(suffix)"
    }
}
