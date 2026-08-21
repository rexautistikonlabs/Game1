//
//  Warmth.swift
//  FieldForge
//
//  The Warmth System is the reason this app is worth opening twice. A single
//  tap after every interaction turns a walking route into institutional
//  memory: who was glad to see you, who asked you to come back in the fall,
//  and who should never be knocked on again.
//

import SwiftUI

/// How receptive a contact was, and how likely they are to give again.
///
/// Deliberately a five-point scale with plain-language names. A staffer
/// standing on a sidewalk in the rain will not calibrate an eleven-point
/// likelihood-to-give index, but they will absolutely remember "warm."
enum Warmth: Int, CaseIterable, Codable, Identifiable, Sendable {
    case unrated = 0
    case doNotReturn = 1
    case cool = 2
    case neutral = 3
    case warm = 4
    case champion = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .unrated: return "Not rated"
        case .doNotReturn: return "Do not return"
        case .cool: return "Cool"
        case .neutral: return "Neutral"
        case .warm: return "Warm"
        case .champion: return "Champion"
        }
    }

    /// Shown under the label on the rating control so the scale means the same
    /// thing to every person on the team.
    var guidance: String {
        switch self {
        case .unrated: return "No read yet"
        case .doNotReturn: return "Asked not to be contacted again"
        case .cool: return "Declined, no interest signalled"
        case .neutral: return "Polite, non-committal"
        case .warm: return "Interested, asked us to follow up"
        case .champion: return "Gave, or offered to open doors for us"
        }
    }

    var symbolName: String {
        switch self {
        case .unrated: return "circle.dashed"
        case .doNotReturn: return "hand.raised.fill"
        case .cool: return "snowflake"
        case .neutral: return "equal.circle.fill"
        case .warm: return "sun.max.fill"
        case .champion: return "star.fill"
        }
    }

    /// Map pin and badge colour. Sequential cool-to-warm, and legible in both
    /// appearances — these are Asset Catalog colours, not raw system reds.
    var tint: Color {
        switch self {
        case .unrated: return Color("WarmthUnrated")
        case .doNotReturn: return Color("WarmthDoNotReturn")
        case .cool: return Color("WarmthCool")
        case .neutral: return Color("WarmthNeutral")
        case .warm: return Color("WarmthWarm")
        case .champion: return Color("WarmthChampion")
        }
    }

    /// Never rely on colour alone — VoiceOver and colour-blind users get the
    /// same information from the label, and the map pins carry glyphs.
    var accessibilityDescription: String { "Warmth: \(label). \(guidance)." }

    /// The four ratings a staffer picks from after a visit. `.unrated` is a
    /// state, not a choice, and `.doNotReturn` is deliberately separated in the
    /// UI so it is never tapped by accident.
    static var selectableScale: [Warmth] { [.cool, .neutral, .warm, .champion] }
}

extension Warmth {
    /// Blends the recorded ratings of a contact's visits into one score, with
    /// recent visits weighted more heavily — a business that was cold in 2019
    /// and warm last week is warm.
    ///
    /// `.doNotReturn` is absorbing: once someone asks to be left alone, no
    /// amount of older enthusiasm overrides it.
    static func rollUp(_ ratings: [(warmth: Warmth, date: Date)], now: Date = .now) -> Warmth {
        let rated = ratings.filter { $0.warmth != .unrated }
        guard !rated.isEmpty else { return .unrated }
        if rated.contains(where: { $0.warmth == .doNotReturn }) { return .doNotReturn }

        var weightedTotal = 0.0
        var weightSum = 0.0
        for entry in rated {
            let ageInYears = max(0, now.timeIntervalSince(entry.date)) / (365.25 * 24 * 3600)
            let weight = pow(0.5, ageInYears)   // half-life of one year
            weightedTotal += Double(entry.warmth.rawValue) * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return .unrated }
        let rounded = Int((weightedTotal / weightSum).rounded())
        return Warmth(rawValue: min(5, max(1, rounded))) ?? .neutral
    }
}
