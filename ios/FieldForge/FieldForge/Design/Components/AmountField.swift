//
//  AmountField.swift
//  FieldForge
//
//  Typing an amount, fast, with a thumb, without a decimal point.
//
//  The interaction: digits accumulate from the right, the way every card
//  terminal in the world works. Typing 2, 5, 0, 0 gives $25.00. There is no
//  decimal key, so there is no way to accidentally enter $2500 instead of
//  $25.00 — a mistake that ends up on a tax document.
//

import SwiftUI

struct AmountField: View {

    @Binding var text: String
    var currencyCode: String = Locale.current.currency?.identifier ?? "USD"
    var isLocked: Bool = false
    var lockedReason: String?
    /// Common amounts, tappable. Saves four taps on the most frequent gifts.
    var quickAmounts: [Int] = [1000, 2500, 5000, 10000]

    @FocusState private var isFocused: Bool

    private var money: Money {
        Money.parse(text, currencyCode: currencyCode) ?? Money(minorUnits: 0, currencyCode: currencyCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Amount")
                    .font(Type.label)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(money.formatted)
                        .font(Type.amountLarge)
                        .foregroundStyle(money.isPositive ? Palette.textPrimary : Palette.textTertiary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: money.minorUnits)

                    Spacer(minLength: 0)

                    if isLocked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Palette.positive)
                            .accessibilityHidden(true)
                    }
                }

                // The real text field, invisible but focusable. The formatted
                // display above is what the user reads; this is what the
                // keyboard talks to.
                TextField("", text: Binding(
                    get: { text },
                    set: { newValue in
                        guard !isLocked else { return }
                        // Digits only. A pasted "$1,250.00" becomes 125000.
                        let digits = newValue.filter(\.isNumber)
                        // Cap at eight digits: a $999,999.99 doorstep gift is
                        // not a thing, and a typo of nine digits is.
                        text = String(digits.prefix(8))
                    }
                ))
                .keyboardType(.numberPad)
                .focused($isFocused)
                .opacity(0.01)
                .frame(height: 1)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(
                Palette.surface,
                in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                    .strokeBorder(
                        isFocused ? Palette.brand : Palette.separator,
                        lineWidth: isFocused ? 2 : 0.5
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { if !isLocked { isFocused = true } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Amount")
            .accessibilityValue(money.isPositive ? money.formatted : "No amount entered")
            .accessibilityHint(isLocked ? (lockedReason ?? "Locked") : "Double tap to enter an amount")
            .accessibilityAddTraits(isLocked ? [] : .isButton)

            if let lockedReason, isLocked {
                Label(lockedReason, systemImage: "checkmark.seal.fill")
                    .font(Type.caption)
                    .foregroundStyle(Palette.positive)
            } else if !quickAmounts.isEmpty {
                quickAmountRow
            }
        }
        .onAppear {
            // Focus immediately: the amount is nearly always the first thing
            // typed, and one saved tap per gift is a lot of taps.
            if !isLocked, text.isEmpty {
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }

    private var quickAmountRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(quickAmounts, id: \.self) { cents in
                    let amount = Money(minorUnits: cents, currencyCode: currencyCode)
                    Button {
                        Haptics.selection()
                        text = String(cents)
                    } label: {
                        Text(amount.formattedCompact)
                            .font(Type.amountSmall)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: Space.minimumTarget)
                            .background(Palette.brandMuted, in: Capsule())
                            .foregroundStyle(Palette.brand)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set amount to \(amount.formatted)")
                }

                Button {
                    Haptics.selection()
                    text = ""
                } label: {
                    Image(systemName: "delete.backward")
                        .frame(minWidth: Space.minimumTarget, minHeight: Space.minimumTarget)
                        .background(Palette.surface, in: Capsule())
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear amount")
            }
            .padding(.horizontal, 1)
        }
    }
}

#Preview("Amount field") {
    @Previewable @State var text = "2500"
    @Previewable @State var locked = "50000"
    VStack(spacing: Space.lg) {
        AmountField(text: $text)
        AmountField(
            text: $locked,
            isLocked: true,
            lockedReason: "Charged to Visa 4242 — amount cannot be changed"
        )
    }
    .padding()
    .background(Palette.background)
}
