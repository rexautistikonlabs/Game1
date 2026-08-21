//
//  FieldForgeApp.swift
//  FieldForge
//
//  The entry point.
//
//  Launch is deliberately dull: open the store, build the environment, show the
//  UI. Everything that could be slow — StoreKit, iCloud status, the outbox,
//  notification reconciliation — happens in a task after first paint, because
//  the app's core promise is that it opens instantly and works with no network,
//  and a launch that waits on a server breaks both halves of that.
//

import SwiftData
import SwiftUI

@main
struct FieldForgeApp: App {

    /// Built once, here, and never rebuilt. `@State` on the App type is the
    /// supported way to own a reference for the process lifetime.
    @State private var environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Whether CloudKit is attached has to be decided before the container
        // exists, so it comes from the cached entitlement. Asking StoreKit here
        // would block launch on the network, which is exactly what this app
        // must never do.
        let cachedEntitlements = MainActor.assumeIsolated { Entitlements() }
        let shouldSync = MainActor.assumeIsolated {
            SyncEngine.shouldAttachCloudKit(
                isProEnabled: cachedEntitlements.isPro,
                isSharingEnabled: cachedEntitlements.isTeamSharingEnabled
            )
        }

        let environment = MainActor.assumeIsolated {
            let opened = Persistence.open(cloudKitEnabled: shouldSync)
            return AppEnvironment(container: opened.container, persistenceMode: opened.mode)
        }
        _environment = State(initialValue: environment)

        AppLog.app.info("Launched (sync: \(shouldSync, privacy: .public))")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appEnvironment, environment)
                .modelContainer(environment.container)
                .task {
                    await environment.performLaunchTasks()
                }
                // Draining on foreground catches what the reachability monitor
                // cannot: the phone was offline, the app was suspended, and
                // connectivity came back while it was asleep.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await environment.outbox.drain() }
                }
        }
    }
}
