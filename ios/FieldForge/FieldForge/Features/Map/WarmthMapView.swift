//
//  WarmthMapView.swift
//  FieldForge
//
//  The map of everyone you know, coloured by how they felt about you.
//
//  This is the screen that changes how a route gets planned. Standing on a
//  corner with twenty minutes spare, a staffer can see the two warm businesses
//  a block away and the one that asked never to be visited again — and act on
//  all three.
//

import MapKit
import SwiftData
import SwiftUI

struct WarmthMapView: View {

    let onStartCapture: (Contact) -> Void

    @Environment(\.appEnvironment) private var app

    @Query(
        filter: #Predicate<Contact> { $0.isArchived == false },
        sort: \Contact.updatedAt,
        order: .reverse
    )
    private var contacts: [Contact]

    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedContactID: UUID?
    @State private var warmthFilter: Set<Warmth> = Set(Warmth.allCases)
    @State private var showsOnlyOpenFollowUps = false
    @State private var hasCenteredOnUser = false
    @State private var isLocating = false
    @State private var isShowingLegend = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                VStack(spacing: 0) {
                    filterBar
                    if isShowingLegend { legend }
                    if !app.reachability.isOnline, app.sharedWarmth.state.isActive {
                        staleTeamDataNotice
                    }
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityPill(
                        reachability: app.reachability,
                        queuedCount: app.sharedWarmth.pendingUploadCount
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingLegend.toggle()
                    } label: {
                        Image(systemName: isShowingLegend ? "questionmark.circle.fill" : "questionmark.circle")
                    }
                    .accessibilityLabel(isShowingLegend ? "Hide the colour key" : "Show the colour key")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await centerOnUser() }
                    } label: {
                        if isLocating {
                            ProgressView()
                        } else {
                            Image(systemName: "location.fill")
                        }
                    }
                    .disabled(isLocating)
                    .accessibilityLabel("Centre on my location")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let contact = selectedContact {
                    selectedContactCard(contact)
                        .padding(.horizontal, Space.screenEdge)
                        .padding(.bottom, Space.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: selectedContactID)
            .task { await centerOnUserOnce() }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, selection: $selectedContactID) {
            // The user's own position, so "am I near anything" is answerable at
            // a glance.
            UserAnnotation()

            ForEach(pinnedContacts) { contact in
                if let coordinate = contact.coordinate {
                    Annotation(
                        contact.displayName,
                        coordinate: coordinate,
                        anchor: .center
                    ) {
                        WarmthMapPin(
                            warmth: contact.warmth,
                            isSelected: selectedContactID == contact.id,
                            hasOpenFollowUp: hasOpenFollowUp(contact)
                        )
                        .onTapGesture {
                            Haptics.selection()
                            selectedContactID = contact.id
                        }
                    }
                    .tag(contact.id)
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including([.restaurant, .store, .cafe])))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .center) {
            if pinnedContacts.isEmpty, !isLocating {
                emptyOverlay
            }
        }
    }

    private var emptyOverlay: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "mappin.slash")
                .font(.largeTitle)
                .foregroundStyle(Palette.textTertiary)
            Text(contacts.isEmpty ? "No contacts yet" : "No contacts have a location yet")
                .font(Type.section)
            Text(contacts.isEmpty
                 ? "Capture a visit and it lands on the map."
                 : "Visits captured with location on will appear here.")
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
        .padding(Space.screenEdge)
    }

    // MARK: Filters

    /// Warmth filters as a horizontal strip of toggles. Tapping one narrows the
    /// map; the count on each tells you whether it is worth tapping.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                Button {
                    Haptics.selection()
                    showsOnlyOpenFollowUps.toggle()
                } label: {
                    Label("Owed", systemImage: "bell.badge.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Space.sm)
                        .frame(minHeight: 32)
                        .background(
                            showsOnlyOpenFollowUps ? Palette.caution : Palette.surface,
                            in: Capsule()
                        )
                        .foregroundStyle(showsOnlyOpenFollowUps ? .white : Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsOnlyOpenFollowUps ? [.isButton, .isSelected] : .isButton)

                ForEach(Warmth.allCases) { warmth in
                    let count = contacts.filter { $0.warmth == warmth && $0.coordinate != nil }.count
                    if count > 0 {
                        FilterChip(
                            warmth: warmth,
                            count: count,
                            isOn: warmthFilter.contains(warmth)
                        ) {
                            Haptics.selection()
                            if warmthFilter.contains(warmth) {
                                warmthFilter.remove(warmth)
                            } else {
                                warmthFilter.insert(warmth)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.screenEdge)
            .padding(.vertical, Space.sm)
        }
        .background(.ultraThinMaterial)
    }

    /// The colour key. Red through green, with the glyphs that carry the same
    /// information without colour, because a red-to-green ramp is precisely the
    /// scale a colour-blind viewer cannot read.
    private var legend: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Colour key")
                .font(Type.label)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: Space.sm) {
                ForEach([Warmth.cool, .neutral, .warm, .champion]) { warmth in
                    HStack(spacing: 4) {
                        Image(systemName: warmth.symbolName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 18, height: 18)
                            .background(warmth.tint, in: Circle())
                        Text(warmth.label)
                            .font(.caption2)
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: Warmth.doNotReturn.symbolName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 18, height: 18)
                    .background(Warmth.doNotReturn.tint, in: Circle())
                Text("Do not contact — deliberately off the colour scale")
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, Space.screenEdge)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
    }

    /// Offline with team sharing on: the pins may be behind what a colleague
    /// has recorded. Saying so is better than showing stale data silently.
    private var staleTeamDataNotice: some View {
        Label(
            "Offline — teammates' updates will appear when you reconnect.",
            systemImage: "wifi.slash"
        )
        .font(.caption2)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Space.screenEdge)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    // MARK: Data

    private var pinnedContacts: [Contact] {
        contacts.filter { contact in
            guard contact.coordinate != nil else { return false }
            guard warmthFilter.contains(contact.warmth) else { return false }
            if showsOnlyOpenFollowUps { return hasOpenFollowUp(contact) }
            return true
        }
    }

    private var selectedContact: Contact? {
        guard let selectedContactID else { return nil }
        return contacts.first { $0.id == selectedContactID }
    }

    private func hasOpenFollowUp(_ contact: Contact) -> Bool {
        (contact.followUps ?? []).contains { !$0.isComplete }
    }

    // MARK: Selected contact card

    private func selectedContactCard(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(Type.section)
                        .foregroundStyle(Palette.textPrimary)
                    Text(contact.subtitle)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    if contact.giftCount > 0 {
                        Text("\(contact.lifetimeGiving.formattedCompact) lifetime")
                            .font(Type.caption.weight(.semibold))
                            .foregroundStyle(Palette.positive)
                    }
                }
                Spacer(minLength: Space.sm)
                VStack(alignment: .trailing, spacing: Space.xs) {
                    WarmthBadge(warmth: contact.warmth, size: .compact)
                    Button {
                        selectedContactID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            if contact.isDoNotContact {
                InlineBanner(kind: .critical, message: "Asked not to be contacted again.")
            }

            HStack(spacing: Space.sm) {
                NavigationLink {
                    ContactDetailView(contact: contact)
                } label: {
                    Text("Open")
                        .font(Type.secondary.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Space.minimumTarget)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                                .strokeBorder(Palette.separator, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                if !contact.isDoNotContact {
                    Button {
                        onStartCapture(contact)
                    } label: {
                        Text("Capture")
                            .font(Type.secondary.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Space.minimumTarget)
                            .foregroundStyle(Palette.onAccent)
                            .background(Palette.brand, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    // MARK: Camera

    private func centerOnUserOnce() async {
        guard !hasCenteredOnUser else { return }
        hasCenteredOnUser = true
        await centerOnUser()
    }

    private func centerOnUser() async {
        isLocating = true
        defer { isLocating = false }
        guard let fix = await app.location.currentLocation(maximumAge: 120) else {
            // No fix: frame whatever pins exist instead of dropping the user in
            // the middle of the Atlantic.
            camera = .automatic
            return
        }
        camera = .region(MKCoordinateRegion(
            center: fix.coordinate,
            latitudinalMeters: 1200,
            longitudinalMeters: 1200
        ))
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let warmth: Warmth
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: warmth.symbolName)
                    .font(.caption2.weight(.bold))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 32)
            .background(isOn ? warmth.tint : Palette.surface, in: Capsule())
            .foregroundStyle(isOn ? .white : Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(warmth.label), \(count) contacts")
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Map") {
    WarmthMapView(onStartCapture: { _ in })
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
