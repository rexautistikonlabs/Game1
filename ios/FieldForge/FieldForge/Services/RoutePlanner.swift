//
//  RoutePlanner.swift
//  FieldForge
//
//  Route mode: put today's follow-ups in walking order.
//
//  The problem it solves is mundane and expensive. A staffer with eleven
//  follow-ups due today opens a list sorted by date and walks a zigzag, because
//  the list has no idea where anything is. Ordering the same eleven stops by
//  geography routinely halves the walking.
//
//  This is a travelling-salesman problem, which is NP-hard, and it does not
//  matter in the slightest: eleven stops is not forty thousand cities. Nearest
//  neighbour followed by 2-opt improvement gets within a few percent of optimal
//  on a dozen points in well under a millisecond, entirely offline, with no
//  routing API and no network. A staffer cannot tell the difference between this
//  and optimal, and can very much tell the difference between this and a
//  zigzag.
//
//  Deliberately straight-line distance rather than street routing: street
//  routing needs a network, and this feature has to work in a basement. The
//  ordering it produces is essentially always the same, because over a few
//  blocks the crow-flies order and the walking order agree.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class RoutePlanner {

    /// One stop on the route.
    struct Stop: Identifiable, Equatable {
        let id: UUID
        let contactID: UUID
        let name: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
        let warmth: Warmth
        /// The follow-up that put this stop on the route, when there is one.
        let followUpID: UUID?
        let followUpKind: FollowUpKind?
        let contactWindow: ContactWindow

        /// Metres from the previous stop. Filled in once the order is decided.
        var legDistance: CLLocationDistance = 0
        /// Metres from the start, cumulative.
        var cumulativeDistance: CLLocationDistance = 0
        var isDone: Bool = false

        static func == (lhs: Stop, rhs: Stop) -> Bool { lhs.id == rhs.id }

        var formattedLeg: String {
            Measurement(value: legDistance, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }

        /// Rough walking time at 1.35 m/s, which is the usual figure for an
        /// adult carrying something.
        var walkingMinutesFromPrevious: Int {
            max(1, Int((legDistance / 1.35 / 60).rounded()))
        }
    }

    private(set) var stops: [Stop] = []
    private(set) var totalDistance: CLLocationDistance = 0
    private(set) var startedAt: Date?
    private(set) var isPlanning = false

    /// Index of the stop the staffer is heading to. Nil when the route is done.
    var currentIndex: Int? {
        stops.firstIndex { !$0.isDone }
    }

    var currentStop: Stop? {
        guard let currentIndex else { return nil }
        return stops[currentIndex]
    }

    var completedCount: Int { stops.filter(\.isDone).count }

    var isActive: Bool { startedAt != nil && !stops.isEmpty }

    var isFinished: Bool { !stops.isEmpty && stops.allSatisfy(\.isDone) }

    var totalWalkingMinutes: Int {
        max(1, Int((totalDistance / 1.35 / 60).rounded()))
    }

    var formattedTotalDistance: String {
        Measurement(value: totalDistance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    // MARK: Building a route

    /// Orders the candidates into a walking route starting from `origin`.
    ///
    /// Candidates with no coordinate are dropped — there is nothing to route to
    /// — and the caller is expected to list them separately rather than
    /// silently losing them.
    func plan(candidates: [RouteCandidate], from origin: CLLocationCoordinate2D) {
        isPlanning = true
        defer { isPlanning = false }

        // Filter and unwrap in one pass, so there is no force unwrap relying on
        // a filter three lines earlier still being correct.
        var remaining = candidates.compactMap { candidate -> Stop? in
            guard let coordinate = candidate.coordinate else { return nil }
            return Stop(
                id: UUID(),
                contactID: candidate.contactID,
                name: candidate.name,
                subtitle: candidate.subtitle,
                coordinate: coordinate,
                warmth: candidate.warmth,
                followUpID: candidate.followUpID,
                followUpKind: candidate.followUpKind,
                contactWindow: candidate.contactWindow
            )
        }
        guard !remaining.isEmpty else {
            stops = []
            totalDistance = 0
            return
        }

        // Nearest neighbour from the staffer's actual position.
        var ordered: [Stop] = []
        var cursor = origin
        while !remaining.isEmpty {
            var bestIndex = 0
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude
            for (index, stop) in remaining.enumerated() {
                let distance = Self.distance(cursor, stop.coordinate)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            var next = remaining.remove(at: bestIndex)
            next.legDistance = bestDistance
            ordered.append(next)
            cursor = next.coordinate
        }

        // 2-opt: repeatedly un-cross any pair of legs that cross. This is what
        // turns "greedy, with one silly backtrack at the end" into something a
        // person would actually walk.
        ordered = Self.twoOptImprove(ordered, origin: origin)

        // Recompute the legs against the final order.
        var cumulative: CLLocationDistance = 0
        var previous = origin
        for index in ordered.indices {
            let leg = Self.distance(previous, ordered[index].coordinate)
            ordered[index].legDistance = leg
            cumulative += leg
            ordered[index].cumulativeDistance = cumulative
            previous = ordered[index].coordinate
        }

        stops = ordered
        totalDistance = cumulative
        AppLog.location.info("Planned a route of \(ordered.count, privacy: .public) stops, \(Int(cumulative), privacy: .public) m")
    }

    func start() {
        startedAt = .now
    }

    func clear() {
        stops = []
        totalDistance = 0
        startedAt = nil
    }

    /// Marks a stop done and leaves the rest of the order alone.
    ///
    /// Deliberately does not re-plan: a staffer part-way along a route has
    /// already decided where they are walking, and having the list reshuffle
    /// under them mid-street would be worse than a slightly stale order.
    func markDone(stopID: UUID) {
        guard let index = stops.firstIndex(where: { $0.id == stopID }) else { return }
        stops[index].isDone = true
    }

    func markSkipped(stopID: UUID) {
        markDone(stopID: stopID)
    }

    /// Re-plans the remaining stops from a new position. Offered as an explicit
    /// action — "re-order from here" — rather than happening automatically.
    func replanRemaining(from origin: CLLocationCoordinate2D) {
        let remaining = stops.filter { !$0.isDone }
        guard remaining.count > 1 else { return }
        let done = stops.filter(\.isDone)

        let candidates = remaining.map {
            RouteCandidate(
                contactID: $0.contactID,
                name: $0.name,
                subtitle: $0.subtitle,
                coordinate: $0.coordinate,
                warmth: $0.warmth,
                followUpID: $0.followUpID,
                followUpKind: $0.followUpKind,
                contactWindow: $0.contactWindow
            )
        }
        plan(candidates: candidates, from: origin)
        stops = done + stops
    }

    // MARK: Geometry

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Standard 2-opt. Bounded iterations so a pathological input cannot spin;
    /// in practice it converges in two or three passes at this scale.
    private static func twoOptImprove(_ route: [Stop], origin: CLLocationCoordinate2D) -> [Stop] {
        guard route.count > 3 else { return route }
        var best = route
        var improved = true
        var passes = 0

        func length(_ stops: [Stop]) -> CLLocationDistance {
            var total: CLLocationDistance = 0
            var previous = origin
            for stop in stops {
                total += distance(previous, stop.coordinate)
                previous = stop.coordinate
            }
            return total
        }

        var bestLength = length(best)

        while improved, passes < 20 {
            improved = false
            passes += 1
            for i in 0..<(best.count - 1) {
                for j in (i + 1)..<best.count {
                    var candidate = best
                    candidate[i...j].reverse()
                    let candidateLength = length(candidate)
                    // A metre of improvement is noise; require something real
                    // so the loop terminates on floating-point wobble.
                    if candidateLength < bestLength - 1 {
                        best = candidate
                        bestLength = candidateLength
                        improved = true
                    }
                }
            }
        }
        return best
    }
}

/// The input to route planning. A plain value so the planner never touches
/// SwiftData and stays trivially testable.
struct RouteCandidate: Identifiable, Equatable {
    var contactID: UUID
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D?
    var warmth: Warmth
    var followUpID: UUID?
    var followUpKind: FollowUpKind?
    var contactWindow: ContactWindow

    var id: UUID { contactID }

    static func == (lhs: RouteCandidate, rhs: RouteCandidate) -> Bool {
        lhs.contactID == rhs.contactID
    }
}

extension RouteCandidate {
    /// From a follow-up that is due.
    init(followUp: FollowUp) {
        let contact = followUp.contact
        self.contactID = contact?.id ?? UUID()
        self.name = contact?.displayName ?? "Follow up"
        self.subtitle = followUp.note.trimmedOrNil ?? followUp.kind.label
        self.coordinate = contact?.coordinate
        self.warmth = contact?.warmth ?? .unrated
        self.followUpID = followUp.id
        self.followUpKind = followUp.kind
        self.contactWindow = contact?.contactWindow ?? .unknown
    }

    /// From a warm contact worth dropping in on, with no follow-up attached.
    init(opportunity contact: Contact) {
        self.contactID = contact.id
        self.name = contact.displayName
        self.subtitle = contact.subtitle
        self.coordinate = contact.coordinate
        self.warmth = contact.warmth
        self.followUpID = nil
        self.followUpKind = nil
        self.contactWindow = contact.contactWindow
    }
}
