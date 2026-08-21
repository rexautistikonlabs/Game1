//
//  TodayView.swift
//  FieldForge
//
//  The screen the app opens to, built around one question: **what should I do
//  in the next ten seconds?**
//
//  Ordered by urgency, not by category:
//
//   1. Anything broken — setup missing, storage degraded, documents stuck.
//   2. Who to see today. The single most useful thing the app knows, and now
//      the top of the screen rather than buried under statistics.
//   3. Route mode, when there is enough to route.
//   4. Today's numbers, small, for the sense of progress that keeps a
//      volunteer walking.
//   5. What the team has been doing, when sharing is on.
//   6. Recent activity, so a mistake is easy to find and fix.
//
//  Everything here is derived from local data. No spinner blocks the first
//  paint, and every section degrades to a useful empty state rather than
//  vanishing.
//

import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct TodayView: View {

    let onStartCapture: () -> Void
    let onStartRoute: () -> Void

    @Environment(\.appEnvironment) private var app

    @Query(sort: \Gift.receivedAt, order: .reverse) private var allGifts: [Gift]
    @Query(sort: \Visit.occurredAt, order: .reverse) private var allVisits: [Visit]
    @Query(filter: #Predicate<FollowUp> { $0.completedAt == nil }, sort: \FollowUp.dueAt)
    private var openFollowUps: [FollowUp]
    @Query(filter: #Predicate<Contact> { $0.isArchived == false }, sort: \Contact.updatedAt, order: .reverse)
    private var contacts: [Contact]

    @State private var isPresentingPaywall = false
    @State private var isPresentingOutbox = false
    @State private var nearby: [NearbyContact] = []
    @State private var locationState: LocationSectionState = .idle

    /// Distinguishes "still looking" from "looked, found nothing" from "cannot
    /// look" — three states that need three different messages, and which a
    /// single optional array cannot express.
    private enum LocationSectionState: Equatable {
        case idle
        case locating
        case ready
        case denied
        case unavailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    problemsSection
                    whoToSeeSection
                    routeSection
                    numbersSection
                    teamSection
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
                await app.sharedWarmth.sync()
                await refreshNearby()
            }
        }
    }

    // MARK: 1. Problems

    @ViewBuilder
    private var problemsSection: some View {
        if let organization = app.activeOrganization(), !organization.isReadyToIssueDocuments {
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
    }

    private var outboxMessage: String {
        let count = app.outbox.pendingCount
        let noun = count == 1 ? "document" : "documents"
        if !app.reachability.isOnline {
            return "\(count) \(noun) waiting to send. They will go out the moment you have signal."
        }
        return "\(count) \(noun) ready to send."
    }

    // MARK: 2. Who to see today

    /// One ranked list rather than three competing ones.
    ///
    /// A staffer does not think "overdue follow-ups, then due-today follow-ups,
    /// then nearby warm contacts". They think "who should I see". So the
    /// candidates are merged and scored, and the reason each one made the list
    /// is shown on its row — which is what makes the ranking trustworthy rather
    /// than magic.
    private struct Suggestion: Identifiable {
        let contact: Contact
        let reason: String
        let urgency: Int
        let followUp: FollowUp?
        let distance: CLLocationDistance?

        var id: UUID { contact.id }

        var distanceDescription: String? {
            guard let distance else { return nil }
            return Measurement(value: distance, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
    }

    private var suggestions: [Suggestion] {
        var byContact: [UUID: Suggestion] = [:]
        let nearbyByID = Dictionary(
            nearby.map { ($0.contact.id, $0.distanceMeters) },
            uniquingKeysWith: { first, _ in first }
        )

        func consider(_ candidate: Suggestion) {
            if let existing = byContact[candidate.contact.id], existing.urgency >= candidate.urgency {
                return
            }
            byContact[candidate.contact.id] = candidate
        }

        for followUp in openFollowUps {
            guard let contact = followUp.contact, !contact.isDoNotContact, !contact.isArchived else { continue }
            if followUp.isOverdue, !followUp.isDueToday {
                let days = Calendar.current.dateComponents([.day], from: followUp.dueAt, to: .now).day ?? 0
                consider(Suggestion(
                    contact: contact,
                    reason: days > 0 ? "Overdue by \(days) day\(days == 1 ? "" : "s")" : "Overdue",
                    urgency: 100,
                    followUp: followUp,
                    distance: nearbyByID[contact.id]
                ))
            } else if followUp.isDueToday {
                consider(Suggestion(
                    contact: contact,
                    reason: "Due today · \(followUp.kind.label)",
                    urgency: 90,
                    followUp: followUp,
                    distance: nearbyByID[contact.id]
                ))
            }
        }

        // Warm contacts you happen to be standing near. Lower urgency than a
        // commitment, but this is the row that turns a spare twenty minutes
        // into a gift.
        for entry in nearby {
            let contact = entry.contact
            guard !contact.isDoNotContact else { continue }
            let reason = contact.warmth == .champion
                ? "Champion, \(entry.distanceDescription) away"
                : "Warm, \(entry.distanceDescription) away"
            consider(Suggestion(
                contact: contact,
                reason: reason,
                urgency: contact.warmth == .champion ? 60 : 50,
                followUp: nil,
                distance: entry.distanceMeters
            ))
        }

        // Someone warm who has not been seen in a long time. Quietly the most
        // valuable category in fundraising and the easiest to forget.
        let staleCutoff = Calendar.current.date(byAdding: .month, value: -9, to: .now) ?? .distantPast
        for contact in contacts where !contact.isDoNotContact {
            guard contact.warmth == .warm || contact.warmth == .champion else { continue }
            guard let lastVisit = contact.lastVisitAt, lastVisit < staleCutoff else { continue }
            consider(Suggestion(
                contact: contact,
                reason: "Warm, not seen since \(lastVisit.formatted(.dateTime.month(.abbreviated).year()))",
                urgency: 40,
                followUp: nil,
                distance: nearbyByID[contact.id]
            ))
        }

        return byContact.values.sorted { left, right in
            if left.urgency != right.urgency { return left.urgency > right.urgency }
            // Within the same urgency, nearest first — that is the tiebreak
            // that saves actual walking.
            switch (left.distance, right.distance) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.contact.displayName < right.contact.displayName
            }
        }
    }

    @ViewBuilder
    private var whoToSeeSection: some View {
        let list = suggestions
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(
                title: "Who to see today",
                subtitle: list.isEmpty ? nil : "\(list.count) worth a knock"
            )

            if list.isEmpty {
                emptyWhoToSee
            } else {
                ForEach(list.prefix(6)) { suggestion in
                    NavigationLink {
                        ContactDetailView(contact: suggestion.contact)
                    } label: {
                        SuggestionRow(
                            contact: suggestion.contact,
                            reason: suggestion.reason,
                            distance: suggestion.distanceDescription,
                            isCommitment: suggestion.followUp != nil
                        )
                    }
                    .buttonStyle(.plain)
                }
                if list.count > 6 {
                    NavigationLink("See all \(list.count)") { FollowUpsView() }
                        .font(Type.secondary.weight(.medium))
                        .foregroundStyle(Palette.brand)
                }
            }
        }
    }

    /// Four different empty states, because the right thing to say depends
    /// entirely on why the list is empty.
    @ViewBuilder
    private var emptyWhoToSee: some View {
        if contacts.isEmpty {
            EmptyStateView(
                symbol: "person.crop.circle.badge.plus",
                title: "Nobody in here yet",
                message: "Long-press Capture and scan a shop sign. FieldForge reads the name and address and saves the visit in one go.",
                actionTitle: "Capture your first visit",
                action: onStartCapture
            )
            .cardSurface()
        } else {
            switch locationState {
            case .locating:
                HStack(spacing: Space.sm) {
                    ProgressView()
                    Text("Looking for warm contacts near you…")
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: Space.sm)

            case .denied:
                InlineBanner(
                    kind: .info,
                    message: "Turn on location and FieldForge will show warm contacts within a short walk. Everything else works without it."
                )

            case .idle, .ready, .unavailable:
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Nothing owed today",
                    message: "No follow-ups due and nobody warm nearby. A good day to knock on new doors.",
                    actionTitle: "Capture a new visit",
                    action: onStartCapture
                )
                .cardSurface()
            }
        }
    }

    // MARK: 3. Route

    /// Only offered when there is actually something to route. A route button
    /// that produces a one-stop route is worse than no button.
    @ViewBuilder
    private var routeSection: some View {
        let routable = suggestions.filter { $0.contact.coordinate != nil }
        if routable.count >= 2 {
            let isUnlocked = app.entitlements.isEnabled(.routeMode)
            Button {
                if isUnlocked { onStartRoute() } else { isPresentingPaywall = true }
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color("RoutePath"), in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.xs) {
                            Text("Walk them as a route")
                                .font(Type.body.weight(.semibold))
                                .foregroundStyle(Palette.textPrimary)
                            if !isUnlocked {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        Text(isUnlocked
                             ? "\(routable.count) stops, ordered by walking distance"
                             : "Route mode is part of FieldForge Team")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
                .cardSurface()
            }
            .buttonStyle(.plain)
            .accessibilityHint(isUnlocked ? "Orders today's stops by walking distance" : "Part of FieldForge Team")
        }
    }

    // MARK: 4. Numbers

    private var todayGifts: [Gift] {
        allGifts.filter {
            Calendar.current.isDateInToday($0.receivedAt) && $0.countsTowardGiving
        }
    }

    private var todayVisits: [Visit] {
        allVisits.filter { Calendar.current.isDateInToday($0.occurredAt) }
    }

    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Today so far")

            HStack(spacing: Space.sm) {
                StatTile(
                    value: Money.sum(todayGifts.map(\.amount)).formattedCompact,
                    label: "Raised",
                    systemImage: "arrow.up.right",
                    tint: Palette.positive
                )
                StatTile(value: "\(todayVisits.count)", label: "Doors", systemImage: "figure.walk")
                StatTile(value: "\(todayGifts.count)", label: "Gifts", systemImage: "gift.fill")
            }

            if todayVisits.isEmpty && todayGifts.isEmpty {
                Text("Nothing recorded yet today. Tap Capture at your first door.")
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

    // MARK: 5. Team

    @ViewBuilder
    private var teamSection: some View {
        if app.sharedWarmth.state.isActive {
            let teamOnly = app.sharedWarmth.teamOnlyProjections()
            if !teamOnly.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionHeader(
                        title: "From your team",
                        subtitle: "Places a colleague has already been"
                    )
                    ForEach(teamOnly.prefix(3), id: \.contactID) { projection in
                        HStack(spacing: Space.md) {
                            WarmthBadge(warmth: projection.warmth, showsLabel: false)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(projection.displayName)
                                    .font(Type.body.weight(.medium))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(projection.lastUpdatedByDisplayName.trimmedOrNil.map { "via \($0)" }
                                     ?? projection.subtitleLine)
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
                        .cardSurface(padding: Space.sm)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: 6. Recent

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(allVisits.prefix(6))
        if !recent.isEmpty {
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

    // MARK: Greeting

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

    // MARK: Nearby

    struct NearbyContact: Identifiable {
        let contact: Contact
        let distanceMeters: CLLocationDistance
        var id: UUID { contact.id }

        var distanceDescription: String {
            Measurement(value: distanceMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
    }

    /// Finds warm contacts within walking distance of the current fix.
    ///
    /// In-memory rather than a spatial query: SwiftData has no geospatial
    /// index, and a field CRM with tens of thousands of contacts in one city is
    /// not a real shape. If it becomes one, this becomes a bounding-box
    /// predicate before it becomes a problem.
    private func refreshNearby() async {
        guard app.location.authorization != .denied else {
            locationState = .denied
            nearby = []
            return
        }
        locationState = .locating
        guard let fix = await app.location.currentLocation(maximumAge: 300) else {
            locationState = app.location.authorization == .denied ? .denied : .unavailable
            nearby = []
            return
        }

        let radius: CLLocationDistance = 800   // roughly a ten-minute walk
        nearby = contacts
            .compactMap { contact -> NearbyContact? in
                guard !contact.isDoNotContact else { return nil }
                guard contact.warmth == .warm || contact.warmth == .champion else { return nil }
                guard let coordinate = contact.coordinate else { return nil }
                let distance = fix.distance(
                    from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                )
                guard distance <= radius else { return nil }
                return NearbyContact(contact: contact, distanceMeters: distance)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
        locationState = .ready
    }
}

// MARK: - Suggestion row

/// A ranked suggestion, with the reason it is on the list. The reason is not
/// decoration — an ordering nobody can explain is an ordering nobody trusts.
private struct SuggestionRow: View {
    let contact: Contact
    let reason: String
    let distance: String?
    let isCommitment: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            WarmthBadge(warmth: contact.warmth, showsLabel: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: Space.xs) {
                    if isCommitment {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    Text(reason)
                        .lineLimit(1)
                }
                .font(Type.caption)
                .foregroundStyle(isCommitment ? Palette.caution : Palette.textSecondary)

                if contact.contactWindow != .unknown {
                    Text("Best \(contact.contactWindow.label.lowercased())")
                        .font(.caption2)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: 2) {
                if let distance {
                    Text(distance)
                        .font(Type.caption.weight(.medium))
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
                if contact.giftCount > 0 {
                    Text(contact.lifetimeGiving.formattedCompact)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.positive)
                        .monospacedDigit()
                }
            }
        }
        .cardSurface(padding: Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                contact.displayName,
                contact.warmth.label,
                reason,
                distance.map { "\($0) away" },
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}

#Preview("Today") {
    TodayView(onStartCapture: {}, onStartRoute: {})
        .environment(\.appEnvironment, AppEnvironment.preview(tier: .team))
        .modelContainer(Persistence.previewContainer())
}
