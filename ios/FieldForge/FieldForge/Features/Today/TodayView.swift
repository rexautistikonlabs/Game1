//
//  TodayView.swift
//  FieldForge
//
//  The screen the app opens to, designed around one question: what should I do
//  in the next ten seconds?
//
//  Order of the page is the order of urgency:
//    1. Anything broken (setup missing, storage degraded, documents stuck).
//    2. Follow-ups due now — the reason today is different from yesterday.
//    3. Today's numbers, small, for the sense of progress that keeps a
//       volunteer walking.
//    4. Warm contacts nearby, which is the feature that turns a spare twenty
//       minutes into a visit.
//    5. Recent activity, so a mistake is easy to find and fix.
//

import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct TodayView: View {

    let onStartCapture: () -> Void

    @Environment(\.appEnvironment) private var app

    /// Fetched with `@Query` so the screen updates the instant a gift is saved
    /// anywhere in the app — no manual refresh, no stale totals.
    @Query(sort: \Gift.receivedAt, order: .reverse) private var allGifts: [Gift]
    @Query(sort: \Visit.occurredAt, order: .reverse) private var allVisits: [Visit]
    @Query(filter: #Predicate<FollowUp> { $0.completedAt == nil }, sort: \FollowUp.dueAt)
    private var openFollowUps: [FollowUp]
    @Query(sort: \Contact.updatedAt, order: .reverse) private var contacts: [Contact]

    @State private var isPresentingPaywall = false
    @State private var isPresentingOutbox = false
    @State private var nearbyContacts: [NearbyContact] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    if let organization = app.activeOrganization(), !organization.isReadyToIssueDocuments {
                        setupNudge(organization)
                    }

                    if app.outbox.pendingCount > 0 {
                        InlineBanner(
                            kind: app.reachability.isOnline ? .info : .caution,
                            message: outboxMessage,
                            actionTitle: "Open"
                        ) {
                            isPresentingOutbox = true
                        }
                    }

                    if app.payments.isSimulatingPayments {
                        InlineBanner(
                            kind: .critical,
                            message: "Payments are simulated in this build. Nothing is actually charged, and receipts from it are not real."
                        )
                    }

                    dueFollowUpsSection
                    todaySection
                    nearbySection
                    recentSection
                }
                .padding(.horizontal, Space.screenEdge)
                .padding(.top, Space.sm)
                // Room for the floating Capture button.
                .padding(.bottom, 140)
            }
            .background(Palette.background)
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingOutbox = true
                    } label: {
                        ConnectivityPill(
                            reachability: app.reachability,
                            queuedCount: app.outbox.pendingCount
                        )
                    }
                    .accessibilityLabel("Connection and queue status")
                }
            }
            .sheet(isPresented: $isPresentingPaywall) { PaywallView() }
            .sheet(isPresented: $isPresentingOutbox) { OutboxView() }
            .task { await refreshNearby() }
            .refreshable {
                await app.outbox.drain()
                await refreshNearby()
            }
        }
    }

    // MARK: Greeting

    /// Time-of-day greeting with the staffer's name when we know it. Small
    /// thing; it makes the app feel like theirs rather than the organization's.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let salutation: String
        switch hour {
        case 0..<12: salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        guard let name = app.staffDisplayName.trimmedOrNil else { return salutation }
        return "\(salutation), \(name.split(separator: " ").first.map(String.init) ?? name)"
    }

    private var outboxMessage: String {
        let count = app.outbox.pendingCount
        let noun = count == 1 ? "document" : "documents"
        if !app.reachability.isOnline {
            return "\(count) \(noun) waiting to send. They will go out the moment you have signal."
        }
        return "\(count) \(noun) ready to send."
    }

    // MARK: Setup nudge

    private func setupNudge(_ organization: Organization) -> some View {
        NavigationLink {
            OrganizationEditorView(organization: organization)
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: "building.2.crop.circle.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Palette.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up your organization")
                        .font(Type.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(organization.missingRequiredBrandingFields.joined(separator: " · "))
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .cardSurface()
        }
        .buttonStyle(.plain)
    }

    // MARK: Follow-ups

    private var dueFollowUps: [FollowUp] {
        openFollowUps.filter { $0.isOverdue || $0.isDueToday }
    }

    @ViewBuilder
    private var dueFollowUpsSection: some View {
        if !dueFollowUps.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(
                    title: "Due now",
                    subtitle: dueFollowUps.count == 1 ? "1 follow-up" : "\(dueFollowUps.count) follow-ups"
                )
                ForEach(dueFollowUps.prefix(4)) { followUp in
                    FollowUpRow(followUp: followUp)
                }
                if dueFollowUps.count > 4 {
                    NavigationLink("See all \(dueFollowUps.count)") { FollowUpsView() }
                        .font(Type.secondary.weight(.medium))
                        .foregroundStyle(Palette.brand)
                }
            }
        }
    }

    // MARK: Today's numbers

    private var todayGifts: [Gift] {
        allGifts.filter {
            Calendar.current.isDateInToday($0.receivedAt) && $0.countsTowardGiving
        }
    }

    private var todayVisits: [Visit] {
        allVisits.filter { Calendar.current.isDateInToday($0.occurredAt) }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Today")

            HStack(spacing: Space.sm) {
                StatTile(
                    value: Money.sum(todayGifts.map(\.amount)).formattedCompact,
                    label: "Raised",
                    systemImage: "arrow.up.right"
                )
                StatTile(
                    value: "\(todayVisits.count)",
                    label: "Doors",
                    systemImage: "figure.walk"
                )
                StatTile(
                    value: "\(todayGifts.count)",
                    label: "Gifts",
                    systemImage: "gift.fill"
                )
            }

            if todayVisits.isEmpty && todayGifts.isEmpty {
                Text("Nothing recorded yet today. Tap Capture when you are at your first door.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if !todayVisits.isEmpty {
                // The conversion line. Blunt, and the number a development
                // director actually asks about.
                let conversion = Double(todayGifts.count) / Double(todayVisits.count)
                Text("\(conversion.formatted(.percent.precision(.fractionLength(0)))) of today's doors gave.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Nearby

    struct NearbyContact: Identifiable {
        let contact: Contact
        let distanceMeters: CLLocationDistance
        var id: UUID { contact.id }

        var distanceDescription: String {
            let measurement = Measurement(value: distanceMeters, unit: UnitLength.meters)
            return measurement.formatted(
                .measurement(width: .abbreviated, usage: .road)
            )
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        if !nearbyContacts.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(
                    title: "Warm nearby",
                    subtitle: "People worth a knock while you are here",
                    actionTitle: "Map"
                ) {}
                ForEach(nearbyContacts.prefix(4)) { nearby in
                    NavigationLink {
                        ContactDetailView(contact: nearby.contact)
                    } label: {
                        HStack(spacing: Space.md) {
                            WarmthBadge(warmth: nearby.contact.warmth, showsLabel: false)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(nearby.contact.displayName)
                                    .font(Type.body.weight(.medium))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(nearby.contact.subtitle)
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: Space.sm)
                            Text(nearby.distanceDescription)
                                .font(Type.caption.weight(.medium))
                                .foregroundStyle(Palette.textSecondary)
                                .monospacedDigit()
                        }
                        .cardSurface(padding: Space.sm)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(nearby.contact.displayName), \(nearby.contact.warmth.label), \(nearby.distanceDescription) away")
                }
            }
        }
    }

    /// Finds warm contacts within walking distance of the current fix.
    ///
    /// Done in-memory rather than with a spatial query: SwiftData has no
    /// geospatial index, and a field CRM with tens of thousands of contacts in
    /// one city is not a real shape. If it becomes one, this becomes a
    /// bounding-box predicate before it becomes a problem.
    private func refreshNearby() async {
        guard app.location.authorization != .denied else {
            nearbyContacts = []
            return
        }
        guard let fix = await app.location.currentLocation(maximumAge: 300) else {
            nearbyContacts = []
            return
        }

        let radius: CLLocationDistance = 800   // roughly a ten-minute walk
        let found = contacts.compactMap { contact -> NearbyContact? in
            guard !contact.isDoNotContact, !contact.isArchived else { return nil }
            guard contact.warmth == .warm || contact.warmth == .champion else { return nil }
            guard let coordinate = contact.coordinate else { return nil }
            let distance = fix.distance(
                from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            guard distance <= radius else { return nil }
            return NearbyContact(contact: contact, distanceMeters: distance)
        }
        nearbyContacts = found.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(allVisits.prefix(6))
        if recent.isEmpty {
            EmptyStateView(
                symbol: "figure.walk.motion",
                title: "Nothing here yet",
                message: "Tap Capture at your first door. Point the camera at the sign and FieldForge fills in the rest.",
                actionTitle: "Capture your first visit",
                action: onStartCapture
            )
            .cardSurface()
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(title: "Recent")
                ForEach(recent) { visit in
                    if let contact = visit.contact {
                        NavigationLink {
                            ContactDetailView(contact: contact)
                        } label: {
                            VisitRow(visit: visit, showsContactName: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

/// A follow-up with its action attached. The button is the point: a reminder you
/// can act on from the list is a reminder that gets done.
struct FollowUpRow: View {
    let followUp: FollowUp

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: Space.md) {
            Button {
                Haptics.success()
                followUp.complete()
                Task { await NotificationScheduler.cancel(followUp) }
                try? context.save()
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(Palette.textTertiary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(followUp.contact?.displayName ?? "Follow up")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                if let note = followUp.note.trimmedOrNil {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: Space.xs) {
                    Label(followUp.kind.label, systemImage: followUp.kind.symbolName)
                    Text("·")
                    Text(followUp.relativeDueDescription)
                }
                .font(Type.caption)
                .foregroundStyle(followUp.isOverdue ? Palette.critical : Palette.textTertiary)
            }

            Spacer(minLength: Space.sm)

            if let url = actionURL {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: followUp.kind.symbolName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(width: 40, height: 40)
                        .background(Palette.brandMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(followUp.kind.label) \(followUp.contact?.displayName ?? "")")
            }
        }
        .cardSurface(padding: Space.sm)
        .swipeActions(edge: .trailing) {
            Button("Snooze a week") {
                followUp.snooze(byDays: 7)
                Task { await NotificationScheduler.schedule(followUp) }
                try? context.save()
            }
            .tint(Palette.caution)
        }
    }

    /// The one-tap action, when the contact has the means for it.
    private var actionURL: URL? {
        guard let contact = followUp.contact, !contact.isDoNotContact else { return nil }
        switch followUp.kind {
        case .call: return ContactActions.callURL(for: contact.phone)
        case .text: return ContactActions.messageURL(for: contact.phone)
        case .email, .thankYou, .sendDocument:
            return ContactActions.mailURL(for: contact.email, subject: "Thank you from our team")
        case .visitAgain: return ContactActions.mapsURL(for: contact)
        case .collectPledge: return ContactActions.callURL(for: contact.phone)
        case .other: return nil
        }
    }
}

/// One line of history.
struct VisitRow: View {
    let visit: Visit
    var showsContactName: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(spacing: 2) {
                Image(systemName: visit.outcome.symbolName)
                    .font(.body)
                    .foregroundStyle(visit.warmth == .unrated ? Palette.textTertiary : visit.warmth.tint)
            }
            .frame(width: 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if showsContactName {
                    Text(visit.contact?.displayName ?? "Unknown")
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                }
                Text(visit.outcome.label)
                    .font(showsContactName ? Type.caption : Type.body)
                    .foregroundStyle(showsContactName ? Palette.textSecondary : Palette.textPrimary)
                if let note = visit.notes.trimmedOrNil {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: 4) {
                Text(visit.occurredAt.formatted(.relative(presentation: .numeric)))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
                if let gift = visit.gift, gift.countsTowardGiving {
                    Text(gift.isInKind ? "In-kind" : gift.amount.formattedCompact)
                        .font(Type.caption.weight(.semibold))
                        .foregroundStyle(Palette.positive)
                        .monospacedDigit()
                }
            }
        }
        .cardSurface(padding: Space.sm)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Today") {
    TodayView(onStartCapture: {})
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
