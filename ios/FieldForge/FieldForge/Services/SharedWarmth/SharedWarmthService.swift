//
//  SharedWarmthService.swift
//  FieldForge
//
//  Shared organizational memory, over a CloudKit shared record zone.
//
//  Why this is hand-rolled CloudKit rather than SwiftData mirroring: SwiftData's
//  CloudKit integration targets the *private* database only. It keeps one
//  person's devices in step, which is useful but is not a team. Sharing with
//  other people needs a `CKShare`, and a share needs a zone, and neither is
//  something SwiftData will drive. So the projection store is a plain local
//  SwiftData store and this service moves it over CloudKit by hand.
//
//  The zone-level share (`CKShare(recordZoneID:)`) is the right primitive here
//  rather than per-record shares: a team shares one zone, everyone in it reads
//  and writes, and adding a teammate does not mean re-sharing 400 records.
//
//  Offline behaviour, which is the whole reason the app exists: every write is
//  local-first. `needsUpload` marks a row as ahead of the server and the push
//  pass drains it whenever there is a network. Being offline for a week means a
//  week of dirty rows and one catch-up push, not a week of lost work.
//

import CloudKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SharedWarmthService {

    // MARK: State

    enum State: Equatable {
        /// Free tier, or sharing switched off. Everything works; nothing leaves.
        case off
        /// Pro, sharing on, but no team zone exists yet.
        case notSetUp
        /// This device owns the team zone.
        case owner(participantCount: Int)
        /// This device joined somebody else's team zone.
        case participant(ownerName: String)
        /// iCloud is unavailable. Local data is untouched and still syncing
        /// nowhere, which is safe.
        case unavailable(String)

        var isActive: Bool {
            switch self {
            case .owner, .participant: return true
            case .off, .notSetUp, .unavailable: return false
            }
        }

        var description: String {
            switch self {
            case .off: return "Not sharing"
            case .notSetUp: return "Ready to set up"
            case .owner(let count):
                if count == 0 { return "Your team — nobody invited yet" }
                return count == 1 ? "Sharing with 1 teammate" : "Sharing with \(count) teammates"
            case .participant(let owner): return "Joined \(owner)'s team"
            case .unavailable(let reason): return reason
            }
        }
    }

    private(set) var state: State = .off
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastErrorDescription: String?
    /// Rows waiting to go up. Surfaced so the Team screen can be honest about
    /// a backlog instead of showing a permanent spinner.
    private(set) var pendingUploadCount = 0

    // MARK: Configuration

    static let zoneName = "TeamWarmth"
    /// The record the zone share hangs off. CloudKit wants a root record for a
    /// hierarchical share; for a zone share it is simply a marker that the zone
    /// has been set up.
    private static let rootRecordType = "TeamRoot"
    private static let rootRecordName = "team-root"

    private let container: CKContainer
    private let modelContainer: ModelContainer
    private let reachability: Reachability

    /// Server change tokens, per zone, so a pull fetches deltas rather than the
    /// whole team's history every time.
    private let tokenStore = ChangeTokenStore()

    init(
        modelContainer: ModelContainer,
        reachability: Reachability,
        containerIdentifier: String = "iCloud.org.example.fieldforge"
    ) {
        self.modelContainer = modelContainer
        self.reachability = reachability
        self.container = CKContainer(identifier: containerIdentifier)
    }

    private var context: ModelContext { modelContainer.mainContext }

    // MARK: Status

    /// Called at launch, when Settings opens, and after a tier change.
    func refreshState(isEnabled: Bool) async {
        guard isEnabled else {
            state = .off
            return
        }

        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                state = .unavailable(Self.explain(accountStatus))
                return
            }
        } catch {
            state = .unavailable("Could not reach iCloud. Everything is still saved on this iPhone.")
            return
        }

        // Am I a participant in somebody else's team?
        if let sharedZone = try? await firstSharedZone() {
            let ownerName = sharedZone.owner
            state = .participant(ownerName: ownerName)
            refreshPendingCount()
            return
        }

        // Do I own a team zone?
        if await ownsTeamZone() {
            let count = (try? await participantCount()) ?? 0
            state = .owner(participantCount: count)
        } else {
            state = .notSetUp
        }
        refreshPendingCount()
    }

    private static func explain(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return ""
        case .noAccount: return "Sign in to iCloud in Settings to share with your team."
        case .restricted: return "iCloud is restricted on this iPhone, so team sharing is off."
        case .couldNotDetermine: return "Could not check iCloud. Everything is still saved on this iPhone."
        case .temporarilyUnavailable: return "iCloud is briefly unavailable. Nothing is lost."
        @unknown default: return "iCloud is in an unknown state. Everything is still saved on this iPhone."
        }
    }

    // MARK: Setting up a team

    /// Creates the zone and its share. Returns the `CKShare` so the caller can
    /// hand it to `UICloudSharingController` for the invite.
    func createTeamShare(teamName: String) async throws -> (share: CKShare, container: CKContainer) {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)

        // Idempotent: saving an existing zone is not an error.
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])

        let rootID = CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
        let root = CKRecord(recordType: Self.rootRecordType, recordID: rootID)
        root["teamName"] = teamName as CKRecordValue

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = teamName as CKRecordValue
        // Teammates need to write: a volunteer rating a visit is the entire
        // point, so read-only sharing would defeat the feature.
        share.publicPermission = .none

        _ = try await container.privateCloudDatabase.modifyRecords(saving: [root, share], deleting: [])

        state = .owner(participantCount: 0)
        AppLog.sync.info("Team zone and share created")
        return (share, container)
    }

    /// Fetches the existing share so a second invite does not create a second
    /// team.
    ///
    /// A zone-wide share always lives at a well-known record name inside its own
    /// zone (`CKRecordNameZoneWideShare`). Looking it up by that name is more
    /// robust than reading `CKRecordZone.share`, which requires the zone object
    /// to have been fetched with its share reference populated.
    ///
    /// A missing share is not an error — it is the normal state before a team
    /// has been set up — so `unknownItem` is folded into `nil` rather than
    /// thrown.
    func existingShare() async throws -> CKShare? {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            return try await container.privateCloudDatabase.record(for: shareID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    private func participantCount() async throws -> Int {
        guard let share = try await existingShare() else { return 0 }
        // The owner is in the participant list; teammates are everyone else.
        return share.participants.filter { $0.role != .owner }.count
    }

    /// Whether a team zone exists in this account. Cheaper and more direct than
    /// listing every zone.
    private func ownsTeamZone() async -> Bool {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: zoneID)
            return true
        } catch {
            return false
        }
    }

    /// Stops sharing entirely. Deletes the zone, which withdraws every record
    /// from every teammate.
    ///
    /// Local `Contact` records are untouched — a staffer leaving a team keeps
    /// their own work, which is both correct and the only defensible behaviour.
    func stopSharing() async throws {
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        tokenStore.clearAll()
        try clearLocalProjections()
        state = .notSetUp
        AppLog.sync.info("Team sharing stopped and zone deleted")
    }

    // MARK: Projecting local contacts

    /// Projects one contact into the shared store. Local and instant; the push
    /// happens later and may be much later.
    func project(_ contact: Contact, staffDisplayName: String) {
        guard state.isActive || state == .notSetUp else { return }

        let projection = existingProjection(for: contact.id) ?? {
            let fresh = SharedContactProjection(contactID: contact.id, teamZoneName: Self.zoneName)
            context.insert(fresh)
            return fresh
        }()

        projection.update(from: contact, updatedBy: staffDisplayName)
        save()
        refreshPendingCount()
        // A contact that now exists locally is no longer "team only".
        refreshTeamOnlyContacts()
    }

    /// Withdraws a contact from the team without deleting anything locally.
    func withdraw(contactID: UUID) {
        guard let projection = existingProjection(for: contactID) else { return }
        projection.isWithdrawn = true
        projection.needsUpload = true
        projection.updatedAt = .now
        save()
        refreshPendingCount()
    }

    /// Re-projects everything currently marked shared. Used after joining a
    /// team, and after a bulk "share my whole route".
    func projectAll(staffDisplayName: String) {
        let descriptor = FetchDescriptor<Contact>(
            predicate: #Predicate { $0.isSharedWithTeam == true && $0.isArchived == false }
        )
        let contacts = (try? context.fetch(descriptor)) ?? []
        for contact in contacts {
            project(contact, staffDisplayName: staffDisplayName)
        }
        AppLog.sync.info("Projected \(contacts.count, privacy: .public) contacts for the team")
    }

    // MARK: Sync

    /// One full round trip: push what is dirty, then pull what changed.
    ///
    /// Push first, deliberately. A staffer who just rated a visit should see
    /// their own reading win a conflict against a teammate's older record.
    func sync() async {
        guard state.isActive, reachability.isOnline, !isSyncing else { return }
        isSyncing = true
        lastErrorDescription = nil
        defer {
            isSyncing = false
            lastSyncedAt = .now
            refreshPendingCount()
            refreshTeamOnlyContacts()
        }

        do {
            try await push()
            try await pull()
        } catch let error as CKError {
            handle(error)
        } catch {
            lastErrorDescription = error.localizedDescription
            AppLog.sync.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func push() async throws {
        let dirty = dirtyProjections()
        guard !dirty.isEmpty else { return }

        let database = writableDatabase
        let zoneID = try await writableZoneID()

        // Withdrawals are deletions; everything else is a save.
        var saving: [CKRecord] = []
        var deleting: [CKRecord.ID] = []

        for projection in dirty {
            let recordID = CKRecord.ID(recordName: projection.recordName, zoneID: zoneID)
            if projection.isWithdrawn {
                deleting.append(recordID)
            } else {
                let record = CKRecord(recordType: SharedContactProjection.recordType, recordID: recordID)
                projection.apply(to: record)
                saving.append(record)
            }
        }

        // CloudKit caps a single modify at 400 records; batch well under it so a
        // staffer coming back from a week offline does not hit the limit.
        for batch in saving.chunked(into: 200) {
            let results = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .changedKeys)
            for (recordID, result) in results.saveResults {
                guard case .success(let record) = result else { continue }
                if let projection = projection(forRecordName: recordID.recordName) {
                    projection.lastKnownChangeTag = record.recordChangeTag ?? ""
                    projection.needsUpload = false
                }
            }
        }

        for batch in deleting.chunked(into: 200) {
            _ = try await database.modifyRecords(saving: [], deleting: batch)
            for recordID in batch {
                if let projection = projection(forRecordName: recordID.recordName) {
                    context.delete(projection)
                }
            }
        }

        save()
        AppLog.sync.info("Pushed \(saving.count, privacy: .public) records, withdrew \(deleting.count, privacy: .public)")
    }

    private func pull() async throws {
        for (database, zoneID) in try await readableZones() {
            var token = tokenStore.token(for: zoneID)
            var pagesFetched = 0

            // CloudKit pages changes. A staffer joining an established team
            // pulls hundreds of records on the first sync, so follow
            // `moreComing` rather than stopping a page in — bounded, so a
            // server that always says "more" cannot spin here forever.
            while pagesFetched < 50 {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)

                for modification in changes.modificationResultsByID.values {
                    guard case .success(let result) = modification else { continue }
                    apply(record: result.record, zoneName: zoneID.zoneName)
                }

                for deletion in changes.deletions {
                    removeProjection(recordName: deletion.recordID.recordName)
                }

                token = changes.changeToken
                tokenStore.setToken(changes.changeToken, for: zoneID)
                // Save each page, so a network drop halfway through a large
                // first sync keeps the pages already fetched.
                save()

                pagesFetched += 1
                guard changes.moreComing else { break }
            }
        }
        save()
    }

    /// Applies one incoming record, merging rather than overwriting.
    private func apply(record: CKRecord, zoneName: String) {
        guard record.recordType == SharedContactProjection.recordType else { return }
        guard let incoming = SharedContactProjection.fromRecord(record, teamZoneName: zoneName) else {
            AppLog.sync.error("Discarded a shared record with no contact id")
            return
        }

        if let existing = existingProjection(for: incoming.contactID) {
            existing.merge(remote: incoming)
        } else {
            context.insert(incoming)
        }
    }

    // MARK: Databases and zones

    /// Where this device writes: its own private zone if it owns the team, the
    /// shared database if it joined someone else's.
    private var writableDatabase: CKDatabase {
        if case .participant = state {
            return container.sharedCloudDatabase
        }
        return container.privateCloudDatabase
    }

    private func writableZoneID() async throws -> CKRecordZone.ID {
        if case .participant = state, let zone = try await firstSharedZone() {
            return zone.zoneID
        }
        return CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Every zone this device can read from. An owner reads their own; a
    /// participant reads the zones shared with them. Someone who owns a team
    /// *and* joined another reads both, which is a real case for a consultant.
    private func readableZones() async throws -> [(CKDatabase, CKRecordZone.ID)] {
        var result: [(CKDatabase, CKRecordZone.ID)] = []

        let privateZones = try await container.privateCloudDatabase.allRecordZones()
        for zone in privateZones where zone.zoneID.zoneName == Self.zoneName {
            result.append((container.privateCloudDatabase, zone.zoneID))
        }

        let sharedZones = (try? await container.sharedCloudDatabase.allRecordZones()) ?? []
        for zone in sharedZones {
            result.append((container.sharedCloudDatabase, zone.zoneID))
        }
        return result
    }

    private struct SharedZoneInfo {
        let zoneID: CKRecordZone.ID
        let owner: String
    }

    private func firstSharedZone() async throws -> SharedZoneInfo? {
        let zones = try await container.sharedCloudDatabase.allRecordZones()
        guard let zone = zones.first else { return nil }
        // The zone's owner name is a CloudKit user record name, not a person's
        // name. Resolve it to something a human recognises where possible.
        return SharedZoneInfo(zoneID: zone.zoneID, owner: friendlyTeamOwnerName)
    }

    /// A CloudKit owner name is an opaque identifier, never a person's name, so
    /// it must not reach the UI. Any record already pulled from the zone carries
    /// a teammate's display name, which is the best thing available; before the
    /// first pull there is nothing, so say something neutral.
    private var friendlyTeamOwnerName: String {
        let descriptor = FetchDescriptor<SharedContactProjection>(
            predicate: #Predicate { $0.isRemote == true }
        )
        let remote = (try? context.fetch(descriptor)) ?? []
        let names = Set(remote.map(\.lastUpdatedByDisplayName).filter { !$0.isEmpty })
        return names.sorted().first ?? "your team"
    }

    // MARK: Error handling

    private func handle(_ error: CKError) {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            // Genuinely transient. Say nothing alarming; the next pass retries.
            AppLog.sync.info("Sync deferred: \(error.code.rawValue, privacy: .public)")
        case .notAuthenticated:
            state = .unavailable("Sign in to iCloud to keep sharing with your team.")
        case .quotaExceeded:
            lastErrorDescription = "The iCloud account is full, so team updates cannot go out. Local data is safe."
        case .zoneNotFound, .userDeletedZone:
            // The owner stopped sharing, or the zone was removed on another
            // device. Drop the local mirror rather than showing stale team data
            // indefinitely.
            tokenStore.clearAll()
            try? clearLocalProjections()
            state = .notSetUp
            lastErrorDescription = "The team share is no longer available. Your own records are untouched."
        case .changeTokenExpired:
            // The server has moved on further than our token covers. Start the
            // zone again from scratch; it is a full refetch, not data loss.
            tokenStore.clearAll()
            AppLog.sync.info("Change token expired; will refetch the zone")
        case .partialFailure:
            let count = (error.partialErrorsByItemID?.count) ?? 0
            lastErrorDescription = count > 0
                ? "\(count) team update\(count == 1 ? "" : "s") could not sync. They will retry."
                : nil
        default:
            lastErrorDescription = error.localizedDescription
            AppLog.sync.error("CloudKit error \(error.code.rawValue, privacy: .public)")
        }
    }

    // MARK: Local store access

    private func existingProjection(for contactID: UUID) -> SharedContactProjection? {
        var descriptor = FetchDescriptor<SharedContactProjection>(
            predicate: #Predicate { $0.contactID == contactID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func projection(forRecordName recordName: String) -> SharedContactProjection? {
        let prefix = "contact-"
        guard recordName.hasPrefix(prefix),
              let id = UUID(uuidString: String(recordName.dropFirst(prefix.count))) else { return nil }
        return existingProjection(for: id)
    }

    private func removeProjection(recordName: String) {
        guard let projection = projection(forRecordName: recordName) else { return }
        context.delete(projection)
    }

    private func dirtyProjections() -> [SharedContactProjection] {
        let descriptor = FetchDescriptor<SharedContactProjection>(
            predicate: #Predicate { $0.needsUpload == true && $0.isRemote == false }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func clearLocalProjections() throws {
        let all = (try? context.fetch(FetchDescriptor<SharedContactProjection>())) ?? []
        for projection in all { context.delete(projection) }
        try context.save()
    }

    private func refreshPendingCount() {
        pendingUploadCount = dirtyProjections().count
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.sync.error("Could not save projections: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Reading the team's view

    /// Teammates' records for a contact this device also knows about. This is
    /// what makes the contact detail screen say "Ana visited in March".
    func remoteProjection(for contactID: UUID) -> SharedContactProjection? {
        guard let projection = existingProjection(for: contactID), projection.isRemote else { return nil }
        return projection
    }

    /// Everything the team knows that this device has no local contact for —
    /// the businesses a colleague has visited and you have not. These are the
    /// rows that stop an organization re-knocking its own doors.
    ///
    /// **Cached, not computed on read.** Working it out needs two full fetches
    /// (every projection, every contact) and it is displayed on the home screen,
    /// so computing it in a view's body would run it on every render pass — a
    /// visible stutter at a few hundred contacts. Recomputed after a sync and
    /// after any projection change instead, which is exactly when it can alter.
    private(set) var teamOnlyContacts: [SharedContactProjection] = []

    /// Recomputes the cache. Cheap enough to call after any projection change;
    /// far too expensive to call from a view body.
    func refreshTeamOnlyContacts() {
        guard state.isActive else {
            teamOnlyContacts = []
            return
        }
        let projections = (try? context.fetch(FetchDescriptor<SharedContactProjection>())) ?? []
        guard !projections.isEmpty else {
            teamOnlyContacts = []
            return
        }
        let localIDs = Set(
            ((try? context.fetch(FetchDescriptor<Contact>())) ?? []).map(\.id)
        )

        teamOnlyContacts = projections
            .filter { $0.isRemote && !localIDs.contains($0.contactID) && !$0.isWithdrawn }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Change tokens

/// Per-zone server change tokens.
///
/// `UserDefaults` rather than the store: a token is device-local sync
/// bookkeeping, it must never sync anywhere itself, and losing it costs one
/// full refetch rather than any data.
private final class ChangeTokenStore {

    private let defaultsKey = "fieldforge.sharedWarmth.changeTokens"

    func token(for zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        guard let blob = tokens()[key(for: zoneID)] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: blob)
    }

    func setToken(_ token: CKServerChangeToken?, for zoneID: CKRecordZone.ID) {
        var current = tokens()
        if let token, let blob = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            current[key(for: zoneID)] = blob
        } else {
            current.removeValue(forKey: key(for: zoneID))
        }
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func tokens() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private func key(for zoneID: CKRecordZone.ID) -> String {
        "\(zoneID.ownerName)|\(zoneID.zoneName)"
    }
}

// MARK: - Batching

extension Array {
    /// CloudKit rejects oversized modify operations, so every push is chunked.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
