//
//  Theme.swift
//  FieldForge
//
//  The design system, such as it is. Small on purpose.
//
//  The brief for this app's look: clean, modern, trustworthy, nothing flashy.
//  That translates to concrete rules:
//
//    * Semantic colours only, all from the asset catalog, all defined for both
//      appearances. No raw `.blue`, no hex literals in views.
//    * A four-step type scale that respects Dynamic Type all the way to the
//      accessibility sizes. Nothing is a fixed point size.
//    * An 8pt spacing grid, named, so padding is a decision and not a guess.
//    * Every tappable thing is at least 44×44. Several are much bigger, because
//      this app is used one-handed while walking.
//

import SwiftUI
import UIKit

// MARK: - Colours

/// Semantic colours. Names describe the role, not the hue, so a rebrand is one
/// asset-catalog edit rather than a search-and-replace through the views.
enum Palette {

    // Surfaces
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    static let separator = Color("SeparatorSubtle")

    // Text
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let textTertiary = Color("TextTertiary")

    // Brand and action
    static let brand = Color("BrandDefault")
    static let brandMuted = Color("BrandMuted")

    /// Foreground for content sitting on top of a saturated fill — `brand`,
    /// `critical`, the route accent.
    ///
    /// Not `.white`. Those fills are dark in light mode and *light* in dark
    /// mode, so a hardcoded white foreground drops to about 2.2:1 in dark mode
    /// on every primary button in the app. This pairing keeps it above 7:1 in
    /// both appearances.
    static let onAccent = Color("OnAccent")

    // States
    static let positive = Color("StatePositive")
    static let caution = Color("StateCaution")
    static let critical = Color("StateCritical")
    static let offline = Color("StateOffline")
}

// MARK: - Typography

/// Text styles built on the system styles, so Dynamic Type works everywhere for
/// free and nothing clips at accessibility sizes.
enum Type {
    /// Screen titles.
    static let screenTitle = Font.largeTitle.weight(.bold)
    /// Section headers.
    static let section = Font.headline
    /// Primary body text.
    static let body = Font.body
    /// Supporting text under a row.
    static let secondary = Font.subheadline
    /// Captions, timestamps, metadata.
    static let caption = Font.caption
    /// Small all-caps labels above a value.
    static let label = Font.caption2.weight(.semibold)
    /// Amounts. Monospaced digits so a column of numbers lines up and a
    /// changing amount does not make the layout jitter.
    static let amount = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    static let amountLarge = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    static let amountSmall = Font.system(.body, design: .rounded, weight: .semibold).monospacedDigit()
}

// MARK: - Spacing

/// An 8pt grid with names. `Space.md` is a decision; `padding(12)` is a guess.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// Standard screen edge inset.
    static let screenEdge: CGFloat = 20
    /// Corner radius for cards and buttons.
    static let corner: CGFloat = 14
    static let cornerSmall: CGFloat = 10
    /// The minimum size of anything tappable. Apple's floor, and a real one:
    /// this app is used while walking.
    static let minimumTarget: CGFloat = 44
    /// Height of the big primary actions, which are used with a thumb.
    static let primaryActionHeight: CGFloat = 56
}

// MARK: - Hex colour support

extension Color {
    /// Parses "#1F5F5B" or "1F5F5B". Returns nil for anything else rather than
    /// silently producing black, so a bad brand colour shows the default.
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else { return nil }

        let red, green, blue, alpha: Double
        if cleaned.count == 6 {
            red = Double((value & 0xFF0000) >> 16) / 255
            green = Double((value & 0x00FF00) >> 8) / 255
            blue = Double(value & 0x0000FF) / 255
            alpha = 1
        } else {
            red = Double((value & 0xFF00_0000) >> 24) / 255
            green = Double((value & 0x00FF_0000) >> 16) / 255
            blue = Double((value & 0x0000_FF00) >> 8) / 255
            alpha = Double(value & 0x0000_00FF) / 255
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// "#1F5F5B" from a colour, for storing a brand choice.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded())
        )
    }

    /// Brand colours a nonprofit can pick from without a colour picker. Chosen
    /// to stay legible as PDF text in both light and dark UI.
    static let brandPresets: [String] = [
        "#1F5F5B", // deep teal
        "#1B4965", // navy
        "#2D6A4F", // forest
        "#7B2D26", // brick
        "#5B3E96", // plum
        "#A15C07", // ochre
        "#37474F", // slate
        "#8C1D40", // maroon
    ]
}

// MARK: - Shared view modifiers

extension View {
    /// The standard card treatment: a raised surface with a hairline. Used for
    /// every grouped block in the app so nothing looks bespoke.
    func cardSurface(padding: CGFloat = Space.md) -> some View {
        self
            .padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 0.5)
            )
    }

    /// Guarantees a tap target big enough to hit while walking.
    func minimumTapTarget() -> some View {
        frame(minWidth: Space.minimumTarget, minHeight: Space.minimumTarget)
            .contentShape(Rectangle())
    }

    /// Applies a shake to draw attention to a validation failure, paired with a
    /// haptic. Motion-sensitive users get the haptic and the message only.
    func attentionShake(trigger: Bool) -> some View {
        modifier(AttentionShake(trigger: trigger))
    }
}

private struct AttentionShake: ViewModifier {
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: (trigger && !reduceMotion) ? -6 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.28),
                value: trigger
            )
    }
}
