//
//  WarmthBadge.swift
//  FieldForge
//
//  The visual language of the Warmth System: a badge for lists, a picker for
//  rating, and a map pin.
//
//  Accessibility rule observed throughout: colour is never the only signal.
//  Every warmth indicator carries a glyph and a text label, so the scale reads
//  identically to a colour-blind user, in bright sun, and through VoiceOver.
//

import SwiftUI

/// Compact indicator for a list row.
struct WarmthBadge: View {
    let warmth: Warmth
    var showsLabel: Bool = true
    var size: Size = .regular

    enum Size {
        case compact
        case regular

        var glyph: Font {
            switch self {
            case .compact: return .caption2
            case .regular: return .caption
            }
        }

        var padding: (h: CGFloat, v: CGFloat) {
            switch self {
            case .compact: return (5, 2)
            case .regular: return (8, 4)
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: warmth.symbolName)
                .font(size.glyph.weight(.semibold))
            if showsLabel {
                Text(warmth.label)
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, size.padding.h)
        .padding(.vertical, size.padding.v)
        .foregroundStyle(warmth.tint)
        .background(warmth.tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(warmth.accessibilityDescription)
    }
}

/// The one-tap rating control. This is the single most-used control in the app,
/// so it is oversized, labelled, and impossible to mis-tap.
struct WarmthPicker: View {
    @Binding var warmth: Warmth
    /// Shows the "Do not return" option, which is separated so it is never
    /// tapped by accident.
    var showsDoNotReturn: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ForEach(Warmth.selectableScale) { option in
                    button(for: option)
                }
            }

            if warmth != .unrated {
                Text(warmth.guidance)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
                    .accessibilityHidden(true)   // already in the button's label
            }

            if showsDoNotReturn {
                Divider().padding(.vertical, Space.xs)
                Toggle(isOn: Binding(
                    get: { warmth == .doNotReturn },
                    set: { isOn in
                        Haptics.selection()
                        warmth = isOn ? .doNotReturn : .unrated
                    }
                )) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: Warmth.doNotReturn.symbolName)
                            .foregroundStyle(Warmth.doNotReturn.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Do not contact again")
                                .font(Type.body)
                            Text("Stops reminders and greys the map pin")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .tint(Warmth.doNotReturn.tint)
            }
        }
        .animation(.snappy(duration: 0.2), value: warmth)
    }

    private func button(for option: Warmth) -> some View {
        let isSelected = warmth == option
        return Button {
            Haptics.selection()
            // Tapping the current rating clears it — an accidental tap should
            // be undoable without hunting for a reset.
            warmth = isSelected ? .unrated : option
        } label: {
            VStack(spacing: 5) {
                Image(systemName: option.symbolName)
                    .font(.title3.weight(.semibold))
                Text(option.label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .padding(.vertical, Space.sm)
            .foregroundStyle(isSelected ? option.onTintColor : option.tint)
            .background(
                isSelected ? option.tint : option.tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.guidance)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Map annotation.
///
/// Sized and weighted for the actual conditions: held at arm's length, in
/// direct sun, by somebody walking. That means bigger than a system pin (also
/// so it is hittable), a glyph rather than colour alone, and — the part that
/// matters most outdoors — a hard shadow so the pin separates from map tiles
/// even when the screen is washed out and the colour has gone flat.
struct WarmthMapPin: View {
    let warmth: Warmth
    let isSelected: Bool
    var hasOpenFollowUp: Bool = false

    private var diameter: CGFloat { isSelected ? 44 : 34 }

    var body: some View {
        ZStack {
            Circle()
                .fill(warmth.tint)
                .frame(width: diameter, height: diameter)
                // Two shadows: a tight dark one for edge definition in sunlight,
                // and a wider soft one so the pin still reads against a busy
                // map. A single soft shadow disappears outdoors.
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)

            Image(systemName: warmth.symbolName)
                .font(.system(size: isSelected ? 21 : 16, weight: .heavy))
                .foregroundStyle(warmth.onTintColor)

            if hasOpenFollowUp {
                Circle()
                    .fill(Palette.caution)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
                    .offset(x: diameter / 2 - 3, y: -diameter / 2 + 3)
            }
        }
        .overlay(
            // A white halo separates the pin from the map beneath it. Kept
            // white in both appearances deliberately: the map is light in light
            // mode and dark in dark mode, and a white ring is the one that
            // works against both, which is why every mapping app uses it.
            Circle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2.5)
                .frame(width: diameter, height: diameter)
        )
        .accessibilityLabel(warmth.accessibilityDescription)
        .accessibilityValue(hasOpenFollowUp ? "Has an open follow-up" : "")
    }
}

/// Preview host. A plain view rather than `@Previewable`, which is an Xcode 16
/// macro — the project targets iOS 17 and should build on Xcode 15 too.
private struct WarmthPreviewHost: View {
    @State private var warmth: Warmth = .warm

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                ForEach(Warmth.allCases) { WarmthBadge(warmth: $0, size: .compact) }
            }
            WarmthPicker(warmth: $warmth)
            HStack(spacing: Space.md) {
                WarmthMapPin(warmth: .champion, isSelected: true, hasOpenFollowUp: true)
                WarmthMapPin(warmth: .cool, isSelected: false)
                WarmthMapPin(warmth: .doNotReturn, isSelected: false)
            }
        }
        .padding()
        .background(Palette.background)
    }
}

#Preview("Warmth") {
    WarmthPreviewHost()
}
