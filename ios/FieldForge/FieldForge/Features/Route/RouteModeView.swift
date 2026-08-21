//
//  RouteModeView.swift
//  FieldForge
//
//  Route mode: today's follow-ups, in walking order, one stop at a time.
//
//  The screen is built around the current stop rather than the list, because
//  that is how it is used — phone held low, glanced at between buildings. The
//  big card at the bottom says where to go next and how far; the map above it is
//  context, not the interface.
//

import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct RouteModeView: View {

    let onStartCapture: (Contact) -> Void

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @Query(filter: #Predicate<FollowUp> { $0.completedAt == nil }, sort: \FollowUp.dueAt)
    private var openFollowUps: [FollowUp]
    @Query(filter: #Predicate<Contact> { $0.isArchived == false })
    private var contacts: [Contact]

    @State private var camera: MapCameraPosition = .automatic
    @State private var origin: CLLocationCoordinate2D?
    @State private var isLocating = false
    @State private var includeWarmOpportunities = true
    @State private var noLocationMessage: String?

    private var planner: RoutePlanner { app.route }

    var body: some View {
        ZStack(alignment: .bottom) {
            map

            VStack(spacing: Space.sm) {
                if let noLocationMessage {
                    InlineBanner(kind: .caution, message: noLocationMessage)
                        .padding(.horizontal, Space.screenEdge)
                }
                if planner.stops.isEmpty {
                    emptyCard
                } else if planner.isFinished {
                    finishedCard
                } else {
                    currentStopCard
                }
            }
            .padding(.bottom, Space.sm)
        }
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Include warm drop-ins", isOn: $includeWarmOpportunities)
                    Button {
                        Task { await replan() }
                    } label: {
                        Label("Re-order from here", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        planner.clear()
                    } label: {
                        Label("End route", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Route options")
            }
        }
        .task { await buildRoute() }
        .onChange(of: includeWarmOpportunities) { _, _ in
            Task { await buildRoute() }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()

            // The planned path. A straight-line polyline, and the caption under
            // the card says so — drawing a confident street route we did not
            // actually compute would be a lie.
            if planner.stops.count > 1 {
                MapPolyline(coordinates: polylineCoordinates)
                    .stroke(
                        Color("RoutePath").opacity(0.85),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [10, 8])
                    )
            }

            ForEach(Array(planner.stops.enumerated()), id: \.element.id) { index, stop in
                Annotation(stop.name, coordinate: stop.coordinate, anchor: .center) {
                    RouteStopPin(
                        number: index + 1,
                        warmth: stop.warmth,
                        isCurrent: planner.currentStop?.id == stop.id,
                        isDone: stop.isDone
                    )
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including([.restaurant, .store, .cafe])))
        .mapControls { MapCompass() }
        .ignoresSafeArea(edges: .bottom)
    }

    private var polylineCoordinates: [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        if let origin { coordinates.append(origin) }
        coordinates.append(contentsOf: planner.stops.map(\.coordinate))
        return coordinates
    }

    // MARK: Cards

    private var emptyCard: some View {
        VStack(spacing: Space.sm) {
            if isLocating {
                ProgressView()
                Text("Working out where you are…")
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: "map")
                    .font(.title)
                    .foregroundStyle(Palette.textTertiary)
                Text("Nothing to route today")
                    .font(Type.section)
                Text("Route mode orders today's follow-ups by walking distance. Set a reminder on a contact and it will show up here.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await buildRoute() } }
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.brand)
                    .minimumTapTarget()
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
        .padding(.horizontal, Space.screenEdge)
    }

    private var finishedCard: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(Palette.positive)
            Text("Route finished")
                .font(Type.section)
            Text("\(planner.completedCount) stop\(planner.completedCount == 1 ? "" : "s") · \(planner.formattedTotalDistance) · about \(planner.totalWalkingMinutes) min of walking")
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Done", systemImage: "checkmark") {
                planner.clear()
                dismiss()
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
        .padding(.horizontal, Space.screenEdge)
    }

    @ViewBuilder
    private var currentStopCard: some View {
        if let stop = planner.currentStop, let index = planner.currentIndex {
            VStack(alignment: .leading, spacing: Space.sm) {
                // Progress line, so the staffer knows how much is left without
                // opening the list.
                HStack(spacing: Space.xs) {
                    Text("Stop \(index + 1) of \(planner.stops.count)")
                        .font(Type.label)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text("\(stop.formattedLeg) · \(stop.walkingMinutesFromPrevious) min")
                        .font(Type.caption.weight(.medium))
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }

                HStack(alignment: .top, spacing: Space.md) {
                    WarmthBadge(warmth: stop.warmth, showsLabel: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(Type.section)
                            .foregroundStyle(Palette.textPrimary)
                        if let subtitle = stop.subtitle.trimmedOrNil {
                            Text(subtitle)
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(2)
                        }
                        if stop.contactWindow != .unknown {
                            Label(stop.contactWindow.label, systemImage: "clock")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: Space.sm) {
                    Button {
                        openDirections(to: stop)
                    } label: {
                        Label("Walk", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Space.minimumTarget)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        capture(stop)
                    } label: {
                        Label("Capture", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Space.minimumTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                }

                HStack(spacing: Space.sm) {
                    Button("Skip") {
                        Haptics.selection()
                        planner.markSkipped(stopID: stop.id)
                        focusCurrentStop()
                    }
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .minimumTapTarget()

                    Spacer()

                    Button("Mark done") {
                        Haptics.success()
                        completeFollowUp(for: stop)
                        planner.markDone(stopID: stop.id)
                        focusCurrentStop()
                    }
                    .font(Type.secondary.weight(.semibold))
                    .foregroundStyle(Palette.positive)
                    .minimumTapTarget()
                }

                Text("Distances are straight-line, not street routing — the order is right, the numbers are approximate.")
                    .font(.caption2)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(Space.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, Space.screenEdge)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Building

    private func buildRoute() async {
        isLocating = true
        noLocationMessage = nil
        defer { isLocating = false }

        guard let fix = await app.location.currentLocation(maximumAge: 180) else {
            noLocationMessage = "Route mode needs your location to order the stops. Turn location on for FieldForge in Settings."
            return
        }
        origin = fix.coordinate

        var candidates: [RouteCandidate] = []
        var seen = Set<UUID>()

        // Due follow-ups first — these are commitments, not suggestions.
        for followUp in openFollowUps where followUp.isOverdue || followUp.isDueToday {
            guard let contact = followUp.contact, !contact.isDoNotContact else { continue }
            guard contact.coordinate != nil, !seen.contains(contact.id) else { continue }
            seen.insert(contact.id)
            candidates.append(RouteCandidate(followUp: followUp))
        }

        // Then warm contacts that happen to be near the route. This is the part
        // that turns a four-stop errand into a productive afternoon.
        if includeWarmOpportunities {
            let warm = contacts.filter {
                !$0.isDoNotContact
                    && ($0.warmth == .warm || $0.warmth == .champion)
                    && $0.coordinate != nil
                    && !seen.contains($0.id)
            }
            // Nearest twelve, so a dense downtown does not produce a fifty-stop
            // route nobody will walk.
            let nearest = warm
                .compactMap { contact -> (Contact, CLLocationDistance)? in
                    guard let coordinate = contact.coordinate else { return nil }
                    return (contact, RoutePlanner.distance(fix.coordinate, coordinate))
                }
                .sorted { $0.1 < $1.1 }
                .prefix(12)
            for (contact, _) in nearest {
                seen.insert(contact.id)
                candidates.append(RouteCandidate(opportunity: contact))
            }
        }

        planner.plan(candidates: candidates, from: fix.coordinate)
        planner.start()
        focusCurrentStop()
    }

    private func replan() async {
        guard let fix = await app.location.currentLocation(maximumAge: 60) else { return }
        origin = fix.coordinate
        planner.replanRemaining(from: fix.coordinate)
        focusCurrentStop()
    }

    private func focusCurrentStop() {
        guard let stop = planner.currentStop else {
            if planner.isFinished { camera = .automatic }
            return
        }
        withAnimation(.snappy(duration: 0.35)) {
            camera = .region(MKCoordinateRegion(
                center: stop.coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            ))
        }
    }

    // MARK: Actions

    private func contact(for stop: RoutePlanner.Stop) -> Contact? {
        contacts.first { $0.id == stop.contactID }
    }

    private func capture(_ stop: RoutePlanner.Stop) {
        guard let contact = contact(for: stop) else { return }
        onStartCapture(contact)
    }

    private func openDirections(to stop: RoutePlanner.Stop) {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(stop.coordinate.latitude),\(stop.coordinate.longitude)"),
            URLQueryItem(name: "dirflg", value: "w"),   // walking
            URLQueryItem(name: "q", value: stop.name),
        ]
        guard let url = components?.url else { return }
        openURL(url)
    }

    /// Marking a stop done completes the follow-up that put it there, so the
    /// two views never disagree about what is outstanding.
    private func completeFollowUp(for stop: RoutePlanner.Stop) {
        guard let followUpID = stop.followUpID,
              let followUp = openFollowUps.first(where: { $0.id == followUpID }) else { return }
        followUp.complete()
        Task { await NotificationScheduler.cancel(followUp) }
        try? context.save()
    }
}

// MARK: - Numbered stop pin

private struct RouteStopPin: View {
    let number: Int
    let warmth: Warmth
    let isCurrent: Bool
    let isDone: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDone ? Palette.textTertiary : warmth.tint)
                .frame(width: isCurrent ? 38 : 28, height: isCurrent ? 38 : 28)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            if isDone {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: isCurrent ? 17 : 13, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .overlay(
            Circle()
                .strokeBorder(isCurrent ? Color("RoutePath") : .white.opacity(0.9), lineWidth: isCurrent ? 3 : 2)
                .frame(width: isCurrent ? 38 : 28, height: isCurrent ? 38 : 28)
        )
        .accessibilityLabel(
            isDone
                ? "Stop \(number), done"
                : "Stop \(number)\(isCurrent ? ", current" : ""). \(warmth.label)."
        )
    }
}

#Preview("Route mode") {
    NavigationStack {
        RouteModeView(onStartCapture: { _ in })
    }
    .environment(\.appEnvironment, AppEnvironment.preview(tier: .team))
    .modelContainer(Persistence.previewContainer())
}
