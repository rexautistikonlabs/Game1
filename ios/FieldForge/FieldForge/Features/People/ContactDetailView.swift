//
//  ContactDetailView.swift
//  FieldForge
//
//  Everything about one relationship on one screen: how to reach them, how it
//  has gone, what they have given, what documents exist, and what is owed next.
//
//  The order is chosen for the moment it is most used — standing outside the
//  building, thirty seconds before knocking. Reach and warmth first, history
//  second, admin last.
//

import SwiftData
import SwiftUI

struct ContactDetailView: View {

    let contact: Contact

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var isPresentingEditor = false
    @State private var isPresentingFollowUp = false
    @State private var scheduledConfirmation: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header
                if contact.isDoNotContact { doNotContactBanner }
                quickActions
                if let scheduledConfirmation {
                    InlineBanner(kind: .positive, message: scheduledConfirmation)
                }
                warmthCard
                teamCard
                if !openFollowUps.isEmpty { followUpsSection }
                givingSection
                visitsSection
                documentsSection
                notesSection
                adminSection
            }
            .padding(.horizontal, Space.screenEdge)
            .padding(.bottom, Space.xxl)
        }
        .background(Palette.background)
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isPresentingEditor = true }
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            ContactEditorView(contact: contact)
        }
        .sheet(isPresented: $isPresentingFollowUp) {
            FollowUpEditorView(contact: contact)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.displayName)
                        .font(Type.screenTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(contact.subtitle)
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Space.sm)
                WarmthBadge(warmth: contact.warmth)
            }

            if !contact.tags.isEmpty {
                TagChips(tags: contact.tags)
            }

            if contact.source.needsHumanReview {
                Label("Some details were read from a photo", systemImage: "camera.metering.spot")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.top, Space.sm)
    }

    private var doNotContactBanner: some View {
        InlineBanner(
            kind: .critical,
            message: contact.doNotContactReason.trimmedOrNil
                ?? "This contact asked not to be contacted again. Reminders are off.",
            actionTitle: "Allow again"
        ) {
            contact.isDoNotContact = false
            contact.doNotContactReason = ""
            contact.recomputeRollups()
            try? context.save()
            app.projectToTeam(contact)
        }
    }

    // MARK: Quick actions

    /// Call, text, email, directions — one tap each, and hidden entirely when
    /// the contact has asked not to be contacted.
    private var quickActions: some View {
        HStack(spacing: Space.sm) {
            if !contact.isDoNotContact {
                if let url = ContactActions.callURL(for: contact.phone) {
                    QuickActionButton(symbol: "phone.fill", label: "Call") { openURL(url) }
                }
                if let url = ContactActions.messageURL(for: contact.phone) {
                    QuickActionButton(symbol: "message.fill", label: "Text") { openURL(url) }
                }
                if let url = ContactActions.mailURL(for: contact.email, subject: emailSubject) {
                    QuickActionButton(symbol: "envelope.fill", label: "Email") { openURL(url) }
                }
            }
            if let url = ContactActions.mapsURL(for: contact) {
                QuickActionButton(symbol: "map.fill", label: "Directions") { openURL(url) }
            }
            if !contact.isDoNotContact {
                QuickActionButton(symbol: "calendar.badge.plus", label: "Schedule") {
                    scheduleVisit()
                }
            }
            QuickActionButton(symbol: "bell.badge.fill", label: "Remind") {
                isPresentingFollowUp = true
            }
        }
    }

    /// One tap creates a visit reminder at the contact's own best time of day,
    /// which is the whole point of recording a contact window in the first
    /// place. No sheet, no date picker — the staffer can adjust it afterwards
    /// if they care, and most of the time they will not need to.
    private func scheduleVisit() {
        let calendar = Calendar.current
        // A week out by default, then snapped to the hour they are catchable.
        let base = calendar.date(byAdding: .day, value: 7, to: .now) ?? .now
        let startOfDay = calendar.startOfDay(for: base)
        let due = NotificationScheduler.normalizedFireDate(
            for: startOfDay,
            window: contact.contactWindow
        )

        let followUp = FollowUp(
            kind: .visitAgain,
            dueAt: due,
            note: contact.sharedNotes.trimmedOrNil ?? ""
        )
        followUp.contact = contact
        followUp.isSharedWithTeam = app.entitlements.isSharingActive
        followUp.assignedToDisplayName = app.staffDisplayName
        context.insert(followUp)
        try? context.save()

        Task { await NotificationScheduler.schedule(followUp) }
        Haptics.success()
        scheduledConfirmation = "Visit reminder set for \(due.formatted(date: .abbreviated, time: .shortened))."
    }

    private var emailSubject: String {
        guard let organization = app.activeOrganization() else { return "Hello" }
        return "Following up from \(organization.name)"
    }

    // MARK: Warmth

    private var warmthCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "What we know")

            VStack(spacing: Space.xs) {
                if contact.contactWindow != .unknown {
                    LabeledRow(label: "Best time", value: contact.contactWindow.label, systemImage: "sun.max")
                }
                if let last = contact.lastVisitAt {
                    LabeledRow(
                        label: "Last visit",
                        value: last.formatted(.relative(presentation: .named)),
                        systemImage: "figure.walk"
                    )
                } else {
                    LabeledRow(label: "Last visit", value: "Never", systemImage: "figure.walk")
                }
                LabeledRow(label: "Visits", value: "\(contact.visitCount)", systemImage: "number")
                if contact.isSharedWithTeam {
                    LabeledRow(
                        label: "Shared",
                        value: contact.createdByDisplayName.trimmedOrNil.map { "Added by \($0)" } ?? "With the team",
                        systemImage: "person.2.fill"
                    )
                }
            }
            .cardSurface(padding: Space.sm)
        }
    }

    // MARK: What the team knows

    /// A teammate's view of this contact, when one has arrived. This is the
    /// payoff of Shared Warmth on the screen where it matters most — the one
    /// open thirty seconds before knocking.
    @ViewBuilder
    private var teamCard: some View {
        if let projection = app.sharedWarmth.remoteProjection(for: contact.id) {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(
                    title: "Your team's read",
                    subtitle: projection.lastUpdatedByDisplayName.trimmedOrNil
                        .map { "Last updated by \($0)" }
                )

                VStack(spacing: Space.xs) {
                    LabeledRow(
                        label: "Their warmth",
                        value: projection.warmth.label,
                        systemImage: projection.warmth.symbolName
                    )
                    if projection.contactWindow != .unknown {
                        LabeledRow(
                            label: "Best time",
                            value: projection.contactWindow.label,
                            systemImage: "clock"
                        )
                    }
                    if projection.giftCount > 0 {
                        LabeledRow(
                            label: "Team-wide giving",
                            value: "\(projection.lifetimeGiving.formatted) over \(projection.giftCount)",
                            systemImage: "gift",
                            isMonospaced: true
                        )
                    }
                    if let notes = projection.sharedNotes.trimmedOrNil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Their notes")
                                .font(Type.label)
                                .textCase(.uppercase)
                                .foregroundStyle(Palette.textSecondary)
                            Text(notes)
                                .font(Type.secondary)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .cardSurface(padding: Space.sm)

                if projection.warmth != contact.warmth, projection.warmth != .unrated {
                    InlineBanner(
                        kind: .info,
                        message: "A teammate rated them \(projection.warmth.label.lowercased()) — your own reading is \(contact.warmth.label.lowercased())."
                    )
                }
            }
        }
    }

    // MARK: Follow-ups

    private var openFollowUps: [FollowUp] {
        (contact.followUps ?? [])
            .filter { !$0.isComplete }
            .sorted { $0.dueAt < $1.dueAt }
    }

    private var followUpsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Owed", actionTitle: "Add") { isPresentingFollowUp = true }
            ForEach(openFollowUps) { followUp in
                FollowUpRow(followUp: followUp)
            }
        }
    }

    // MARK: Giving

    private var gifts: [Gift] {
        (contact.gifts ?? []).sorted { $0.receivedAt > $1.receivedAt }
    }

    private var givingSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Giving")

            HStack(spacing: Space.sm) {
                StatTile(
                    value: contact.lifetimeGiving.formattedCompact,
                    label: "Lifetime",
                    systemImage: "gift.fill",
                    tint: Palette.positive
                )
                StatTile(value: "\(contact.giftCount)", label: "Gifts", systemImage: "number")
                if let first = contact.firstGiftAt {
                    StatTile(
                        value: first.formatted(.dateTime.year()),
                        label: "Since",
                        systemImage: "calendar"
                    )
                }
            }

            if gifts.isEmpty {
                Text("No gifts recorded yet.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(gifts.prefix(5)) { gift in
                    GiftRow(gift: gift)
                }
                if gifts.count > 5 {
                    Text("and \(gifts.count - 5) more")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    // MARK: Visits

    private var visits: [Visit] {
        (contact.visits ?? []).sorted { $0.occurredAt > $1.occurredAt }
    }

    @ViewBuilder
    private var visitsSection: some View {
        if !visits.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(title: "Every visit")
                ForEach(visits.prefix(8)) { visit in
                    VisitRow(visit: visit)
                }
            }
        }
    }

    // MARK: Documents

    private var documents: [GeneratedDocument] {
        gifts
            .flatMap { $0.documents ?? [] }
            .sorted { $0.issuedAt > $1.issuedAt }
    }

    @ViewBuilder
    private var documentsSection: some View {
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(title: "Documents")
                ForEach(documents) { document in
                    NavigationLink {
                        DocumentDetailView(document: document)
                    } label: {
                        DocumentRow(document: document)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Notes")

            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.entitlements.isSharingActive ? "Shared with the team" : "Notes")
                        .font(Type.label)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                    TextField(
                        "What should whoever visits next know?",
                        text: Binding(
                            get: { contact.sharedNotes },
                            set: {
                                contact.sharedNotes = $0
                                contact.touch()
                                try? context.save()
                                app.projectToTeam(contact)
                            }
                        ),
                        axis: .vertical
                    )
                    .font(Type.body)
                    .lineLimit(2...6)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text("Only on this iPhone")
                            .font(Type.label)
                            .textCase(.uppercase)
                        Spacer()
                        if app.entitlements.isSharingActive {
                            Text("Not shared, even with your team")
                                .font(.caption2)
                                .textCase(nil)
                        }
                    }
                    .foregroundStyle(Palette.textSecondary)

                    TextField(
                        "Anything you would not put in an organizational record",
                        text: Binding(
                            get: { contact.privateNotes },
                            set: { contact.privateNotes = $0; contact.touch(); try? context.save() }
                        ),
                        axis: .vertical
                    )
                    .font(Type.body)
                    .lineLimit(2...6)
                }
            }
            .cardSurface()
        }
    }

    // MARK: Admin

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "This record")

            VStack(spacing: Space.sm) {
                if app.entitlements.isEnabled(.sharedTeamMemory) {
                    Toggle(isOn: Binding(
                        get: { contact.isSharedWithTeam },
                        set: { newValue in
                            SyncEngine.markShared(contact, isShared: newValue)
                            try? context.save()
                            if newValue {
                                app.projectToTeam(contact)
                            } else {
                                app.withdrawFromTeam(contact)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Share with the team")
                                .font(Type.body)
                            Text("Visits, warmth and giving. Private notes never leave this iPhone.")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .tint(Palette.brand)
                } else {
                    LockedFeatureRow(feature: .sharedTeamMemory)
                }

                Divider()

                Button(role: .destructive) {
                    contact.isArchived = true
                    contact.touch()
                    try? context.save()
                } label: {
                    Label("Archive this contact", systemImage: "archivebox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Space.minimumTarget)
                }

                Text("Archiving hides them from lists and the map. Nothing is deleted — the giving history stays in your records.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .cardSurface()
        }
    }
}

// MARK: - Rows and buttons

struct QuickActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.step()
            action()
        }) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 60)
            .foregroundStyle(Palette.brand)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct GiftRow: View {
    let gift: Gift

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: gift.method.symbolName)
                .font(.body)
                .foregroundStyle(gift.isVoided ? Palette.textTertiary : Palette.positive)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(gift.summaryLine)
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(gift.isVoided ? Palette.textTertiary : Palette.textPrimary)
                    .strikethrough(gift.isVoided)
                HStack(spacing: Space.xs) {
                    Text(gift.receivedAt.formatted(date: .abbreviated, time: .omitted))
                    if let fund = gift.fundName.trimmedOrNil {
                        Text("·")
                        Text(fund)
                    }
                }
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)

                if gift.isVoided, let reason = gift.voidReason.trimmedOrNil {
                    Text("Voided: \(reason)")
                        .font(Type.caption)
                        .foregroundStyle(Palette.critical)
                }
                if !gift.isPaymentConfirmed, gift.method.requiresNetwork {
                    Label("Payment not confirmed", systemImage: "exclamationmark.triangle.fill")
                        .font(Type.caption)
                        .foregroundStyle(Palette.caution)
                }
            }

            Spacer(minLength: Space.sm)

            if !(gift.documents ?? []).isEmpty {
                Image(systemName: "doc.text.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("Has a document")
            }
        }
        .cardSurface(padding: Space.sm)
        .accessibilityElement(children: .combine)
    }
}

/// The consistent way a locked paid feature appears. Never a blocked door with
/// no explanation — always what it does and what it costs.
struct LockedFeatureRow: View {
    let feature: Feature
    @State private var isPresentingPaywall = false

    var body: some View {
        Button {
            isPresentingPaywall = true
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "person.2.badge.key.fill")
                    .foregroundStyle(Palette.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Part of FieldForge Team")
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text(feature.lockedExplanation)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(minHeight: Space.minimumTarget)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingPaywall) { PaywallView() }
    }
}

#Preview("Contact detail") {
    let container = Persistence.previewContainer()
    let contacts = (try? container.mainContext.fetch(FetchDescriptor<Contact>())) ?? []
    NavigationStack {
        if let contact = contacts.first {
            ContactDetailView(contact: contact)
        } else {
            Text("Seed data unavailable")
        }
    }
    .environment(\.appEnvironment, AppEnvironment.preview())
    .modelContainer(container)
}
