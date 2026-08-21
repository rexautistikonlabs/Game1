//
//  Entitlements.swift
//  FieldForge
//
//  What the free tier does, what the paid tier adds, and where the line is.
//
//  The philosophy, stated so it does not drift:
//
//  The free tier is a complete, unembarrassing tool. A one-person nonprofit
//  must be able to walk a route, take a payment, produce a branded signed
//  receipt or a proper IRS acknowledgment letter, email it, and keep their CRM
//  forever, without paying anything and without a watermark. Anything less is
//  not a "generous free tier", it is a demo, and a demo is useless to the
//  organizations that need this most.
//
//  The paid tier is about *teams and scale*: shared organizational memory, the
//  full Warmth System across a whole staff, multiple organizations, deeper
//  branding, and bulk export. Those are the things that only matter once an
//  organization is big enough to have a budget.
//
//  What is deliberately NOT gated, ever:
//    * document generation, of either kind
//    * the signature
//    * the organization's logo and brand colour
//    * offline capture of anything
//    * emailing or AirDropping a finished document
//    * the donor's own records
//  Charging for any of those would mean a donor's tax letter depends on
//  somebody's subscription being current. That is not a product decision we are
//  willing to make.
//

import Foundation
import Observation

/// A capability the app checks before offering something.
enum Feature: String, CaseIterable {

    // MARK: Free, forever

    /// Both document types, unlimited, unbranded by us.
    case documentGeneration
    /// In-app signature capture embedded in the PDF.
    case signatureCapture
    /// Logo, brand colour, letterhead lines, EIN.
    case coreBranding
    /// Contacts, visits, gifts, notes, tags, reminders.
    case coreCRM
    /// Offline capture and the outbox.
    case offlineQueue
    /// Apple Pay and manual capture.
    case paymentCapture
    /// Rating your own visits and seeing your own warmth scores.
    case personalWarmth
    /// The map of your own contacts.
    case personalMap
    /// Emailing, AirDropping, and printing documents.
    case documentDelivery

    // MARK: Paid

    /// Shared organizational memory: teammates see the same contacts, visits,
    /// warmth scores, and preferred contact times.
    case sharedTeamMemory
    /// More than one organization in one app — fiscal sponsors, consultants.
    case multipleOrganizations
    /// Colour-band letterhead, custom footer, per-document signatory overrides.
    case advancedBranding
    /// CSV and PDF batch export of the whole history.
    case bulkExport
    /// Assigning a follow-up to a teammate.
    case assignFollowUps
    /// Tap to Pay on iPhone, which requires an org-level payment platform
    /// relationship anyway.
    case tapToPay
    /// Route mode: today's follow-ups ordered by walking distance.
    case routeMode
    /// Searching and listing document history beyond the free window. The
    /// documents themselves are never touched — see `historyWindowMonths`.
    case unlimitedHistory

    var isFree: Bool {
        switch self {
        case .documentGeneration, .signatureCapture, .coreBranding, .coreCRM,
             .offlineQueue, .paymentCapture, .personalWarmth, .personalMap,
             .documentDelivery:
            return true
        case .sharedTeamMemory, .multipleOrganizations, .advancedBranding,
             .bulkExport, .assignFollowUps, .tapToPay, .routeMode,
             .unlimitedHistory:
            return false
        }
    }

    /// Shown on the paywall. Written as a benefit, not a feature name.
    var paywallDescription: String? {
        switch self {
        case .sharedTeamMemory:
            return "Everyone on your team sees the same history — who gave, who was warm, and when they said to come back."
        case .multipleOrganizations:
            return "Run several organizations from one app, each with its own letterhead and numbering."
        case .advancedBranding:
            return "Full-colour letterhead, custom footers, and a different signatory per document."
        case .bulkExport:
            return "Export every gift, visit, and document as CSV for your finance system."
        case .assignFollowUps:
            return "Hand a follow-up to whoever is walking that street tomorrow."
        case .tapToPay:
            return "Accept a tap of a physical card on the iPhone itself."
        case .routeMode:
            return "Today's follow-ups put in walking order, so a morning of visits is a route instead of a zigzag."
        case .unlimitedHistory:
            return "Search and browse every document you have ever issued, however far back."
        default:
            return nil
        }
    }

    /// The line the UI shows when a locked feature is tapped. Never scolding.
    var lockedExplanation: String {
        paywallDescription ?? "This is part of FieldForge Team."
    }
}

/// Which tier the user is on.
enum Tier: String, Codable, Equatable {
    case free
    case team

    var displayName: String {
        switch self {
        case .free: return "FieldForge"
        case .team: return "FieldForge Team"
        }
    }
}

/// The single place the app asks "can they do this?".
///
/// Deliberately not a network call and not a launch-blocking check: a staffer
/// in a basement with an expired receipt cache must still be able to issue a
/// receipt. Entitlement state is cached locally and only ever *grants* on a
/// stale cache, never revokes.
@MainActor
@Observable
final class Entitlements {

    private(set) var tier: Tier = .free

    /// When the subscription is known to be valid until. Nil for free.
    private(set) var validUntil: Date?

    /// True while StoreKit is being consulted, so Settings can show a spinner
    /// rather than briefly claiming the user is on the free tier.
    private(set) var isRefreshing = false

    /// The user's own choice to share with the team, independent of the tier.
    /// Being on the paid tier does not mean everything is shared.
    var isTeamSharingEnabled: Bool {
        didSet { UserDefaults.standard.set(isTeamSharingEnabled, forKey: Self.sharingKey) }
    }

    private static let tierKey = "fieldforge.entitlement.tier"
    private static let validUntilKey = "fieldforge.entitlement.validUntil"
    private static let sharingKey = "fieldforge.entitlement.teamSharing"

    init() {
        // Restore the cached tier before StoreKit answers, so a launch with no
        // network does not flash the paywall at a paying customer.
        let cached = UserDefaults.standard.string(forKey: Self.tierKey)
        tier = Tier(rawValue: cached ?? "") ?? .free
        validUntil = UserDefaults.standard.object(forKey: Self.validUntilKey) as? Date
        isTeamSharingEnabled = UserDefaults.standard.bool(forKey: Self.sharingKey)
    }

    // MARK: Queries

    func isEnabled(_ feature: Feature) -> Bool {
        if feature.isFree { return true }
        return tier == .team
    }

    var isPro: Bool { tier == .team }

    /// Whether shared memory is actually operating: paid, and switched on.
    var isSharingActive: Bool {
        isEnabled(.sharedTeamMemory) && isTeamSharingEnabled
    }

    /// Document numbers carry a device tag only when several people might be
    /// minting numbers at once.
    var needsDeviceTaggedDocumentNumbers: Bool { isSharingActive }

    /// How far back the Documents list and its search reach on this tier.
    ///
    /// Eighteen months, not three. That is deliberate and it is the difference
    /// between a limit and a hostage: eighteen months covers the whole of last
    /// tax year plus the current one, which is the window a donor actually calls
    /// about. A nonprofit that never pays can still answer every realistic
    /// "can you resend my receipt from April?".
    ///
    /// **Nothing is ever deleted.** This caps what the list *shows*, and the
    /// Documents screen says so with a row that names the count it is hiding.
    /// A subscription lapsing must never make a donor's tax record unreachable —
    /// it simply goes back behind the window it came from.
    var historyWindowMonths: Int? {
        isEnabled(.unlimitedHistory) ? nil : 18
    }

    /// The cutoff date for the history window, or `nil` when unlimited.
    var historyCutoff: Date? {
        guard let months = historyWindowMonths else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: .now)
    }

    // MARK: Updating

    func apply(tier newTier: Tier, validUntil expiry: Date?) {
        // Only ever move up on a stale or failed check. A paying customer whose
        // receipt validation times out on a train keeps their features.
        if newTier == .free, tier == .team, expiry == nil {
            AppLog.store.info("Ignoring downgrade with no expiry — treating as an unverified check")
            return
        }
        tier = newTier
        validUntil = expiry
        UserDefaults.standard.set(newTier.rawValue, forKey: Self.tierKey)
        if let expiry {
            UserDefaults.standard.set(expiry, forKey: Self.validUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.validUntilKey)
        }
        AppLog.store.info("Tier is now \(newTier.rawValue, privacy: .public)")
    }

    func setRefreshing(_ value: Bool) { isRefreshing = value }

    /// Used only in previews and tests.
    static func previewTeam() -> Entitlements {
        let entitlements = Entitlements()
        entitlements.tier = .team
        entitlements.isTeamSharingEnabled = true
        return entitlements
    }
}
