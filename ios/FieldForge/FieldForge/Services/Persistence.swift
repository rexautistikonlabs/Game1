//
//  Persistence.swift
//  FieldForge
//
//  The SwiftData container, and the recovery path for when it will not open.
//
//  A field app that shows a blank screen because a migration failed is worse
//  than useless — the staffer is standing in front of a donor. So the container
//  is built in three escalating attempts, and the app always ends up with
//  something it can write to.
//

import Foundation
import SwiftData

enum Persistence {

    // MARK: - Two stores, on purpose
    //
    // The app keeps private data and shareable data in physically separate
    // store files, each with its own `ModelConfiguration`. That is the
    // structural half of the promise that `privateNotes` never leaves the
    // device: the bytes that sync and the bytes that must not sync are
    // different files on disk, and the syncing code only ever opens one of
    // them. See `SharedContactProjection` for the other three mechanisms.

    /// Everything private to this staffer. Never targeted by the sharing code.
    static let privateSchema = Schema([
        Organization.self,
        Contact.self,
        Visit.self,
        Gift.self,
        GeneratedDocument.self,
        DocumentAuditEntry.self,
        FollowUp.self,
        Attachment.self,
        OutboxItem.self,
        OpenDoorListing.self,
        LetterTemplate.self,
        InKindNeed.self,
        InKindOffer.self,
        CrewEvent.self,
        CourtesyPing.self,
    ])

    /// Narrow projections the team (and, later, courtesy network) may see.
    static let sharedSchema = Schema([
        SharedContactProjection.self,
        SharedCourtesyProjection.self,
    ])

    /// Both, for building the container. A single `ModelContext` can read
    /// across configurations, which is what lets the contact detail screen show
    /// a teammate's view beside the local record without a second context.
    static let schema = Schema([
        Organization.self,
        Contact.self,
        Visit.self,
        Gift.self,
        GeneratedDocument.self,
        DocumentAuditEntry.self,
        FollowUp.self,
        Attachment.self,
        OutboxItem.self,
        OpenDoorListing.self,
        LetterTemplate.self,
        InKindNeed.self,
        InKindOffer.self,
        CrewEvent.self,
        CourtesyPing.self,
        SharedContactProjection.self,
        SharedCourtesyProjection.self,
    ])

    /// How the container was actually opened, so the UI can be honest about it.
    enum Mode {
        /// Normal: local store, syncing to the private CloudKit database.
        case synced
        /// Local only — free tier, no iCloud account, or sync turned off.
        case localOnly
        /// The store would not open and was moved aside. Data from before is in
        /// `recoveredStoreURL`; the app is usable and the user is told.
        case recoveredAfterFailure(recoveredStoreURL: URL?)
        /// Last resort: memory only. Nothing persists. Loudly surfaced.
        case ephemeral

        var isDegraded: Bool {
            switch self {
            case .synced, .localOnly: return false
            case .recoveredAfterFailure, .ephemeral: return true
            }
        }
    }

    /// Result of opening the store.
    struct Opened {
        let container: ModelContainer
        let mode: Mode
    }

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "FieldForge.store")
    }

    /// The projection store. A separate file so that "what syncs" and "what
    /// never syncs" are not merely different rows in one database.
    private static var sharedStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "FieldForge-Shared.store")
    }

    /// The projection configuration. `cloudKitDatabase: .none` deliberately:
    /// this store is moved by `SharedWarmthService` over a CloudKit *shared*
    /// zone, which SwiftData mirroring cannot target. Letting SwiftData also
    /// mirror it would duplicate every record into the private database.
    static var sharedWarmthConfiguration: ModelConfiguration {
        ModelConfiguration(
            "SharedWarmth",
            schema: sharedSchema,
            url: sharedStoreURL,
            cloudKitDatabase: .none
        )
    }

    /// Opens the store, falling back rather than trapping.
    ///
    /// - Parameter cloudKitEnabled: pass the live Pro entitlement. CloudKit is
    ///   only attached for organizations sharing team memory; a solo free-tier
    ///   user gets a purely local store and never sees an iCloud prompt.
    @MainActor
    static func open(cloudKitEnabled: Bool) -> Opened? {
        // 1. The intended configuration: the private store, optionally mirrored
        //    to the user's own private CloudKit database, plus the projection
        //    store which is never mirrored by SwiftData.
        let primary = ModelConfiguration(
            "Private",
            schema: privateSchema,
            url: storeURL,
            cloudKitDatabase: cloudKitEnabled
                ? .private("iCloud.org.rexautistikonlabs.fieldforge")
                : .none
        )
        if let container = try? ModelContainer(
            for: schema,
            configurations: primary, sharedWarmthConfiguration
        ) {
            AppLog.persistence.info("Store opened (cloudKit: \(cloudKitEnabled, privacy: .public))")
            return Opened(container: container, mode: cloudKitEnabled ? .synced : .localOnly)
        }

        // 2. CloudKit itself is a common cause — a schema not yet deployed to
        //    production, or an account in a strange state. Retry locally before
        //    concluding the data is the problem.
        if cloudKitEnabled {
            let localOnly = ModelConfiguration("Private", schema: privateSchema, url: storeURL, cloudKitDatabase: .none)
            if let container = try? ModelContainer(
                for: schema,
                configurations: localOnly, sharedWarmthConfiguration
            ) {
                AppLog.persistence.warning("CloudKit unavailable; opened store local-only")
                return Opened(container: container, mode: .localOnly)
            }
        }

        // 3. The store is genuinely unopenable. Move it aside — never delete
        //    it — and start clean so the app works right now. The old file is
        //    surfaced in Settings so it can be sent in for recovery.
        let recovered = moveStoreAside()
        let fresh = ModelConfiguration("Private", schema: privateSchema, url: storeURL, cloudKitDatabase: .none)
        if let container = try? ModelContainer(
            for: schema,
            configurations: fresh, sharedWarmthConfiguration
        ) {
            AppLog.persistence.error("Store unopenable; started fresh, previous file preserved")
            return Opened(container: container, mode: .recoveredAfterFailure(recoveredStoreURL: recovered))
        }

        // 4. Nothing on disk works — a full disk, most likely. Run in memory so
        //    the staffer can still produce the receipt in front of them, and
        //    warn loudly that it will not survive. Never trap: a white screen
        //    at launch is worse than ephemeral storage.
        let memory = inMemoryConfiguration
        if let container = try? ModelContainer(for: schema, configurations: memory) {
            AppLog.persistence.critical("Running in memory only — data will not persist")
            return Opened(container: container, mode: .ephemeral)
        }

        AppLog.persistence.critical("Could not open any store, including in-memory")
        return nil
    }

    /// Renames the store (and its -wal/-shm siblings) with a timestamp.
    private static func moveStoreAside() -> URL? {
        let manager = FileManager.default
        let stamp = DateFormatter.fileStamp.string(from: .now)
        let destination = URL.applicationSupportDirectory
            .appending(path: "FieldForge-unopenable-\(stamp).store")
        do {
            guard manager.fileExists(atPath: storeURL.path) else { return nil }
            try manager.moveItem(at: storeURL, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: storeURL.path + suffix)
                if manager.fileExists(atPath: sidecar.path) {
                    try? manager.moveItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: destination.path + suffix)
                    )
                }
            }
            // The projection store goes with it. A fresh private store beside a
            // stale projection store would show team records for contacts that
            // no longer exist locally, which reads as data corruption.
            if manager.fileExists(atPath: sharedStoreURL.path) {
                let sharedDestination = URL.applicationSupportDirectory
                    .appending(path: "FieldForge-Shared-unopenable-\(stamp).store")
                try? manager.moveItem(at: sharedStoreURL, to: sharedDestination)
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: sharedStoreURL.path + suffix)
                    if manager.fileExists(atPath: sidecar.path) {
                        try? manager.moveItem(
                            at: sidecar,
                            to: URL(fileURLWithPath: sharedDestination.path + suffix)
                        )
                    }
                }
            }
            return destination
        } catch {
            AppLog.persistence.error("Could not move damaged store aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Whether to attach CloudKit

    /// Whether the *private* store should be mirrored to the user's own private
    /// CloudKit database.
    ///
    /// This is about one person's own devices — iPhone and iPad staying in step —
    /// and is a different question from whether they share anything with
    /// teammates. It used to be tied to the team-sharing switch, which meant a
    /// paying user who turned team sharing off also silently lost their own iPad
    /// sync. That was a bug in intent, so the two are now independent:
    ///
    ///   * private mirror  — Pro, full stop.
    ///   * team sharing    — Pro *and* the user's explicit opt-in, and it runs
    ///                       over a shared zone (`SharedWarmthService`), not
    ///                       through SwiftData at all.
    ///
    /// The free tier stays deliberately local-only: no iCloud prompt, no
    /// account, no surprise. That is a promise, not a limitation to work around.
    ///
    /// Read once, at launch, before the container exists — which is why it takes
    /// plain booleans rather than reaching for `Entitlements`.
    static func shouldMirrorToPrivateCloudKit(isProEnabled: Bool) -> Bool {
        isProEnabled
    }

    /// Launch never attaches CloudKit. Team sharing creates a container later.
    static let attachesCloudKitAtLaunch = false

    /// In-memory, never CloudKit. Previews, tests, and the last-resort
    /// ephemeral fallback all use this so a CloudKit-entitled build does not
    /// try to validate a development schema against `/dev/null`.
    static var inMemoryConfiguration: ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
    }

    /// In-memory container for SwiftUI previews and unit tests only.
    /// Never called from `FieldForgeApp` or `EnvironmentKey.defaultValue`.
    @MainActor
    static func previewContainer(seeded: Bool = true) -> ModelContainer {
        do {
            let container = try ModelContainer(for: schema, configurations: inMemoryConfiguration)
            if seeded {
                SeedData.populate(context: container.mainContext)
            }
            return container
        } catch {
            AppLog.persistence.error(
                "Preview/test container failed: \(error.localizedDescription, privacy: .public)"
            )
            preconditionFailure("Preview/test store could not be created: \(error)")
        }
    }
}

extension DateFormatter {
    /// "2026-08-21-134502" — no colons, so it is safe inside a filename on
    /// every filesystem the app might be copied to.
    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
