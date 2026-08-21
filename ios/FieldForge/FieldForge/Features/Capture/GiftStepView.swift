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

import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct GiftStepView: View {

    @Binding var draft: DocumentDraft

    @Environment(\.appEnvironment) private var app

    @Environment(\.modelContext) private var context

    @State private var paymentError: String?
    @State private var showsAdvanced = false
    @State private var isTakingPayment = false
    @State private var isPresentingCamera = false
    @State private var isPresentingPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cameraUnavailableMessage: String?
    /// Attachments created on this screen, so the strip can show them without
    /// a fetch on every keystroke.
    @State private var itemPhotos: [Attachment] = []

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
        .task { reloadItemPhotos() }
        .sheet(isPresented: $isPresentingCamera) {
            ItemCameraView { data in
                savePhoto(data)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isPresentingPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                await loadPickedPhoto(item)
                pickedPhoto = nil
            }
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

            inKindPhotoStrip
        }
        .cardSurface()
    }

    // MARK: In-kind photographs

    /// Photograph the goods, right here.
    ///
    /// The photographs are saved to the store the instant they are taken, not
    /// held in view state — a picture of a pallet of donated food is the one
    /// thing on this screen that cannot be reconstructed if the app dies. The
    /// draft only carries their ids, and `DraftCommitter` links them to the
    /// gift at commit time.
    @ViewBuilder
    private var inKindPhotoStrip: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Photos of the items")
                    .font(Type.label)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if !itemPhotos.isEmpty {
                    Text("\(itemPhotos.count)")
                        .font(Type.caption.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                }
            }

            if let cameraUnavailableMessage {
                InlineBanner(kind: .caution, message: cameraUnavailableMessage)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    Button {
                        presentCamera()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.title3)
                            Text("Photo")
                                .font(.caption2.weight(.medium))
                        }
                        .frame(width: 74, height: 74)
                        .foregroundStyle(Palette.onAccent)
                        .background(Palette.brand, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photograph the donated items")

                    Button {
                        isPresentingPhotoPicker = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.title3)
                            Text("Library")
                                .font(.caption2.weight(.medium))
                        }
                        .frame(width: 74, height: 74)
                        .foregroundStyle(Palette.brand)
                        .background(Palette.brandMuted, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose a photo you already took")

                    ForEach(itemPhotos) { attachment in
                        photoThumbnail(attachment)
                    }
                }
                .padding(.vertical, 2)
            }

            if itemPhotos.isEmpty {
                Text("A photograph makes an in-kind acknowledgment far more convincing, and it is the part nobody can reconstruct later.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if app.activeOrganization()?.includesInKindPhotosInLetter == true {
                Label("These will print in the acknowledgment letter.", systemImage: "doc.richtext")
                    .font(Type.caption)
                    .foregroundStyle(Palette.positive)
            } else {
                Label(
                    "Saved to the record. Turn on “Include in-kind photos in letters” in Settings to print them.",
                    systemImage: "info.circle"
                )
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func photoThumbnail(_ attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = attachment.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                    .fill(Palette.background)
                    .frame(width: 74, height: 74)
                    .overlay(Image(systemName: "photo").foregroundStyle(Palette.textTertiary))
            }

            Button {
                remove(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this photo")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo of the donated items")
    }

    // MARK: Photo actions

    private func presentCamera() {
        guard ItemCameraView.isAvailable else {
            cameraUnavailableMessage = "This device has no camera. Choose a photo from your library instead."
            return
        }
        guard !ItemCameraView.isPermissionDenied else {
            cameraUnavailableMessage = "Camera access is off for FieldForge. Turn it on in Settings, or choose a photo from your library."
            return
        }
        cameraUnavailableMessage = nil
        isPresentingCamera = true
    }

    /// Saves immediately. See the note on `inKindPhotoStrip` for why.
    private func savePhoto(_ data: Data) {
        let attachment = Attachment(
            kind: .inKindItem,
            data: data,
            caption: draft.inKindDescription.trimmedOrNil ?? ""
        )
        attachment.isCapturedLive = true
        attachment.latitude = draft.latitude
        attachment.longitude = draft.longitude
        // The donor's stated value travels with the photo, so a caption in the
        // letter can attribute it to them rather than to the charity.
        attachment.donorEstimatedValueMinorUnits = draft.donorEstimatedValue.minorUnits
        attachment.generateThumbnail()
        context.insert(attachment)

        do {
            try context.save()
            draft.attachmentIDs.append(attachment.id)
            draft.touch()
            itemPhotos.append(attachment)
            Haptics.success()
        } catch {
            AppLog.capture.error("Could not save an in-kind photo: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            cameraUnavailableMessage = "That photo could not be saved. Please try again."
        }
    }

    private func remove(_ attachment: Attachment) {
        Haptics.selection()
        draft.attachmentIDs.removeAll { $0 == attachment.id }
        itemPhotos.removeAll { $0.id == attachment.id }
        context.delete(attachment)
        try? context.save()
        draft.touch()
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            cameraUnavailableMessage = "That photo could not be opened."
            return
        }
        // Same downscale as the camera path, so a library original does not
        // arrive at twelve megapixels.
        guard let jpeg = ItemCameraView.Coordinator.downscaledJPEG(
            image,
            maximumDimension: 1600,
            quality: 0.75
        ) else { return }
        savePhoto(jpeg)
    }

    /// Reloads the strip from the draft, so photos survive leaving and
    /// re-entering the step.
    private func reloadItemPhotos() {
        let ids = draft.attachmentIDs
        guard !ids.isEmpty else {
            itemPhotos = []
            return
        }
        let descriptor = FetchDescriptor<Attachment>(
            predicate: #Predicate { ids.contains($0.id) },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        itemPhotos = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .inKindItem || $0.kind == .photo }
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
