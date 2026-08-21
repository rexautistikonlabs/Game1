//
//  WarmthTests.swift
//  FieldForgeTests
//
//  The warmth roll-up decides the colour of a map pin, which decides where a
//  staffer walks. It has to behave predictably, and "do not return" has to be
//  absolutely sticky.
//

import Foundation
import Testing
@testable import FieldForge

struct WarmthTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    @Test("No ratings means unrated, not neutral")
    func emptyIsUnrated() {
        #expect(Warmth.rollUp([], now: now) == .unrated)
        #expect(Warmth.rollUp([(.unrated, now)], now: now) == .unrated)
    }

    @Test("A single rating is itself")
    func singleRating() {
        #expect(Warmth.rollUp([(.warm, now)], now: now) == .warm)
        #expect(Warmth.rollUp([(.cool, now)], now: now) == .cool)
    }

    @Test("Do-not-return overrides everything, however old and however warm")
    func doNotReturnIsAbsorbing() {
        let signals: [(warmth: Warmth, date: Date)] = [
            (.champion, daysAgo(1)),
            (.champion, daysAgo(2)),
            (.doNotReturn, daysAgo(900)),
        ]
        #expect(Warmth.rollUp(signals, now: now) == .doNotReturn)
    }

    @Test("Recent visits outweigh old ones")
    func recencyWins() {
        // Cold four years ago, warm last week: the business is warm now.
        let signals: [(warmth: Warmth, date: Date)] = [
            (.cool, daysAgo(1_460)),
            (.warm, daysAgo(7)),
        ]
        let result = Warmth.rollUp(signals, now: now)
        #expect(result == .warm)
    }

    @Test("Old enthusiasm decays rather than persisting forever")
    func decay() {
        // Champion five years ago, cool today. The half-life is one year, so
        // the old signal is worth about 3% of the new one.
        let signals: [(warmth: Warmth, date: Date)] = [
            (.champion, daysAgo(1_825)),
            (.cool, now),
        ]
        #expect(Warmth.rollUp(signals, now: now) == .cool)
    }

    @Test("Simultaneous conflicting ratings average out")
    func averaging() {
        let signals: [(warmth: Warmth, date: Date)] = [
            (.cool, now),      // 2
            (.champion, now),  // 5
        ]
        // (2 + 5) / 2 = 3.5, rounds to 4.
        #expect(Warmth.rollUp(signals, now: now) == .warm)
    }

    @Test("The result never escapes the scale")
    func staysInRange() {
        let manyChampions = Array(repeating: (Warmth.champion, now), count: 50)
            .map { (warmth: $0.0, date: $0.1) }
        #expect(Warmth.rollUp(manyChampions, now: now) == .champion)

        let manyCool = Array(repeating: (Warmth.cool, now), count: 50)
            .map { (warmth: $0.0, date: $0.1) }
        let result = Warmth.rollUp(manyCool, now: now)
        #expect(result.rawValue >= Warmth.doNotReturn.rawValue)
        #expect(result.rawValue <= Warmth.champion.rawValue)
    }

    @Test("Future-dated visits do not produce a nonsense weight")
    func futureDates() {
        // Clock skew, or a staffer typing up notes with the wrong date.
        let signals: [(warmth: Warmth, date: Date)] = [
            (.warm, now.addingTimeInterval(86_400 * 30)),
        ]
        #expect(Warmth.rollUp(signals, now: now) == .warm)
    }

    @Test("Every case has a distinct label, glyph and guidance")
    func presentation() {
        var labels = Set<String>()
        var symbols = Set<String>()
        for warmth in Warmth.allCases {
            labels.insert(warmth.label)
            symbols.insert(warmth.symbolName)
            // Colour is never the only signal, so the description must carry
            // the meaning in words.
            #expect(warmth.accessibilityDescription.contains(warmth.label))
            #expect(!warmth.guidance.isEmpty)
        }
        #expect(labels.count == Warmth.allCases.count)
        #expect(symbols.count == Warmth.allCases.count)
    }

    @Test("The selectable scale excludes unrated and do-not-return")
    func selectableScale() {
        #expect(!Warmth.selectableScale.contains(.unrated))
        #expect(!Warmth.selectableScale.contains(.doNotReturn))
        #expect(Warmth.selectableScale.count == 4)
    }
}
