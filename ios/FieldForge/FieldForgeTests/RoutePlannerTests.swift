//
//  RoutePlannerTests.swift
//  FieldForgeTests
//
//  Route mode decides where somebody walks, so the ordering has to be sane and
//  the arithmetic has to be right. These tests use a deliberately simple
//  geometry — points on a line, and a square — where the correct answer is
//  obvious by inspection and a regression is unmistakable.
//

import CoreLocation
import Testing
@testable import FieldForge

@MainActor
struct RoutePlannerTests {

    /// Rockford, Illinois. Real coordinates so the distances are realistic.
    private let origin = CLLocationCoordinate2D(latitude: 42.2588, longitude: -89.0940)

    /// Roughly 111 metres per 0.001° of latitude, so offsets are legible.
    private func north(_ metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + metres / 111_000,
            longitude: origin.longitude
        )
    }

    private func east(_ metres: Double) -> CLLocationCoordinate2D {
        // Longitude degrees shrink with latitude; at 42°N one degree is ~82 km.
        CLLocationCoordinate2D(
            latitude: origin.latitude,
            longitude: origin.longitude + metres / 82_000
        )
    }

    private func candidate(
        _ name: String,
        at coordinate: CLLocationCoordinate2D?,
        warmth: Warmth = .warm
    ) -> RouteCandidate {
        RouteCandidate(
            contactID: UUID(),
            name: name,
            subtitle: "",
            coordinate: coordinate,
            warmth: warmth,
            followUpID: nil,
            followUpKind: nil,
            contactWindow: .unknown
        )
    }

    // MARK: Ordering

    @Test("Stops on a line come out in order, nearest first")
    func ordersAlongALine() {
        let planner = RoutePlanner()
        // Deliberately shuffled input.
        planner.plan(
            candidates: [
                candidate("Far", at: north(900)),
                candidate("Near", at: north(100)),
                candidate("Middle", at: north(500)),
            ],
            from: origin
        )
        #expect(planner.stops.map(\.name) == ["Near", "Middle", "Far"])
    }

    @Test("A square is walked around its perimeter, not across its diagonals")
    func avoidsCrossing() {
        let planner = RoutePlanner()
        let corners = [
            candidate("NE", at: CLLocationCoordinate2D(latitude: north(400).latitude, longitude: east(400).longitude)),
            candidate("N", at: north(400)),
            candidate("E", at: east(400)),
            candidate("Origin-ish", at: north(20)),
        ]
        planner.plan(candidates: corners, from: origin)

        // The exact order depends on the geometry, but the total must beat the
        // worst crossing route by a clear margin — that is what 2-opt buys.
        let total = planner.totalDistance
        #expect(total > 0)
        // A crossing route around a 400m square would be well over 1600m; a
        // sane perimeter walk is comfortably under 1400m.
        #expect(total < 1_500, "Route is \(Int(total))m, which suggests it is crossing itself")
    }

    @Test("Leg and cumulative distances agree with each other")
    func distancesAreConsistent() {
        let planner = RoutePlanner()
        planner.plan(
            candidates: [
                candidate("A", at: north(100)),
                candidate("B", at: north(300)),
                candidate("C", at: north(600)),
            ],
            from: origin
        )

        var running: CLLocationDistance = 0
        for stop in planner.stops {
            running += stop.legDistance
            #expect(abs(stop.cumulativeDistance - running) < 1, "Cumulative distance drifted at \(stop.name)")
        }
        #expect(abs(planner.totalDistance - running) < 1)
    }

    @Test("Stops with no coordinate are dropped, not routed to nowhere")
    func dropsUnlocatableStops() {
        let planner = RoutePlanner()
        planner.plan(
            candidates: [
                candidate("Located", at: north(200)),
                candidate("Unlocated", at: nil),
            ],
            from: origin
        )
        #expect(planner.stops.count == 1)
        #expect(planner.stops.first?.name == "Located")
    }

    @Test("An empty candidate list produces an empty route rather than a crash")
    func emptyInput() {
        let planner = RoutePlanner()
        planner.plan(candidates: [], from: origin)
        #expect(planner.stops.isEmpty)
        #expect(planner.totalDistance == 0)
        #expect(planner.currentStop == nil)
        #expect(!planner.isFinished)   // an empty route is not a finished one
    }

    @Test("A single stop is handled without the 2-opt pass misbehaving")
    func singleStop() {
        let planner = RoutePlanner()
        planner.plan(candidates: [candidate("Only", at: north(250))], from: origin)
        #expect(planner.stops.count == 1)
        #expect(planner.totalDistance > 200)
        #expect(planner.totalDistance < 300)
    }

    // MARK: Progress

    @Test("Marking stops done advances the current stop and then finishes")
    func progress() {
        let planner = RoutePlanner()
        planner.plan(
            candidates: [
                candidate("First", at: north(100)),
                candidate("Second", at: north(400)),
            ],
            from: origin
        )
        planner.start()

        #expect(planner.currentStop?.name == "First")
        #expect(planner.completedCount == 0)
        #expect(!planner.isFinished)

        planner.markDone(stopID: planner.stops[0].id)
        #expect(planner.currentStop?.name == "Second")
        #expect(planner.completedCount == 1)

        planner.markDone(stopID: planner.stops[1].id)
        #expect(planner.currentStop == nil)
        #expect(planner.isFinished)
    }

    @Test("Marking a stop done does not reshuffle the remaining order")
    func orderIsStableMidRoute() {
        let planner = RoutePlanner()
        planner.plan(
            candidates: [
                candidate("A", at: north(100)),
                candidate("B", at: north(300)),
                candidate("C", at: north(700)),
            ],
            from: origin
        )
        let before = planner.stops.map(\.name)
        planner.markDone(stopID: planner.stops[0].id)
        // A staffer part-way along has already decided where they are walking.
        #expect(planner.stops.map(\.name) == before)
    }

    @Test("Clearing resets everything")
    func clear() {
        let planner = RoutePlanner()
        planner.plan(candidates: [candidate("A", at: north(100))], from: origin)
        planner.start()
        planner.clear()
        #expect(planner.stops.isEmpty)
        #expect(!planner.isActive)
        #expect(planner.totalDistance == 0)
    }

    // MARK: Presentation

    @Test("Walking time is plausible and never zero")
    func walkingTime() {
        let planner = RoutePlanner()
        planner.plan(
            candidates: [candidate("A", at: north(810))],
            from: origin
        )
        // 810m at 1.35 m/s is about ten minutes.
        #expect(planner.totalWalkingMinutes >= 9)
        #expect(planner.totalWalkingMinutes <= 11)

        // Even a stop next door reads as at least a minute.
        let tiny = RoutePlanner()
        tiny.plan(candidates: [candidate("Next door", at: north(5))], from: origin)
        #expect(tiny.stops.first?.walkingMinutesFromPrevious == 1)
    }

    @Test("Candidates can be built from a follow-up or from an opportunity")
    func candidateConstruction() {
        let contact = Contact(name: "Delgado Hardware")
        contact.latitude = 42.2588
        contact.longitude = -89.0940
        contact.contactWindow = .afternoon
        contact.warmthRawValue = Warmth.champion.rawValue

        let followUp = FollowUp(kind: .collectPledge, dueAt: .now, note: "Collect the pledge")
        followUp.contact = contact

        let fromFollowUp = RouteCandidate(followUp: followUp)
        #expect(fromFollowUp.name == "Delgado Hardware")
        #expect(fromFollowUp.followUpKind == .collectPledge)
        #expect(fromFollowUp.subtitle == "Collect the pledge")
        #expect(fromFollowUp.contactWindow == .afternoon)

        let fromOpportunity = RouteCandidate(opportunity: contact)
        #expect(fromOpportunity.followUpID == nil)
        #expect(fromOpportunity.warmth == .champion)
    }
}

// MARK: - Reminder timing

struct ReminderTimingTests {

    private let calendar = Calendar.current

    private func midnight(daysFromNow days: Int = 3) -> Date {
        let base = calendar.date(byAdding: .day, value: days, to: .now) ?? .now
        return calendar.startOfDay(for: base)
    }

    @Test("A bare date fires at the contact's own best hour", arguments: [
        (ContactWindow.earlyMorning, 7),
        (ContactWindow.midMorning, 10),
        (ContactWindow.lunch, 11),
        (ContactWindow.afternoon, 14),
        (ContactWindow.evening, 17),
        (ContactWindow.neverDuringRush, 14),
    ])
    func firesAtThePreferredHour(window: ContactWindow, expectedHour: Int) {
        let fire = NotificationScheduler.normalizedFireDate(for: midnight(), window: window)
        #expect(calendar.component(.hour, from: fire) == expectedHour)
    }

    @Test("With no known window it falls back to a civil hour")
    func fallsBackToNine() {
        let fire = NotificationScheduler.normalizedFireDate(for: midnight(), window: .unknown)
        #expect(calendar.component(.hour, from: fire) == NotificationScheduler.defaultHour)
    }

    @Test("A time the staffer chose on purpose is never moved")
    func deliberateTimeIsRespected() {
        let base = calendar.date(byAdding: .day, value: 2, to: .now) ?? .now
        let chosen = calendar.date(bySettingHour: 16, minute: 30, second: 0, of: base) ?? base
        let fire = NotificationScheduler.normalizedFireDate(for: chosen, window: .earlyMorning)
        #expect(fire == chosen)
        #expect(calendar.component(.hour, from: fire) == 16)
        #expect(calendar.component(.minute, from: fire) == 30)
    }

    @Test("A reminder never lands in the small hours")
    func neverFiresAtNight() {
        for window in ContactWindow.allCases {
            let fire = NotificationScheduler.normalizedFireDate(for: midnight(), window: window)
            let hour = calendar.component(.hour, from: fire)
            #expect(hour >= 7, "\(window.label) fires at \(hour):00")
            #expect(hour <= 19, "\(window.label) fires at \(hour):00")
        }
    }

    @Test("Lunch-hour reminders arrive before the window, not during it")
    func lunchArrivesEarly() {
        // 11:45 gives a staffer time to walk there before the rush.
        let (hour, minute) = NotificationScheduler.preferredHour(for: .lunch)
        #expect(hour == 11)
        #expect(minute == 45)
    }
}
