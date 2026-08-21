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

    /// Every model in the store. Adding one here is the only registration step.
    static let schema = Schema([
        Organization.self,
        Contact.self,
        Visit.self,
        Gift.self,
        GeneratedDocument.self,
        FollowUp.self,
        Attachment.self,
        OutboxItem.self,
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

    /// Opens the store, falling back rather than trapping.
    ///
    /// - Parameter cloudKitEnabled: pass the live Pro entitlement. CloudKit is
    ///   only attached for organizations sharing team memory; a solo free-tier
    ///   user gets a purely local store and never sees an iCloud prompt.
    @MainActor
    static func open(cloudKitEnabled: Bool) -> Opened {
        // 1. The intended configuration.
        let primary = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: cloudKitEnabled
                ? .private("iCloud.org.example.fieldforge")
                : .none
        )
        if let container = try? ModelContainer(for: schema, configurations: primary) {
            AppLog.persistence.info("Store opened (cloudKit: \(cloudKitEnabled, privacy: .public))")
            return Opened(container: container, mode: cloudKitEnabled ? .synced : .localOnly)
        }

        // 2. CloudKit itself is a common cause — a schema not yet deployed to
        //    production, or an account in a strange state. Retry locally before
        //    concluding the data is the problem.
        if cloudKitEnabled {
            let localOnly = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            if let container = try? ModelContainer(for: schema, configurations: localOnly) {
                AppLog.persistence.warning("CloudKit unavailable; opened store local-only")
                return Opened(container: container, mode: .localOnly)
            }
        }

        // 3. The store is genuinely unopenable. Move it aside — never delete
        //    it — and start clean so the app works right now. The old file is
        //    surfaced in Settings so it can be sent in for recovery.
        let recovered = moveStoreAside()
        let fresh = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: fresh) {
            AppLog.persistence.error("Store unopenable; started fresh, previous file preserved")
            return Opened(container: container, mode: .recoveredAfterFailure(recoveredStoreURL: recovered))
        }

        // 4. Nothing on disk works — a full disk, most likely. Run in memory so
        //    the staffer can still produce the receipt in front of them, and
        //    warn loudly that it will not survive.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: memory)
            AppLog.persistence.critical("Running in memory only — data will not persist")
            return Opened(container: container, mode: .ephemeral)
        } catch {
            // A container that cannot even be built in memory means the schema
            // is invalid, which is a programmer error and not recoverable.
            fatalError("Schema is invalid: \(error)")
        }
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
            return destination
        } catch {
            AppLog.persistence.error("Could not move damaged store aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// In-memory container for previews and tests, pre-seeded with the sample
    /// organization so every SwiftUI preview in the project renders real data.
    @MainActor
    static func previewContainer(seeded: Bool = true) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Force-try is acceptable here: this path is only reached from previews
        // and tests, and a failure means the schema is wrong.
        let container = try! ModelContainer(for: schema, configurations: configuration)
        if seeded {
            SeedData.populate(context: container.mainContext)
        }
        return container
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
