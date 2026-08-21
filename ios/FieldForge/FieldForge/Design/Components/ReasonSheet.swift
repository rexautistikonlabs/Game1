//
//  ReasonSheet.swift
//  FieldForge
//
//  "Why?" as a sheet.
//
//  Used for voiding and correcting documents. The reason is required rather
//  than optional, because "voided, no reason given" is the least useful entry an
//  audit trail can hold, and because the person who needs it is the staffer's
//  own colleague eighteen months from now.
//
//  Quick reasons are offered as chips. Most voids are one of four things, and
//  tapping "Cheque bounced" beats typing it while standing up.
//

import SwiftUI

struct ReasonSheet: View {

    let title: String
    let explanation: String
    let placeholder: String
    let confirmTitle: String
    var isDestructive: Bool = false
    /// Common answers, tappable. Defaults suit a void; a caller can override.
    var quickReasons: [String] = [
        "Cheque bounced",
        "Duplicate",
        "Wrong donor",
        "Wrong amount",
    ]
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String? { reason.trimmedOrNil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(explanation)
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(placeholder, text: $reason, axis: .vertical)
                    .font(Type.body)
                    .lineLimit(2...5)
                    .focused($isFocused)
                    .padding(Space.sm)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                            .strokeBorder(isFocused ? Palette.brand : Palette.separator, lineWidth: isFocused ? 2 : 0.5)
                    )

                if !quickReasons.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Common reasons")
                            .font(Type.label)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.textSecondary)
                        FlowLayout(spacing: Space.xs) {
                            ForEach(quickReasons, id: \.self) { quick in
                                Button {
                                    Haptics.selection()
                                    reason = quick
                                } label: {
                                    Text(quick)
                                        .font(Type.caption)
                                        .padding(.horizontal, Space.sm)
                                        .frame(minHeight: 34)
                                        .background(Palette.brandMuted, in: Capsule())
                                        .foregroundStyle(Palette.brand)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Use reason: \(quick)")
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Space.screenEdge)
            .background(Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ActionBar {
                    PrimaryButton(
                        title: confirmTitle,
                        systemImage: isDestructive ? "xmark.octagon" : "checkmark",
                        role: isDestructive ? .destructive : .primary,
                        isEnabled: trimmed != nil
                    ) {
                        guard let trimmed else { return }
                        onConfirm(trimmed)
                    }
                    if trimmed == nil {
                        Text("A reason is required — it is the useful half of the record.")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .task {
                // Straight to the keyboard: the sheet exists to collect one
                // sentence, so there is nothing else to look at first.
                try? await Task.sleep(for: .milliseconds(250))
                isFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("Reason sheet") {
    ReasonSheet(
        title: "Why void this?",
        explanation: "The document, its number and its history all stay. Only the reason is being added.",
        placeholder: "Cheque bounced / duplicate / wrong donor",
        confirmTitle: "Void document",
        isDestructive: true
    ) { _ in }
}
