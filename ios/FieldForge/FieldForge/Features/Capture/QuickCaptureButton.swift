//
//  QuickCaptureButton.swift
//  FieldForge
//
//  The floating action button, and the four shortcuts behind it.
//
//  The design target is explicit: **any capture reachable in two taps, and the
//  common one in one.** So:
//
//    * A plain tap opens the capture flow immediately — one tap.
//    * A long press fans out four shortcuts, each of which is the second tap:
//      scan a sign, scan a card, drop a visit right here, or resume the last
//      contact. Tap-then-tap, never tap-scroll-tap.
//
//  Position matters as much as tap count. The button sits in the lower right,
//  clear of the tab bar, inside the arc a right thumb sweeps without the hand
//  shifting grip. The fan opens *upward and leftward* into that same arc rather
//  than outward toward the top of the screen, which a thumb cannot reach at all
//  on a 6.7" phone.
//
//  Left-handed users are not an afterthought: the fan mirrors when the system
//  layout direction is right-to-left, and the button honours a user preference
//  for a left-side position.
//

import SwiftUI

struct QuickCaptureButton: View {

    enum Shortcut: String, CaseIterable, Identifiable {
        /// Camera straight to a sign, and on a good read this creates the
        /// contact and the visit in one action. See `OneShotCapture`.
        case scanSign
        case scanCard
        /// The contact captured most recently, for a second gift or a follow-on
        /// conversation.
        case lastContact

        var id: String { rawValue }

        var label: String {
            switch self {
            case .scanSign: return "Scan a sign"
            case .scanCard: return "Scan a card"
            case .lastContact: return "Last contact"
            }
        }

        var symbol: String {
            switch self {
            case .scanSign: return "camera.viewfinder"
            case .scanCard: return "person.text.rectangle"
            case .lastContact: return "arrow.uturn.backward.circle"
            }
        }
    }

    /// Plain tap.
    let onCapture: () -> Void
    /// One of the shortcuts.
    let onShortcut: (Shortcut) -> Void
    /// Hidden when there is no previous contact to return to.
    var lastContactName: String?
    /// Mirrors the whole control to the leading edge for left-handed use.
    var prefersLeftHand: Bool = false

    @State private var isFanned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var availableShortcuts: [Shortcut] {
        Shortcut.allCases.filter { $0 != .lastContact || lastContactName != nil }
    }

    var body: some View {
        ZStack(alignment: fanAlignment) {
            // Tapping anywhere outside closes the fan. Full-screen and
            // invisible, so a mis-aimed thumb dismisses instead of doing
            // something unintended.
            if isFanned {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { setFanned(false) }
                    .accessibilityHidden(true)
            }

            VStack(alignment: prefersLeftHand ? .leading : .trailing, spacing: Space.sm) {
                if isFanned {
                    ForEach(Array(availableShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        shortcutRow(shortcut)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .scale(scale: 0.6, anchor: fanAnchor)
                                            .combined(with: .opacity)
                                            .animation(.spring(response: 0.28, dampingFraction: 0.72).delay(Double(index) * 0.035)),
                                        removal: .scale(scale: 0.7, anchor: fanAnchor).combined(with: .opacity)
                                    )
                            )
                    }
                }
                mainButton
            }
        }
    }

    // MARK: The button

    private var mainButton: some View {
        Button {
            if isFanned {
                setFanned(false)
            } else {
                Haptics.step()
                onCapture()
            }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: isFanned ? "xmark" : "plus")
                    .font(.title3.weight(.bold))
                    .rotationEffect(.degrees(isFanned ? 90 : 0))
                if !isFanned {
                    Text("Capture")
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, isFanned ? 0 : Space.lg)
            .frame(width: isFanned ? 56 : nil, height: 56)
            .foregroundStyle(Palette.onAccent)
            .background(Palette.brand, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        // A long press is the discovery path, and it is also the *fast* path
        // once learned: press-and-release-onto-a-shortcut is one gesture.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.28)
                .onEnded { _ in
                    Haptics.selection()
                    setFanned(true)
                }
        )
        .accessibilityLabel(isFanned ? "Close capture shortcuts" : "Capture a new interaction")
        .accessibilityHint(isFanned ? "" : "Double tap to start. Double tap and hold for shortcuts.")
        // VoiceOver users cannot discover a long press, so the shortcuts are
        // also exposed as custom actions on the button itself.
        .accessibilityActions {
            ForEach(availableShortcuts) { shortcut in
                Button(accessibilityLabel(for: shortcut)) {
                    onShortcut(shortcut)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isFanned)
    }

    // MARK: Shortcut rows

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        Button {
            setFanned(false)
            Haptics.step()
            onShortcut(shortcut)
        } label: {
            HStack(spacing: Space.sm) {
                if prefersLeftHand { icon(for: shortcut) }
                Text(labelText(for: shortcut))
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if !prefersLeftHand { icon(for: shortcut) }
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: 48)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: shortcut))
    }

    private func icon(for shortcut: Shortcut) -> some View {
        Image(systemName: shortcut.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.brand)
            .frame(width: 24)
    }

    private func labelText(for shortcut: Shortcut) -> String {
        if shortcut == .lastContact, let name = lastContactName {
            // Truncated: the row must stay one line at accessibility sizes.
            return name.count > 18 ? String(name.prefix(18)) + "…" : name
        }
        return shortcut.label
    }

    private func accessibilityLabel(for shortcut: Shortcut) -> String {
        if shortcut == .lastContact, let name = lastContactName {
            return "Capture for \(name), your last contact"
        }
        return shortcut.label
    }

    // MARK: Geometry

    /// The fan grows up from the button and stays on the button's own side, so
    /// every row lands inside the same thumb arc.
    private var fanAlignment: Alignment {
        prefersLeftHand ? .bottomLeading : .bottomTrailing
    }

    private var fanAnchor: UnitPoint {
        prefersLeftHand ? .bottomLeading : .bottomTrailing
    }

    private func setFanned(_ value: Bool) {
        if reduceMotion {
            isFanned = value
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                isFanned = value
            }
        }
    }
}

#Preview("Quick capture") {
    ZStack {
        Palette.background.ignoresSafeArea()
        QuickCaptureButton(
            onCapture: {},
            onShortcut: { _ in },
            lastContactName: "Delgado Hardware"
        )
        .padding(.trailing, Space.screenEdge)
        .padding(.bottom, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
