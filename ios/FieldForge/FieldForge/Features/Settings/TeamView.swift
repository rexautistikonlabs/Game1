//
//  TeamView.swift
//  FieldForge
//
//  Shared organizational memory: set it up, invite people, and — above all —
//  see exactly what leaves this iPhone.
//
//  The disclosure section is the most important part of this screen. Asking
//  someone to share donor relationships is asking for real trust, and the only
//  honest way to do it is to show the actual payload side by side with what is
//  withheld. So the screen lists both, generated from the same code that builds
//  the record rather than from a marketing description of it.
//

import CloudKit
import SwiftData
import SwiftUI

struct TeamView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<Contact> { $0.isArchived == false },
        sort: \Contact.nameSortKey
    )
    private var contacts: [Contact]
    @Query(sort: \SharedContactProjection.updatedAt, order: .reverse)
    private var projections: [SharedContactProjection]

    @State private var isPresentingSharingSheet = false
    @State private var activeShare: CKShare?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var teamName = ""
    @State private var isConfirmingStop = false
    @State private var isPresentingDisclosure = false

    private var service: SharedWarmthService { app.sharedWarmth }

    var body: some View {
        List {
            statusSection

            if app.entitlements.isEnabled(.sharedTeamMemory) {
                switch service.state {
                case .off, .notSetUp:
                    setUpSection
                case .owner, .participant:
                    activeSection
                    sharedContactsSection
                    teamOnlySection
                    notYetSection
                case .unavailable(let reason):
                    Section {
                        InlineBanner(kind: .caution, message: reason)
                    }
                    setUpSection
                }
            } else {
                Section {
                    LockedFeatureRow(feature: .sharedTeamMemory)
                }
            }

            disclosureSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Team")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.refreshState(isEnabled: app.entitlements.isSharingActive)
            if teamName.isEmpty {
                teamName = app.activeOrganization()?.name.trimmedOrNil ?? "Our team"
            }
        }
        .refreshable { await service.sync() }
        .sheet(isPresented: $isPresentingSharingSheet) {
            if let activeShare {
                CloudSharingView(
                    share: activeShare,
                    container: CKContainer(identifier: "iCloud.org.example.fieldforge"),
                    teamName: teamName,
                    onSaved: {
                        isPresentingSharingSheet = false
                        Task {
                            await service.refreshState(isEnabled: true)
                            await service.sync()
                        }
                    },
                    onStoppedSharing: {
                        isPresentingSharingSheet = false
                        Task { await service.refreshState(isEnabled: true) }
                    },
                    onFailed: { error in
                        isPresentingSharingSheet = false
                        errorMessage = error.localizedDescription
                    }
                )
            }
        }
        .confirmationDialog(
            "Stop sharing with the team?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop sharing", role: .destructive) {
                Task { await stopSharing() }
            }
            Button("Keep sharing", role: .cancel) {}
        } message: {
            Text("Teammates lose access to the shared warmth records. Your own contacts, visits, gifts and documents all stay exactly as they are on this iPhone.")
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack {
                Label {
                    Text(service.state.description)
                } icon: {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusTint)
                }
                Spacer()
                if service.isSyncing {
                    ProgressView()
                }
            }

            if service.pendingUploadCount > 0 {
                LabeledContent("Waiting to sync") {
                    Text("\(service.pendingUploadCount)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.caution)
                }
            }

            if let syncedAt = service.lastSyncedAt {
                LabeledContent("Last synced") {
                    Text(syncedAt.formatted(.relative(presentation: .named)))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if !app.reachability.isOnline, service.state.isActive {
                Label(
                    "Offline. Ratings and notes are saving locally and will sync themselves.",
                    systemImage: "wifi.slash"
                )
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
            }

            if let message = errorMessage ?? service.lastErrorDescription {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Type.caption)
                    .foregroundStyle(Palette.caution)
            }
        } header: {
            Text("Status")
        }
    }

    private var statusSymbol: String {
        switch service.state {
        case .off: return "person.slash"
        case .notSetUp: return "person.2.badge.plus"
        case .owner: return "person.2.fill"
        case .participant: return "person.2.circle.fill"
        case .unavailable: return "exclamationmark.icloud"
        }
    }

    private var statusTint: Color {
        switch service.state {
        case .owner, .participant: return Palette.positive
        case .unavailable: return Palette.caution
        case .off, .notSetUp: return Palette.textSecondary
        }
    }

    // MARK: Set up

    private var setUpSection: some View {
        Section {
            TextField("Team name", text: $teamName)
                .textInputAutocapitalization(.words)

            Button {
                Task { await createShare() }
            } label: {
                HStack {
                    Label("Set up team sharing", systemImage: "person.2.badge.plus")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking || teamName.trimmedOrNil == nil || !app.reachability.isOnline)

            if !app.reachability.isOnline {
                Label("Setting up a team needs a connection. Everything else works offline.", systemImage: "wifi.slash")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Set up")
        } footer: {
            Text("Creates a private shared area in your iCloud and gives you a link to invite your colleagues. Only people you invite can see it.")
        }
    }

    // MARK: Active

    private var activeSection: some View {
        Section {
            if case .owner = service.state {
                Button {
                    Task { await presentSharingSheet() }
                } label: {
                    Label("Invite or manage teammates", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(isWorking)
            }

            Button {
                Task { await service.sync() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(service.isSyncing || !app.reachability.isOnline)

            Button {
                service.projectAll(staffDisplayName: app.staffDisplayName)
                Task { await service.sync() }
            } label: {
                Label("Share my whole route", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(sharedContacts.isEmpty && contacts.isEmpty)

            if case .owner = service.state {
                Button(role: .destructive) {
                    isConfirmingStop = true
                } label: {
                    Label("Stop sharing", systemImage: "person.2.slash")
                }
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text("“Share my whole route” projects every contact you have already marked as shared. Contacts you have not marked stay private.")
        }
    }

    /// What the team feature does not do yet.
    ///
    /// Stated on the screen rather than only in a changelog: a coordinator
    /// deciding whether to move their volunteers onto this needs to know what
    /// is missing before they commit, not after.
    private var notYetSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assigning follow-ups to a teammate")
                        .font(Type.body)
                    Text("Warmth, notes and giving history sync today. Handing a specific follow-up to a named colleague needs the reminder itself to travel, which is not built yet — so the control is not shown rather than being shown and doing nothing.")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "hourglass")
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Not yet")
        }
    }

    // MARK: What is shared

    private var sharedContacts: [Contact] {
        contacts.filter { $0.isSharedWithTeam && !$0.isArchived }
    }

    private var sharedContactsSection: some View {
        Section {
            if sharedContacts.isEmpty {
                Text("Nothing shared yet. Turn on sharing for a contact from their record, or use “Share my whole route”.")
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(sharedContacts.prefix(20)) { contact in
                    HStack(spacing: Space.md) {
                        WarmthBadge(warmth: contact.warmth, showsLabel: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.displayName)
                                .font(Type.body)
                            if let projection = projection(for: contact.id) {
                                Text(projection.needsUpload ? "Waiting to sync" : "Synced")
                                    .font(Type.caption)
                                    .foregroundStyle(projection.needsUpload ? Palette.caution : Palette.textTertiary)
                            } else {
                                Text("Not projected yet")
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        if contact.privateNotes.trimmedOrNil != nil {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(Palette.textTertiary)
                                .accessibilityLabel("Has private notes, which stay on this iPhone")
                        }
                    }
                }
                if sharedContacts.count > 20 {
                    Text("and \(sharedContacts.count - 20) more")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        } header: {
            Text("You are sharing \(sharedContacts.count)")
        }
    }

    private func projection(for contactID: UUID) -> SharedContactProjection? {
        projections.first { $0.contactID == contactID }
    }

    // MARK: What the team knows that you do not

    private var teamOnly: [SharedContactProjection] {
        service.teamOnlyContacts
    }

    @ViewBuilder
    private var teamOnlySection: some View {
        let records = teamOnly
        if !records.isEmpty {
            Section {
                ForEach(records.prefix(15)) { projection in
                    HStack(spacing: Space.md) {
                        WarmthBadge(warmth: projection.warmth, showsLabel: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(projection.displayName)
                                .font(Type.body)
                            Text(teamOnlySubtitle(projection))
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if projection.giftCount > 0 {
                            Text(projection.lifetimeGiving.formattedCompact)
                                .font(Type.caption.weight(.semibold))
                                .foregroundStyle(Palette.positive)
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("From your teammates")
            } footer: {
                Text("Businesses your colleagues have already visited. This is the list that stops an organization knocking on its own doors twice.")
            }
        }
    }

    private func teamOnlySubtitle(_ projection: SharedContactProjection) -> String {
        var parts: [String] = []
        if let subtitle = projection.subtitleLine.trimmedOrNil { parts.append(subtitle) }
        if let by = projection.lastUpdatedByDisplayName.trimmedOrNil { parts.append("via \(by)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Disclosure

    /// Generated from the same code that builds the CloudKit record, so this
    /// list cannot drift away from what is actually sent.
    private var disclosureSection: some View {
        Section {
            DisclosureGroup("Exactly what is shared", isExpanded: $isPresentingDisclosure) {
                VStack(alignment: .leading, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Label("Leaves this iPhone", systemImage: "arrow.up.circle.fill")
                            .font(Type.label)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.caution)
                        ForEach(Self.disclosedFieldNames, id: \.self) { name in
                            Text("· \(name)")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textPrimary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: Space.xs) {
                        Label("Never leaves this iPhone", systemImage: "lock.fill")
                            .font(Type.label)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.positive)
                        ForEach(Self.withheldCategories, id: \.self) { item in
                            Text("· \(item)")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textPrimary)
                        }
                    }
                }
                .padding(.top, Space.sm)
            }
            .tint(Palette.brand)
        } footer: {
            Text("The list above is generated from the code that builds the shared record, not written by hand, so it cannot drift out of date.")
        }
    }

    /// Every shared field, in plain language, de-duplicated and in the record's
    /// own order.
    ///
    /// Derived from `Key.all` rather than hand-written, so a new field added to
    /// the projection appears here automatically — that is the property that
    /// keeps this list honest. Deduplicated because several keys describe one
    /// human-visible thing: latitude and longitude are both "the map pin".
    static var disclosedFieldNames: [String] {
        var seen = Set<String>()
        return SharedContactProjection.Key.all.compactMap { key in
            let name = friendlyFieldName(key)
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// Turns a record key into something a person can read.
    static func friendlyFieldName(_ key: String) -> String {
        switch key {
        case SharedContactProjection.Key.contactID: return "An anonymous record identifier"
        case SharedContactProjection.Key.displayName: return "The contact's name"
        case SharedContactProjection.Key.subtitleLine: return "The detail line under the name"
        case SharedContactProjection.Key.kind: return "Whether it is a business, person or foundation"
        case SharedContactProjection.Key.warmth: return "The warmth rating"
        case SharedContactProjection.Key.contactWindow: return "The best time of day to catch them"
        case SharedContactProjection.Key.isDoNotContact: return "Whether they asked not to be contacted"
        case SharedContactProjection.Key.sharedNotes: return "Notes you wrote for the team"
        case SharedContactProjection.Key.tags: return "Tags"
        case SharedContactProjection.Key.latitude, SharedContactProjection.Key.longitude:
            return "The map pin"
        case SharedContactProjection.Key.lifetimeGivingMinorUnits, SharedContactProjection.Key.currencyCode:
            return "Lifetime giving total"
        case SharedContactProjection.Key.giftCount: return "How many gifts"
        case SharedContactProjection.Key.visitCount: return "How many visits"
        case SharedContactProjection.Key.lastVisitAt: return "When they were last visited"
        case SharedContactProjection.Key.lastGiftAt: return "When they last gave"
        case SharedContactProjection.Key.firstGiftAt: return "When they first gave"
        case SharedContactProjection.Key.lastUpdatedByDisplayName: return "Which teammate updated it"
        case SharedContactProjection.Key.updatedAt: return "When it was updated"
        default: return key
        }
    }

    /// Deduplicated, because latitude/longitude and the two money fields each
    /// map to one human-readable line.
    static var withheldCategories: [String] {
        [
            "Your private notes on a contact",
            "Your private notes on a visit",
            "Phone numbers, email addresses and street addresses",
            "Payment details, card descriptions and transaction IDs",
            "Signatures and issued documents",
            "Photos, in-kind item pictures and voice notes",
        ]
    }

    // MARK: Actions

    private func createShare() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await service.createTeamShare(teamName: teamName)
            activeShare = result.share
            service.projectAll(staffDisplayName: app.staffDisplayName)
            isPresentingSharingSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentSharingSheet() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if let share = try await service.existingShare() {
                activeShare = share
                isPresentingSharingSheet = true
            } else {
                await createShare()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopSharing() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.stopSharing()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Team") {
    NavigationStack { TeamView() }
        .environment(\.appEnvironment, AppEnvironment.preview(tier: .team))
        .modelContainer(Persistence.previewContainer())
}
