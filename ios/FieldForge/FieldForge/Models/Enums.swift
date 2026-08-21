//
//  Enums.swift
//  FieldForge
//
//  Every enum persisted by SwiftData is stored as its `String` raw value on
//  the model and exposed through a computed property. That costs a few lines
//  per model but buys two things worth much more: `#Predicate` can filter on
//  the raw string on every OS version, and an unknown value arriving from a
//  newer build over CloudKit degrades to a sensible default instead of
//  failing to decode.
//

import Foundation

/// How a gift arrived. Drives the receipt's "Payment method" row, the letter's
/// tax language, and which fields the capture flow asks for.
enum GiftMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case applePay
    case tapToPay
    case cash
    case check
    case cardManual
    case inKind
    case pledge
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .applePay: return "Apple Pay"
        case .tapToPay: return "Tap to Pay"
        case .cash: return "Cash"
        case .check: return "Check"
        case .cardManual: return "Card (recorded manually)"
        case .inKind: return "In-kind gift"
        case .pledge: return "Pledge"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .applePay: return "applelogo"
        case .tapToPay: return "wave.3.right.circle.fill"
        case .cash: return "banknote.fill"
        case .check: return "doc.text.fill"
        case .cardManual: return "creditcard.fill"
        case .inKind: return "shippingbox.fill"
        case .pledge: return "hand.raised.fingers.spread.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// Electronic methods need a live connection; the capture flow offers the
    /// manual fallbacks first when there are no bars.
    var requiresNetwork: Bool {
        switch self {
        case .applePay, .tapToPay: return true
        case .cash, .check, .cardManual, .inKind, .pledge, .other: return false
        }
    }

    /// A pledge is a promise, not a contribution — issuing a tax
    /// acknowledgment for one would be wrong, so the document step blocks it
    /// and offers a confirmation letter instead.
    var isTaxDeductibleContribution: Bool { self != .pledge }

    /// In-kind gifts get entirely different language and never a dollar total
    /// on the letter. See `TaxLanguage`.
    var isInKind: Bool { self == .inKind }

    /// Methods a staffer can record with no connectivity and no card reader.
    static var offlineCapable: [GiftMethod] { [.cash, .check, .inKind, .cardManual, .pledge, .other] }
}

/// The two faces of the document engine. Same gift, same donor, same
/// organization — two completely different pieces of paper.
enum DocumentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Clean business-style receipt. Hand this to the shop owner who just
    /// tapped their card and wants something for their books.
    case receipt
    /// Formal, IRS-compliant written acknowledgment on letterhead. This is the
    /// document a donor's accountant wants in April.
    case letter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .receipt: return "Receipt"
        case .letter: return "Letter"
        }
    }

    var longLabel: String {
        switch self {
        case .receipt: return "Donation receipt"
        case .letter: return "Acknowledgment letter"
        }
    }

    var symbolName: String {
        switch self {
        case .receipt: return "receipt"
        case .letter: return "doc.richtext"
        }
    }

    var explanation: String {
        switch self {
        case .receipt: return "Short, business-style proof of payment. Best for handing over on the spot."
        case .letter: return "Formal written acknowledgment with IRS substantiation language. Best for the donor's tax file."
        }
    }

    var other: DocumentKind { self == .receipt ? .letter : .receipt }

    /// Filename-safe stem used for the exported PDF.
    var fileStem: String { self == .receipt ? "Receipt" : "Acknowledgment" }
}

/// Where a finished PDF is in its life. A document is never lost: it is
/// always in exactly one of these states, and `.queued` survives app launches.
enum DeliveryState: String, CaseIterable, Codable, Sendable {
    /// Rendered and saved locally, no delivery requested.
    case saved
    /// Delivery requested with no connection. Waiting in the outbox.
    case queued
    /// Handed to Mail / the share sheet / AirDrop successfully.
    case sent
    /// Delivery was attempted and refused. `OutboxItem.lastError` says why.
    case failed
    /// Superseded by a re-issue. Kept for the audit trail, hidden by default.
    case superseded

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .queued: return "Queued to send"
        case .sent: return "Sent"
        case .failed: return "Send failed"
        case .superseded: return "Re-issued"
        }
    }

    var symbolName: String {
        switch self {
        case .saved: return "tray.full"
        case .queued: return "clock.arrow.circlepath"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .superseded: return "arrow.triangle.2.circlepath"
        }
    }
}

/// What actually happened at the door. Separate from warmth: warmth is how
/// they felt about us, outcome is what we walked away with.
enum VisitOutcome: String, CaseIterable, Codable, Identifiable, Sendable {
    case gaveNow
    case pledged
    case askAgainLater
    case declined
    case wrongPerson
    case closedOrGone
    case droppedInfo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gaveNow: return "Gave today"
        case .pledged: return "Promised to give"
        case .askAgainLater: return "Come back later"
        case .declined: return "Declined"
        case .wrongPerson: return "Decision-maker not in"
        case .closedOrGone: return "Closed or moved"
        case .droppedInfo: return "Left materials"
        }
    }

    var symbolName: String {
        switch self {
        case .gaveNow: return "checkmark.seal.fill"
        case .pledged: return "hand.thumbsup.fill"
        case .askAgainLater: return "calendar.badge.clock"
        case .declined: return "xmark.circle"
        case .wrongPerson: return "person.fill.questionmark"
        case .closedOrGone: return "building.2.crop.circle.badge.minus"
        case .droppedInfo: return "doc.on.doc"
        }
    }

    /// Outcomes the follow-up engine offers a reminder for, and how far out it
    /// suggests by default.
    var suggestedFollowUpDays: Int? {
        switch self {
        case .gaveNow: return 365           // next year's ask
        case .pledged: return 14            // collect the pledge
        case .askAgainLater: return 90
        case .wrongPerson: return 7         // catch them when they are in
        case .droppedInfo: return 10
        case .declined, .closedOrGone: return nil
        }
    }
}

/// What a stored file is, so the UI can present it correctly without sniffing
/// bytes and so exports can pick the right attachments.
enum AttachmentKind: String, CaseIterable, Codable, Sendable {
    case photo
    case inKindItem
    case businessCard
    case locationProof
    case signature
    case voiceNote
    case documentPDF

    var label: String {
        switch self {
        case .photo: return "Photo"
        case .inKindItem: return "In-kind item"
        case .businessCard: return "Business card"
        case .locationProof: return "Location photo"
        case .signature: return "Signature"
        case .voiceNote: return "Voice note"
        case .documentPDF: return "Document"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "photo"
        case .inKindItem: return "shippingbox"
        case .businessCard: return "person.text.rectangle"
        case .locationProof: return "mappin.and.ellipse"
        case .signature: return "signature"
        case .voiceNote: return "waveform"
        case .documentPDF: return "doc.fill"
        }
    }

    var fileExtension: String {
        switch self {
        case .documentPDF: return "pdf"
        case .voiceNote: return "m4a"
        case .signature: return "png"
        default: return "jpg"
        }
    }
}

/// Work that could not be done at the moment it was asked for. The outbox is
/// the promise that nothing is lost offline.
enum OutboxKind: String, CaseIterable, Codable, Sendable {
    /// Email a rendered PDF to a donor.
    case emailDocument
    /// Turn stored coordinates into a street address once there is a network.
    case reverseGeocode
    /// Push local records into shared organizational memory (Pro).
    case syncUpstream

    var label: String {
        switch self {
        case .emailDocument: return "Email document"
        case .reverseGeocode: return "Look up address"
        case .syncUpstream: return "Share with team"
        }
    }

    /// Whether the user has to be present. Emailing needs the Mail composer,
    /// so it is walked through on the Outbox screen; the rest drain silently.
    var requiresUserPresence: Bool { self == .emailDocument }
}

/// Where a contact record came from. Useful for data hygiene and for telling a
/// staffer that a name was OCR'd and may need a glance.
enum ContactSource: String, CaseIterable, Codable, Sendable {
    case manual
    case signOCR
    case businessCard
    case deviceContacts
    case teamShared
    case imported

    var label: String {
        switch self {
        case .manual: return "Typed"
        case .signOCR: return "Scanned from a sign"
        case .businessCard: return "Business card"
        case .deviceContacts: return "From Contacts"
        case .teamShared: return "Shared by a teammate"
        case .imported: return "Imported"
        }
    }

    /// Machine-read fields deserve a "check this" affordance in the UI.
    var needsHumanReview: Bool { self == .signOCR || self == .businessCard }
}

/// A contact can be a business, a person, a foundation, or a congregation, and
/// the letter salutation differs for each.
enum ContactKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case business
    case individual
    case foundation
    case faithCommunity
    case governmentOrSchool

    var id: String { rawValue }

    var label: String {
        switch self {
        case .business: return "Business"
        case .individual: return "Individual"
        case .foundation: return "Foundation"
        case .faithCommunity: return "Faith community"
        case .governmentOrSchool: return "Government or school"
        }
    }

    var symbolName: String {
        switch self {
        case .business: return "storefront.fill"
        case .individual: return "person.fill"
        case .foundation: return "building.columns.fill"
        case .faithCommunity: return "building.2.fill"
        case .governmentOrSchool: return "graduationcap.fill"
        }
    }
}

/// The action a reminder is asking for. Drives the one-tap button on the
/// follow-up row, so a reminder is never a dead end.
enum FollowUpKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case call
    case text
    case email
    case visitAgain
    case sendDocument
    case collectPledge
    case thankYou
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .call: return "Call"
        case .text: return "Text"
        case .email: return "Email"
        case .visitAgain: return "Visit again"
        case .sendDocument: return "Send document"
        case .collectPledge: return "Collect pledge"
        case .thankYou: return "Say thank you"
        case .other: return "Follow up"
        }
    }

    var symbolName: String {
        switch self {
        case .call: return "phone.fill"
        case .text: return "message.fill"
        case .email: return "envelope.fill"
        case .visitAgain: return "figure.walk"
        case .sendDocument: return "paperplane.fill"
        case .collectPledge: return "dollarsign.circle.fill"
        case .thankYou: return "heart.fill"
        case .other: return "bell.fill"
        }
    }
}

/// Best time of day to catch a contact. Volunteered by whoever visited, and
/// one of the highest-value things shared memory can carry.
enum ContactWindow: String, CaseIterable, Codable, Identifiable, Sendable {
    case unknown
    case earlyMorning
    case midMorning
    case lunch
    case afternoon
    case evening
    case byAppointment
    case neverDuringRush

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .earlyMorning: return "Early morning"
        case .midMorning: return "Mid-morning"
        case .lunch: return "Lunch hour"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .byAppointment: return "By appointment only"
        case .neverDuringRush: return "Avoid the rush"
        }
    }
}
