//
//  SettingsView.swift
//  FieldForge
//
//  Settings, ordered by how often anyone touches them: the organization and its
//  letterhead first, then who you are, then the team, then the honest technical
//  status of storage and sync at the bottom.
//

import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Query(sort: \Organization.createdAt) private var organizations: [Organization]

    @State private var isPresentingPaywall = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            List {
                organizationSection
                staffSection
                teamSection
                dataSection
                subscriptionSection
                storageSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Settings")
            .sheet(isPresented: $isPresentingPaywall) { PaywallView() }
            .task {
                await app.sharedWarmth.refreshState(isEnabled: app.entitlements.isSharingActive)
            }
        }
    }

    // MARK: Organization

    private var organizationSection: some View {
        Section {
            ForEach(organizations) { organization in
                NavigationLink {
                    OrganizationEditorView(organization: organization)
                } label: {
                    HStack(spacing: Space.md) {
                        logoThumbnail(organization)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(organization.name.trimmedOrNil ?? "Untitled organization")
                                .font(Type.body.weight(.medium))
                            if organization.isReadyToIssueDocuments {
                                Text(organization.einLine.trimmedOrNil ?? "Ready")
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            } else {
                                Label(
                                    "\(organization.missingRequiredBrandingFields.count) thing\(organization.missingRequiredBrandingFields.count == 1 ? "" : "s") still needed",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(Type.caption)
                                .foregroundStyle(Palette.caution)
                            }
                        }
                        Spacer(minLength: 0)
                        if organizations.count > 1, app.activeOrganizationID == organization.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Palette.brand)
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if organizations.count > 1 {
                        Button("Use this") {
                            app.activeOrganizationID = organization.id
                        }
                        .tint(Palette.brand)
                    }
                }
            }

            if app.entitlements.isEnabled(.multipleOrganizations) {
                Button {
                    let organization = Organization()
                    context.insert(organization)
                    try? context.save()
                } label: {
                    Label("Add another organization", systemImage: "plus")
                }
            } else if organizations.count >= 1 {
                LockedFeatureRow(feature: .multipleOrganizations)
            }
        } header: {
            Text("Organization")
        } footer: {
            Text("Everything on your receipts and letters comes from here — the logo, the address, the EIN, and who signs.")
        }
    }

    @ViewBuilder
    private func logoThumbnail(_ organization: Organization) -> some View {
        if let data = organization.logoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(organization.brandColor.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(initials(organization.name))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(organization.brandColor)
                )
        }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    // MARK: Staff

    private var staffSection: some View {
        Section {
            TextField("Your name", text: Binding(
                get: { app.staffDisplayName },
                set: { app.staffDisplayName = $0 }
            ))
            .textInputAutocapitalization(.words)
        } header: {
            Text("You")
        } footer: {
            Text("Used to greet you, and to show teammates who recorded a visit. It is not an account and never leaves your organization.")
        }
    }

    // MARK: Team

    private var teamSection: some View {
        Section {
            NavigationLink {
                TeamView()
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(app.sharedWarmth.state.isActive ? Palette.positive : Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shared warmth")
                            .font(Type.body)
                        Text(app.entitlements.isEnabled(.sharedTeamMemory)
                             ? app.sharedWarmth.state.description
                             : "Part of FieldForge Team")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if app.sharedWarmth.pendingUploadCount > 0 {
                        Text("\(app.sharedWarmth.pendingUploadCount)")
                            .font(Type.caption.weight(.semibold))
                            .foregroundStyle(Palette.caution)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Team")
        } footer: {
            Text("Warmth ratings, giving history and team notes are shared. Private notes on a contact or a visit never leave this iPhone, on any tier.")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            NavigationLink {
                ExportView()
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "tablecells")
                        .foregroundStyle(app.entitlements.isEnabled(.bulkExport) ? Palette.brand : Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Export to CSV")
                            .font(Type.body)
                        Text(app.entitlements.isEnabled(.bulkExport)
                             ? "Contacts, donations and documents"
                             : "Part of FieldForge Team")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Exports are built on this iPhone and never uploaded.")
        }
    }

    // MARK: Subscription

    private var subscriptionSection: some View {
        Section {
            HStack {
                Text("Plan")
                Spacer()
                Text(app.entitlements.tier.displayName)
                    .foregroundStyle(Palette.textSecondary)
            }

            if let validUntil = app.entitlements.validUntil {
                HStack {
                    Text("Renews")
                    Spacer()
                    Text(validUntil.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if !app.entitlements.isPro {
                Button {
                    isPresentingPaywall = true
                } label: {
                    Label("See what Team adds", systemImage: "person.2.badge.key")
                }
            }

            Button {
                Task {
                    isRestoring = true
                    let restored = await app.store.restorePurchases()
                    isRestoring = false
                    restoreMessage = restored
                        ? "Restored. You are on Team."
                        : "No previous purchase was found on this Apple Account."
                }
            } label: {
                HStack {
                    Text("Restore a purchase")
                    if isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRestoring)

            if let restoreMessage {
                Text(restoreMessage)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Subscription")
        } footer: {
            Text("Everything you have already created stays yours and stays usable, whatever happens to a subscription. Documents, contacts and history are never held hostage.")
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            HStack {
                Text("Storage")
                Spacer()
                Text(storageDescription)
                    .foregroundStyle(storageIsHealthy ? Palette.textSecondary : Palette.critical)
            }

            if case .recoveredAfterFailure(let url) = app.persistenceMode, let url {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Your previous data could not be opened and was kept aside rather than deleted.")
                        .font(Type.caption)
                    Text(url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(Palette.textTertiary)
                        .textSelection(.enabled)
                }
            }

            if case .ephemeral = app.persistenceMode {
                Label(
                    "Nothing is being saved to disk. Send anything important out of the app now.",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(Type.caption)
                .foregroundStyle(Palette.critical)
            }

            HStack {
                Text("Connection")
                Spacer()
                Text(app.reachability.statusDescription)
                    .foregroundStyle(Palette.textSecondary)
            }

            if app.outbox.pendingCount > 0 {
                HStack {
                    Text("Waiting to send")
                    Spacer()
                    Text("\(app.outbox.pendingCount)")
                        .foregroundStyle(Palette.caution)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Status")
        }
    }

    private var storageIsHealthy: Bool { !app.persistenceMode.isDegraded }

    private var storageDescription: String {
        switch app.persistenceMode {
        case .synced: return "On this iPhone and iCloud"
        case .localOnly: return "On this iPhone"
        case .recoveredAfterFailure: return "Started fresh"
        case .ephemeral: return "Not saving"
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(versionString)
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
            }

            if PaymentGatewayRegistry.shared.isSimulated {
                Label(
                    "Payments are simulated in this build. Nothing is charged.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Type.caption)
                .foregroundStyle(Palette.critical)
            }
        } header: {
            Text("About")
        } footer: {
            Text("FieldForge is not a tax adviser. The language on its documents follows IRS Publication 1771, but your organization is responsible for what it issues.")
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
