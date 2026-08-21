//
//  Visit.swift
//  FieldForge
//
//  One interaction. A visit exists whether or not money changed hands — that
//  is the whole point. Twenty documented "not today"s are how the twenty-first
//  door opens, and an app that only records gifts throws that away.
//

import CoreLocation
import Foundation
import SwiftData

@Model
final class Visit {

    var id: UUID = UUID()

    /// When the interaction happened, not when it was typed up. Defaults to
    /// now, but is editable so an evening of catching-up on notes is honest.
    var occurredAt: Date = Date.now

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var outcomeRawValue: String = VisitOutcome.droppedInfo.rawValue
    var outcome: VisitOutcome {
        get { VisitOutcome(rawValue: outcomeRawValue) ?? .droppedInfo }
        set { outcomeRawValue = newValue.rawValue }
    }

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var warmthRawValue: Int = Warmth.unrated.rawValue
    /// The one-tap rating. This is the single highest-value field in the app
    /// and the capture flow never lets a visit be saved without offering it.
    var warmth: Warmth {
        get { Warmth(rawValue: warmthRawValue) ?? .unrated }
        set { warmthRawValue = newValue.rawValue }
    }

    // MARK: What was said

    /// Typed or dictated. `SpeechTranscriber` writes straight into this field.
    var notes: String = ""

    /// True when `notes` came out of the on-device speech recognizer, so the
    /// UI can offer a "check this" affordance and an undo.
    var notesWereDictated: Bool = false

    /// Kept private to the staffer even when the visit is shared.
    var privateNotes: String = ""

    // MARK: Where

    var latitude: Double?
    var longitude: Double?

    /// Horizontal accuracy in metres at the moment of capture. Stored so a
    /// 2 km cell-tower fix can be shown as approximate rather than presented
    /// with false confidence.
    var locationAccuracyMeters: Double?

    /// Reverse-geocoded street, when a network was available or the outbox got
    /// around to it later.
    var resolvedAddress: String = ""

    /// A GPS check-in is a claim; a timestamped photo of the storefront is
    /// evidence. Grant reporting sometimes wants the second kind.
    var isVerifiedCheckIn: Bool = false

    // MARK: Duration

    var checkedInAt: Date?
    var checkedOutAt: Date?

    // MARK: Sharing

    var isSharedWithTeam: Bool = false
    var recordedByDisplayName: String = ""

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    // MARK: Relationships

    /// Inverse declared on `Contact.visits`.
    var contact: Contact?

    /// The gift, if this visit produced one. A visit can exist without a gift
    /// and — for a mailed-in cheque — a gift can exist without a visit.
    @Relationship(deleteRule: .nullify, inverse: \Gift.visit)
    var gift: Gift?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.visit)
    var attachments: [Attachment]? = []

    init(
        occurredAt: Date = .now,
        outcome: VisitOutcome = .droppedInfo,
        warmth: Warmth = .unrated
    ) {
        self.occurredAt = occurredAt
        self.outcomeRawValue = outcome.rawValue
        self.warmthRawValue = warmth.rawValue
    }

    // MARK: Derived

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var durationSeconds: TimeInterval? {
        guard let checkedInAt, let checkedOutAt else { return nil }
        let elapsed = checkedOutAt.timeIntervalSince(checkedInAt)
        return elapsed > 0 ? elapsed : nil
    }

    var formattedDuration: String? {
        guard let seconds = durationSeconds else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }

    /// A fix worse than 100 m is roughly "this block", not "this address", and
    /// the UI says so rather than dropping a confident pin.
    var isLocationApproximate: Bool {
        guard let accuracy = locationAccuracyMeters else { return true }
        return accuracy > 100
    }

    var hasPhotoEvidence: Bool {
        (attachments ?? []).contains { $0.kind == .locationProof || $0.kind == .photo }
    }

    var summaryLine: String {
        var parts: [String] = [outcome.label]
        if warmth != .unrated { parts.append(warmth.label) }
        if let note = notes.trimmedOrNil {
            parts.append(note.count > 60 ? String(note.prefix(60)) + "…" : note)
        }
        return parts.joined(separator: " · ")
    }

    func touch() { updatedAt = .now }

    /// Applies a location fix. Called by `LocationService` once, at capture
    /// time — a visit's coordinates are a historical fact and are never
    /// silently updated afterwards.
    func applyLocation(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        locationAccuracyMeters = location.horizontalAccuracy
        touch()
    }
}
