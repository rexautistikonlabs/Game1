//
//  AppEnvironment.swift
//  FieldForge
//
//  The dependency container. One observable object holding the long-lived
//  services, injected once at the root and read through `@Environment`.
//
//  Why a container rather than singletons: the services here have real
//  initialisation order (the outbox needs the container and reachability; the
//  store service needs entitlements), they need to be replaceable in previews,
//  and a location manager that outlives a view is a battery bug waiting to
//  happen. One owner, created once, torn down never.
//

import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {

    // MARK: Services

    let reachability: Reachability
    let location: LocationService
    let transcriber: SpeechTranscriber
    let entitlements: Entitlements
    let store: StoreService
    let sharedWarmth: SharedWarmthService
    let payments: PaymentCoordinator
    let outbox: OutboxProcessor
    let route: RoutePlanner

    /// How the store opened. Surfaced in Settings when it is degraded.
    let persistenceMode: Persistence.Mode

    let container: ModelContainer

    // MARK: Session state

    /// The organization currently being worked on. Almost always the only one.
    /// Persisted so a fiscal sponsor with three orgs does not have to re-pick
    /// on every launch.
    var activeOrganizationID: UUID? {
        didSet {
            UserDefaults.standard.set(activeOrganizationID?.uuidString, forKey: Self.activeOrgKey)
        }
    }

    /// Display name used to attribute visits and notes in shared memory. Not an
    /// identity — just "who wrote this", so a teammate knows who to ask.
    var staffDisplayName: String {
        didSet { UserDefaults.standard.set(staffDisplayName, forKey: Self.staffNameKey) }
    }

    /// Set when something needs saying at the top of the app: a degraded store,
    /// a simulated payment gateway, a queued outbox.
    var globalNotice: String?

    private static let activeOrgKey = "fieldforge.activeOrganizationID"
    private static let staffNameKey = "fieldforge.staffDisplayName"

    // MARK: Init

    init(container: ModelContainer, persistenceMode: Persistence.Mode) {
        self.container = container
        self.persistenceMode = persistenceMode

        let reachability = Reachability()
        self.reachability = reachability
        self.location = LocationService()
        self.transcriber = SpeechTranscriber()

        let entitlements = Entitlements()
        self.entitlements = entitlements
        self.store = StoreService(entitlements: entitlements)

        self.sharedWarmth = SharedWarmthService(
            modelContainer: container,
            reachability: reachability
        )
        self.payments = PaymentCoordinator(reachability: reachability)
        self.outbox = OutboxProcessor(container: container, reachability: reachability)
        self.route = RoutePlanner()

        let storedOrgID = UserDefaults.standard.string(forKey: Self.activeOrgKey)
        self.activeOrganizationID = storedOrgID.flatMap(UUID.init(uuidString:))
        self.staffDisplayName = UserDefaults.standard.string(forKey: Self.staffNameKey) ?? ""

        if persistenceMode.isDegraded {
            globalNotice = Self.notice(for: persistenceMode)
        }
    }

    /// Work that has to happen once, at launch, but must not block first paint.
    func performLaunchTasks() async {
        NotificationScheduler.registerCategories()
        SeedData.bootstrapIfNeeded(context: container.mainContext)
        StatusMigration.migrateIfNeeded(context: container.mainContext)
        resolveActiveOrganizationIfNeeded()

        outbox.refreshCounts()

        async let entitlementRefresh: Void = store.refreshEntitlements()
        async let productLoad: Void = store.loadProducts()
        _ = await (entitlementRefresh, productLoad)

        // Never open CloudKit at launch. Sharing creates the container lazily
        // when the Team screen (or an explicit share action) asks for it.
        await sharedWarmth.refreshState(isEnabled: false)

        // Re-read local Stripe settings (UserDefaults + Keychain, not CloudKit)
        // so a backend URL saved last session turns off the SIMULATED label.
        // Fetch the platform pk_ only if this iPhone has none stored.
        await StripePaymentSettings.shared.refreshPublicConfigIfNeeded()
        payments.reloadProcessor()

        // Drain anything left from last time before the staffer notices it is
        // there. If they are offline this is a no-op and costs nothing.
        await outbox.drain()

        await reconcileReminders()
    }

    /// Route start. Does **not** initialise Stripe Terminal — Collect does that.
    func prepareForRoute() async {
        _ = await location.currentLocation()
    }

    // MARK: Organization

    /// The active organization, fetched fresh. Cheap: it is one row, and holding
    /// a model object across the app lifetime invites stale-object bugs.
    func activeOrganization() -> Organization? {
        let context = container.mainContext
        if let id = activeOrganizationID {
            var descriptor = FetchDescriptor<Organization>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let found = try? context.fetch(descriptor).first { return found }
        }
        var fallback = FetchDescriptor<Organization>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        fallback.fetchLimit = 1
        return try? context.fetch(fallback).first
    }

    private func resolveActiveOrganizationIfNeeded() {
        guard activeOrganizationID == nil || activeOrganization() == nil else { return }
        activeOrganizationID = activeOrganization()?.id
    }

    /// True until the organization has enough detail to issue documents. Drives
    /// the setup nudge on Today.
    var needsOrganizationSetup: Bool {
        guard let organization = activeOrganization() else { return true }
        return !organization.isReadyToIssueDocuments
    }

    /// ZIP the map, Today, and route prefer. Editable on the organization.
    var focusPostalCode: String {
        PostalCode.normalize(activeOrganization()?.defaultFocusPostalCode ?? "")
            .trimmedOrNil ?? PostalCode.defaultFocus
    }

    func recordCrew(_ action: CrewAction, qualifier: String = "") {
        CrewLedger.record(
            action,
            staffDisplayName: staffDisplayName,
            organization: activeOrganization(),
            qualifier: qualifier,
            context: container.mainContext
        )
        try? container.mainContext.save()
    }

    // MARK: Team projection

    /// Call after any change a teammate should see. Cheap, local, and safe to
    /// call when sharing is off — it simply does nothing.
    ///
    /// One funnel on purpose: if projecting were sprinkled across the call
    /// sites, the first one somebody forgot would silently stop a teammate
    /// seeing a "do not contact" flag.
    func projectToTeam(_ contact: Contact) {
        guard entitlements.isSharingActive, contact.isSharedWithTeam else { return }
        sharedWarmth.project(contact, staffDisplayName: staffDisplayName)
    }

    /// Withdraws a contact from the team without touching the local record.
    func withdrawFromTeam(_ contact: Contact) {
        guard entitlements.isEnabled(.sharedTeamMemory) else { return }
        sharedWarmth.withdraw(contactID: contact.id)
    }

    // MARK: Reminders

    private func reconcileReminders() async {
        let descriptor = FetchDescriptor<FollowUp>(
            predicate: #Predicate { $0.completedAt == nil }
        )
        let followUps = (try? container.mainContext.fetch(descriptor)) ?? []
        await NotificationScheduler.reconcile(followUps: followUps)
        try? container.mainContext.save()
    }

    // MARK: Notices

    private static func notice(for mode: Persistence.Mode) -> String? {
        switch mode {
        case .synced, .localOnly:
            return nil
        case .recoveredAfterFailure:
            return "FieldForge could not open its previous data and started fresh. The old file was kept — see Settings."
        case .ephemeral:
            return "Storage is unavailable, so nothing will be saved after you close the app. Send anything important now."
        }
    }

    // MARK: Live process instance

    /// Installed by `BootView` after the first Today frame. Nil until then so
    /// launch never constructs Terminal or blocks on Persistence in `@State`.
    private static var _installed: AppEnvironment?

    /// Readable from EnvironmentKey without hopping the main actor.
    nonisolated(unsafe) fileprivate static var gate: AppEnvironment?

    static var installed: AppEnvironment? { _installed }

    static func install(_ environment: AppEnvironment) {
        _installed = environment
        gate = environment
    }

    /// The one environment the running app uses once boot succeeds.
    /// Must not create Stripe Terminal. CloudKit stays off.
    static var shared: AppEnvironment {
        if let _installed { return _installed }
        TapToPaySession.recoverIfDirty()
        if let opened = Persistence.open(cloudKitEnabled: false) {
            let env = AppEnvironment(container: opened.container, persistenceMode: opened.mode)
            install(env)
            return env
        }
        if let container = try? ModelContainer(
            for: Persistence.schema,
            configurations: Persistence.inMemoryConfiguration
        ) {
            let env = AppEnvironment(container: container, persistenceMode: .ephemeral)
            install(env)
            return env
        }
        let container = Persistence.previewContainer(seeded: false)
        let env = AppEnvironment(container: container, persistenceMode: .ephemeral)
        install(env)
        return env
    }

    // MARK: Previews

    /// A fully wired environment over an in-memory, seeded store. Every preview
    /// in the project uses this, which is why they all show real data.
    /// Never called from `EnvironmentKey.defaultValue`.
    static func preview(tier: Tier = .free) -> AppEnvironment {
        let container = Persistence.previewContainer()
        let environment = AppEnvironment(container: container, persistenceMode: .localOnly)
        if tier == .team {
            environment.entitlements.apply(tier: .team, validUntil: .now.addingTimeInterval(86_400 * 365))
            environment.entitlements.isTeamSharingEnabled = true
        }
        environment.staffDisplayName = "Maritza"
        environment.activeOrganizationID = environment.activeOrganization()?.id
        return environment
    }
}

// MARK: - Environment plumbing

/// Written out longhand rather than with the `@Entry` macro so the project
/// builds on any Xcode that supports iOS 17, not only the newest one.
///
/// SwiftUI always evaluates `defaultValue` while building the view graph.
/// It must return the live shared instance — no trap, no `preview()`, no
/// second container.
private struct AppEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppEnvironment {
        if let env = AppEnvironment.gate { return env }
        // BootView installs before RootView. Previews inject `.preview()`.
        // Never call Stripe Terminal or assumeIsolated here.
        return AppEnvironment.gate!
    }
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
