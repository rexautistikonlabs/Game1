//
//  GiftStepView.swift
//  FieldForge
//
//  Step 2: what did they give?
//
//  Ordering here is the feature. When there is signal, Apple Pay and Tap to Pay
//  come first, because a card in hand is a gift that will not evaporate on the
//  walk home. When there is no signal, cash and cheque come first and the dead
//  electronic buttons drop below with a plain explanation. A staffer should
//  never have to scroll past something that cannot work.
//

import SwiftUI

struct GiftStepView: View {

    @Binding var draft: DocumentDraft

    @Environment(\.appEnvironment) private var app

    @State private var paymentError: String?
    @State private var showsAdvanced = false
    @State private var isTakingPayment = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if !app.reachability.isOnline {
                InlineBanner(
                    kind: .info,
                    message: "No signal. Cash, cheques and in-kind gifts all record perfectly — cards need a connection."
                )
            }

            if let paymentError {
                InlineBanner(kind: .critical, message: paymentError)
            }

            if draft.isInKind {
                inKindFields
            } else {
                AmountField(
                    text: Binding(
                        get: { draft.amountText },
                        set: { draft.amountText = $0; draft.touch() }
                    ),
                    currencyCode: app.activeOrganization()?.defaultCurrencyCode ?? "USD",
                    isLocked: draft.isPaymentConfirmed,
                    lockedReason: lockedAmountReason
                )
            }

            methodSection
            fundSection

            if !draft.isInKind, !draft.isPaymentConfirmed {
                electronicPaymentSection
            }

            advancedSection
        }
    }

    // MARK: Amount lock

    private var lockedAmountReason: String? {
        guard draft.isPaymentConfirmed else { return nil }
        let instrument = draft.confirmedInstrumentDescription.trimmedOrNil ?? "the card"
        return "Charged to \(instrument) — the amount now matches what the donor was actually charged."
    }

    // MARK: In-kind

    private var inKindFields: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LabeledField(
                title: "What was donated",
                text: Binding(
                    get: { draft.inKindDescription },
                    set: { draft.inKindDescription = $0; draft.touch() }
                ),
                placeholder: "42 twin blankets, new in packaging",
                autocapitalization: .sentences,
                isRequired: true,
                axis: .vertical
            )

            HStack(spacing: Space.sm) {
                LabeledField(
                    title: "How many",
                    text: Binding(
                        get: { draft.inKindQuantityText },
                        set: { draft.inKindQuantityText = $0; draft.touch() }
                    ),
                    placeholder: "42",
                    keyboard: .numberPad
                )
                LabeledField(
                    title: "Donor's estimate",
                    text: Binding(
                        get: { draft.donorEstimatedValueText },
                        set: { draft.donorEstimatedValueText = $0; draft.touch() }
                    ),
                    placeholder: "If they gave one",
                    keyboard: .decimalPad
                )
            }

            // The single most important sentence on this screen. Charities that
            // put their own valuation on an acknowledgment cause their donors
            // real problems, so the app explains rather than just complying.
            InlineBanner(
                kind: .info,
                message: "The letter will describe the items but will not state a value. Valuing a donated item is the donor's job, not the charity's — that is what the IRS expects."
            )

            Text("A photo of the items makes the record much stronger. Add one from the donor's record after saving.")
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .cardSurface()
    }

    // MARK: Method

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "How did it arrive?")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Space.sm)],
                spacing: Space.sm
            ) {
                ForEach(app.payments.methodOptions) { option in
                    MethodTile(
                        option: option,
                        isSelected: draft.method == option.method
                    ) {
                        select(option)
                    }
                }
            }

            if draft.method == .check {
                LabeledField(
                    title: "Cheque number",
                    text: Binding(
                        get: { draft.referenceNumber },
                        set: { draft.referenceNumber = $0; draft.touch() }
                    ),
                    placeholder: "So it can be reconciled",
                    keyboard: .numbersAndPunctuation
                )
            } else if draft.method == .cardManual {
                LabeledField(
                    title: "Last four digits",
                    text: Binding(
                        get: { draft.referenceNumber },
                        set: { draft.referenceNumber = String($0.filter(\.isNumber).prefix(4)); draft.touch() }
                    ),
                    placeholder: "Never the full number",
                    keyboard: .numberPad
                )
            }

            if draft.method == .pledge {
                InlineBanner(
                    kind: .caution,
                    message: "A pledge is a promise, not a gift. FieldForge will issue a pledge confirmation and a reminder to collect it — not a tax acknowledgment."
                )
            }
        }
    }

    private func select(_ option: PaymentCoordinator.MethodOption) {
        guard option.isEnabled else { return }
        Haptics.selection()
        draft.method = option.method
        paymentError = nil
        // Switching away from in-kind should not leave a stale description
        // sitting on the record.
        if !option.method.isInKind {
            draft.inKindDescription = ""
            draft.inKindQuantityText = ""
            draft.donorEstimatedValueText = ""
        }
        draft.touch()
    }

    // MARK: Fund

    private var fundSection: some View {
        LabeledField(
            title: "Designated for",
            text: Binding(
                get: { draft.fundName },
                set: { draft.fundName = $0; draft.touch() }
            ),
            placeholder: app.activeOrganization()?.defaultFundName ?? "General Fund",
            autocapitalization: .words
        )
    }

    // MARK: Electronic payment

    /// The take-payment button, shown only when the selected method actually
    /// needs a card. Tapping it opens the Apple Pay sheet or the tap reader.
    @ViewBuilder
    private var electronicPaymentSection: some View {
        if draft.method.requiresNetwork {
            VStack(alignment: .leading, spacing: Space.sm) {
                PrimaryButton(
                    title: draft.method == .applePay ? "Charge with Apple Pay" : "Take a tap",
                    systemImage: draft.method.symbolName,
                    isLoading: isTakingPayment,
                    isEnabled: draft.amount.isPositive
                ) {
                    Task { await takePayment() }
                }

                if app.payments.isSimulatingPayments {
                    Text("This build simulates payments. Nothing will actually be charged.")
                        .font(Type.caption)
                        .foregroundStyle(Palette.critical)
                }
            }
        } else if draft.method == .cash || draft.method == .check {
            Label(
                "Nothing to charge — this records straight away, online or off.",
                systemImage: "checkmark.circle"
            )
            .font(Type.caption)
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private func takePayment() async {
        guard let organization = app.activeOrganization() else { return }
        isTakingPayment = true
        paymentError = nil
        defer { isTakingPayment = false }

        let request = app.payments.request(for: draft, organization: organization)
        let outcome = await app.payments.collect(method: draft.method, request: request)

        switch outcome {
        case .captured(let receipt):
            app.payments.apply(receipt, to: &draft)
            Haptics.success()

        case .cancelled:
            // Not an error. Say nothing.
            break

        case .failed(let failure):
            Haptics.warning()
            paymentError = failure.isRetryable
                ? failure.message
                : "\(failure.message) You can still record this as cash, a cheque, or a card taken elsewhere."

        case .unavailable(let reason):
            Haptics.warning()
            paymentError = reason.explanation
            // Move them to something that works rather than leaving them on a
            // dead method.
            draft.method = .cash
            draft.touch()
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        DisclosureGroup("More", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: Space.md) {
                DatePicker(
                    "Date received",
                    selection: Binding(
                        get: { draft.giftDate },
                        set: { draft.giftDate = $0; draft.touch() }
                    ),
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .font(Type.body)

                Toggle(isOn: Binding(
                    get: { draft.providedGoodsOrServices },
                    set: { draft.providedGoodsOrServices = $0; draft.touch() }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("They received something in return")
                            .font(Type.body)
                        Text("A gala seat, a tote bag, an ad in the programme")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .tint(Palette.brand)

                if draft.providedGoodsOrServices {
                    LabeledField(
                        title: "What they received",
                        text: Binding(
                            get: { draft.goodsOrServicesDescription },
                            set: { draft.goodsOrServicesDescription = $0; draft.touch() }
                        ),
                        placeholder: "Two dinner seats",
                        autocapitalization: .sentences
                    )
                    LabeledField(
                        title: "Its fair value",
                        text: Binding(
                            get: { draft.goodsOrServicesValueText },
                            set: { draft.goodsOrServicesValueText = $0; draft.touch() }
                        ),
                        placeholder: "Your good-faith estimate",
                        keyboard: .decimalPad
                    )

                    // Show the arithmetic. This is the number the donor's
                    // accountant will use, so it should not be a surprise.
                    if draft.amount.isPositive {
                        let deductible = Money(
                            minorUnits: max(0, draft.amount.minorUnits - draft.goodsOrServicesValue.minorUnits),
                            currencyCode: draft.amount.currencyCode
                        )
                        LabeledRow(
                            label: "Tax-deductible portion",
                            value: deductible.formatted,
                            systemImage: "function",
                            valueColor: Palette.positive,
                            isMonospaced: true
                        )
                    }
                }

                LabeledField(
                    title: "Note about the gift",
                    text: Binding(
                        get: { draft.giftNotes },
                        set: { draft.giftNotes = $0; draft.touch() }
                    ),
                    placeholder: "Anything finance needs to know",
                    autocapitalization: .sentences,
                    axis: .vertical
                )
            }
            .padding(.top, Space.sm)
        }
        .tint(Palette.brand)
    }
}

// MARK: - Method tile

private struct MethodTile: View {
    let option: PaymentCoordinator.MethodOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: option.method.symbolName)
                    .font(.body.weight(.semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.method.label)
                        .font(Type.secondary.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let reason = option.unavailableReason {
                        Text(reason.shortLabel)
                            .font(.caption2)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.sm)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                    .strokeBorder(isSelected ? Palette.brand : Palette.separator, lineWidth: isSelected ? 2 : 0.5)
            )
            .opacity(option.isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .accessibilityLabel(option.method.label)
        .accessibilityValue(option.unavailableReason?.explanation ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var foreground: Color {
        isSelected ? Palette.brand : Palette.textPrimary
    }

    private var background: Color {
        isSelected ? Palette.brandMuted : Palette.surface
    }
}
