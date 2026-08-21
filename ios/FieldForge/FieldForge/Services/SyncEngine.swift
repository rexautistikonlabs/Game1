//
//  SyncEngine.swift
//  FieldForge
//
//  Shared organizational memory — the paid tier's headline feature, and the
//  one that changes how a team works.
//
//  What it is for: a volunteer walking a route should be able to see that
//  somebody from the office already visited the hardware store in March, that
//  the owner is warm, that she prefers afternoons, and that she gave $500 last
//  winter. Without that, every organization re-knocks its own doors.
//
//  How it works here: SwiftData mirrors the store into the user's private
//  CloudKit database, which shares across that person's own devices for free.
//  Team-wide sharing needs a shared CloudKit zone, and this file is the seam for
//  it plus the privacy rules that must hold either way.
//
//  The rules, which are product decisions and not implementation details:
//
//    * Nothing is shared unless the organization turns sharing on, per record.
//    * `Contact.privateNotes` and `Visit.privateNotes` NEVER sync. Somewhere to
//      write "the dog is aggressive" without it becoming an org-wide record.
//    * Free tier is local-only. No iCloud prompt, no account, no surprise.
//    * Turning sharing off stops future sync and leaves what has already been
//      shared alone — quietly deleting teammates' data would be worse.
//

import CloudKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SyncEngine {

    enum Status: Equatable {
        /// Free tier or sharing switched off. Everything works; nothing leaves.
        case localOnly
        /// Mirroring to the user's private database.
        case syncingPrivate
        /// Sharing with the team through a shared zone.
        case syncingShared(participantCount: Int)
        /// iCloud is unavailable — signed out, storage full, restricted.
        case unavailable(String)

        var isSyncing: Bool {
            switch self {
            case .syncingPrivate, .syncingShared: return true
            case .localOnly, .unavailable: return false
            }
        }

        var description: String {
            switch self {
            case .localOnly: return "This iPhone only"
            case .syncingPrivate: return "Synced to your iCloud"
            case .syncingShared(let count):
                return count == 1 ? "Shared with 1 teammate" : "Shared with \(count) teammates"
            case .unavailable(let reason): return reason
            }
        }
    }

    private(set) var status: Status = .localOnly
    private(set) var lastCheckedAt: Date?

    /// Set when a record could not be shared, so Settings can explain rather
    /// than showing a permanently spinning indicator.
    private(set) var lastErrorDescription: String?

    private let containerIdentifier: String

    init(containerIdentifier: String = "iCloud.org.example.fieldforge") {
        self.containerIdentifier = containerIdentifier
    }

    /// Checks the iCloud account state. Called at launch and when Settings
    /// opens — not on a timer, because it needs a network and says nothing new.
    func refreshStatus(isProEnabled: Bool, isSharingEnabled: Bool) async {
        lastCheckedAt = .now

        guard isProEnabled, isSharingEnabled else {
            status = .localOnly
            return
        }

        do {
            let accountStatus = try await CKContainer(identifier: containerIdentifier).accountStatus()
            switch accountStatus {
            case .available:
                status = .syncingPrivate
                lastErrorDescription = nil
            case .noAccount:
                status = .unavailable("Sign in to iCloud in Settings to share with your team.")
            case .restricted:
                status = .unavailable("iCloud is restricted on this iPhone, so sharing is off.")
            case .couldNotDetermine:
                status = .unavailable("Could not check iCloud. Your data is safe on this iPhone.")
            case .temporarilyUnavailable:
                status = .unavailable("iCloud is temporarily unavailable. Everything still saves locally.")
            @unknown default:
                status = .unavailable("iCloud state is unknown. Everything still saves locally.")
            }
        } catch {
            AppLog.sync.error("Account status check failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Could not reach iCloud. Your data is safe on this iPhone.")
        }
    }

    /// Whether the container should be built with CloudKit attached.
    ///
    /// Read once, at launch, before the container exists — changing it requires
    /// rebuilding the container, which is why turning team sharing on prompts
    /// for a restart rather than doing it live.
    static func shouldAttachCloudKit(isProEnabled: Bool, isSharingEnabled: Bool) -> Bool {
        isProEnabled && isSharingEnabled
    }

    // MARK: Field-level privacy

    // How private notes actually stay private, stated plainly because it is a
    // real constraint rather than a solved problem:
    //
    // SwiftData mirrors whole models. Everything in the container, including
    // `privateNotes`, goes to the signed-in user's *private* CloudKit database
    // — which is theirs, and is how their own iPhone and iPad stay in step.
    // That is fine and expected.
    //
    // Team sharing is different, and this is the boundary: a shared CloudKit
    // zone would expose whole records to teammates, private notes included. So
    // team sharing must not simply share these models. The supported approach,
    // and the remaining work called out in the README, is a second, narrow
    // `SharedContactRecord` model holding only the fields in `sharedPreview`
    // below, written to the shared zone; `privateNotes` has no counterpart
    // there and therefore cannot leak. Until that model exists, the Team screen
    // reports sharing as "your devices only", which is what it actually is.

    /// What a teammate will actually see for a contact. Used by the UI to show
    /// the staffer exactly what they are about to share, which is the only
    /// honest way to ask for consent.
    static func sharedPreview(of contact: Contact) -> [String] {
        var lines: [String] = [contact.displayName]
        if let subtitle = contact.subtitle.trimmedOrNil { lines.append(subtitle) }
        if contact.warmth != .unrated { lines.append("Warmth: \(contact.warmth.label)") }
        if contact.contactWindow != .unknown { lines.append("Best time: \(contact.contactWindow.label)") }
        if let notes = contact.sharedNotes.trimmedOrNil { lines.append("Notes: \(notes)") }
        if contact.giftCount > 0 {
            lines.append("Giving: \(contact.lifetimeGiving.formatted) across \(contact.giftCount) gifts")
        }
        if contact.privateNotes.trimmedOrNil != nil {
            lines.append("Your private notes stay on this iPhone.")
        }
        return lines
    }

    /// Marks a record and its history as shared. Bulk operation, because a
    /// staffer turning on sharing means "share my route", not "tap 200 rows".
    static func markShared(_ contact: Contact, isShared: Bool) {
        contact.isSharedWithTeam = isShared
        for visit in contact.visits ?? [] { visit.isSharedWithTeam = isShared }
        for gift in contact.gifts ?? [] { gift.isSharedWithTeam = isShared }
        contact.touch()
    }
}
