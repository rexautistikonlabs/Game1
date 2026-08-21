//
//  PrimaryButton.swift
//  FieldForge
//
//  The big thumb button. Deliberately larger than a standard control, pinned to
//  the bottom of the screen wherever it appears, because the whole app is used
//  with one hand while the other holds a clipboard, a phone, or a door.
//

import SwiftUI

struct PrimaryButton: View {

    let title: String
    var systemImage: String?
    var role: Role = .primary
    var isLoading: Bool = false
    var isEnabled: Bool = true
    /// Shown under the title when the button needs to explain itself — "no
    /// signal, will send later".
    var subtitle: String?
    let action: () -> Void

    enum Role {
        case primary
        case secondary
        case destructive
    }

    @Environment(\.isEnabled) private var environmentEnabled

    private var effectivelyEnabled: Bool { isEnabled && environmentEnabled && !isLoading }

    var body: some View {
        Button(action: {
            guard effectivelyEnabled else { return }
            Haptics.step()
            action()
        }) {
            HStack(spacing: Space.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .imageScale(.medium)
                }

                VStack(spacing: 1) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Space.primaryActionHeight)
            .padding(.horizontal, Space.md)
            .foregroundStyle(foregroundColor)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: 1)
                }
            }
            .opacity(effectivelyEnabled ? 1 : 0.45)
            // Multi-line at accessibility text sizes rather than truncating.
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .disabled(!effectivelyEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(.isButton)
        // A loading button must announce that it is working, or VoiceOver users
        // tap it again.
        .accessibilityValue(isLoading ? "Working" : "")
    }

    private var foregroundColor: Color {
        switch role {
        case .primary: return .white
        case .secondary: return Palette.textPrimary
        case .destructive: return .white
        }
    }

    private var backgroundStyle: Color {
        switch role {
        case .primary: return Palette.brand
        case .secondary: return Palette.surface
        case .destructive: return Palette.critical
        }
    }
}

/// A bottom bar that keeps the primary action above the home indicator and out
/// from under the keyboard.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Space.sm) {
            content
        }
        .padding(.horizontal, Space.screenEdge)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.sm)
        .background(.bar)
    }
}

#Preview("Primary buttons") {
    VStack(spacing: Space.md) {
        PrimaryButton(title: "Take payment", systemImage: "creditcard.fill") {}
        PrimaryButton(
            title: "Save and send later",
            systemImage: "tray.and.arrow.down.fill",
            subtitle: "No signal — it will send itself"
        ) {}
        PrimaryButton(title: "Skip for now", role: .secondary) {}
        PrimaryButton(title: "Working", isLoading: true) {}
        PrimaryButton(title: "Unavailable", isEnabled: false) {}
    }
    .padding()
    .background(Palette.background)
}
