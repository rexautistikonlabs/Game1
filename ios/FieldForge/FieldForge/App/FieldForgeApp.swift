//
//  FieldForgeApp.swift
//  FieldForge
//
//  The entry point.
//
//  First frame is Today (a smoke shell). Stripe Terminal, connection tokens,
//  and Tap to Pay are not touched here. Persistence and AppEnvironment attach
//  after that paint. If they fail, the smoke Today stays with an error — never
//  a white screen.
//

import SwiftData
import SwiftUI

@main
struct FieldForgeApp: App {

    init() {
        // Before the first frame. A dirty collect must not keep Today blank.
        TapToPaySession.recoverIfDirty()
    }

    var body: some Scene {
        WindowGroup {
            BootView()
        }
    }
}

/// First frame is Today. Never waits on Terminal. If storage fails, smoke Today stays.
private struct BootView: View {

    @State private var session = BootSession.start()

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let environment = session.environment {
                RootView()
                    .environment(\.appEnvironment, environment)
                    .modelContainer(environment.container)
                    .task {
                        await environment.performLaunchTasks()
                    }
                    .onOpenURL { url in
                        guard let outcome = StripeConnectOAuth().handleIncomingURL(url) else { return }
                        if case .connected(let accountID) = outcome {
                            _ = StripeConnectAccount.shared.connect(accountID: accountID)
                            environment.payments.reloadProcessor()
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await environment.outbox.drain() }
                    }
            } else {
                LaunchSmokeToday(error: session.error)
            }
        }
    }
}

/// Opens local storage only. Stripe Terminal is not loaded here.
private struct BootSession {
    var environment: AppEnvironment?
    var error: String?

    @MainActor
    static func start() -> BootSession {
        TapToPaySession.recoverIfDirty()
        if let existing = AppEnvironment.installed {
            return BootSession(environment: existing)
        }
        guard let opened = Persistence.open(cloudKitEnabled: false) else {
            return BootSession(
                error: "FieldForge could not open storage. Close the app and reopen, or restart this iPhone."
            )
        }
        let env = AppEnvironment(container: opened.container, persistenceMode: opened.mode)
        AppEnvironment.install(env)
        return BootSession(environment: env)
    }
}
