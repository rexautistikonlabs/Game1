//
//  GiftStepView.swift
//  FieldForge
//
//  Step 2: what did they give?
//
//  Ordering here is the feature. A donor pays on their own phone via a texted
//  or emailed Stripe link. This iPhone’s Wallet is not a charge path — staff
//  Apple Pay is hidden so the operator cannot charge their own card by
//  mistake. Tap to Pay stays Not enabled until Apple grants the entitlement
//  and is not a charge button. When there is no signal, cash and cheque come
//  first.
//

import MessageUI
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct GiftStepView: View {

    @Binding var draft: DocumentDraft
    /// Starts Terminal collect. Selecting Tap to Pay is not a charge.
    var onCollectTapToPay: (() -> Void)? = nil

    @Environment(\.appEnvironment) private var app

    @Environment(\.modelContext) private var context

    @State private var paymentError: String?
    @State private var showsAdvanced = false
    @State private var isCreatingPayLink = false
    @State private var creatingPayLinkChannel: PayLinkChannel?
    @State private var isCheckingPayStatus = false
    @State private var isPresentingMessage = false
    @State private var isPresentingMail = false
    @State private var isAskingForPhone = false
    @State private var isAskingForEmail = false
    @State private var phonePrompt = ""
    @State private var emailPrompt = ""
    @State private var pendingPayLink: PayLink?
    @State private var pendingPayLinkMail: MailComposer.Message?
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

            if !draft.isInKind {
                VStack(alignment: .leading, spacing: Space.lg) {
                    donorPhoneSection
                    donorEmailSection
                    payLinkSection
                    if !draft.isPaymentConfirmed {
                        manualPaymentReassurance
                    }
                }
            }

            advancedSection
        }
        .task {
            reloadItemPhotos()
            syncPhoneFromContact()
            syncEmailFromContact()
        }
        .refreshable { await refreshPayStatus() }
        .sheet(isPresented: $isPresentingMessage) {
            if let link = pendingPayLink {
                MessageComposer(
                    recipients: [resolvedPhone],
                    body: PayLinkMessage.body(
                        organizationName: app.activeOrganization()?.name ?? "",
                        amount: draft.amount,
                        url: link.url
                    )
                ) { _ in
                    isPresentingMessage = false
                }
            }
        }
        .sheet(isPresented: $isPresentingMail) {
            if let message = pendingPayLinkMail {
                MailComposer(message: message) { _, _ in
                    isPresentingMail = false
                }
            }
        }
        .alert("Mobile number", isPresented: $isAskingForPhone) {
            TextField("Phone", text: $phonePrompt)
                .keyboardType(.phonePad)
            Button("Text pay link") {
                draft.newContact.phone = phonePrompt
                draft.touch()
                Task { await sendPayLink(channel: .sms) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pay link is sent as a text. Add a number for this contact first.")
        }
        .alert("Email", isPresented: $isAskingForEmail) {
            TextField("Email", text: $emailPrompt)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Email pay link") {
                draft.newContact.email = emailPrompt
                draft.touch()
                Task { await sendPayLink(channel: .email) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pay link is sent as an email. Add an address for this contact first.")
        }
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

            Toggle("This is leftover inventory", isOn: Binding(
                get: { draft.leftoverInventory },
                set: { draft.isLeftoverInventory = $0; draft.touch() }
            ))
            if draft.leftoverInventory {
                Picker("Category", selection: Binding(
                    get: { draft.leftoverCategory },
                    set: { draft.leftoverCategoryRawValue = $0.rawValue; draft.touch() }
                )) {
                    ForEach(InKindCategory.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                Text("Logs an offer so Today can match it against what we need. No payment.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

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
                        isSelected: draft.method == option.method,
                        simulatedCaption: methodCaption(option)
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

            // No Collect at all while the switch is off, even for a draft
            // restored with .tapToPay already chosen.
            if draft.method == .tapToPay, TapToPayProvider.isTurnedOnInSettings {
                tapToPayCollectSection
            } else if draft.method == .tapToPay {
                InlineBanner(
                    kind: .caution,
                    message: TapToPayCollectUI.turnedOffMessage
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

    @ViewBuilder
    private var tapToPayCollectSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if draft.hasSucceededElectronicPayment {
                Label("Paid — a letter can be issued.", systemImage: "checkmark.seal.fill")
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.positive)
            } else {
                Text("Selecting Tap to Pay is not a charge. Collect starts the reader and waits for a card.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                PrimaryButton(
                    title: "Collect",
                    systemImage: "wave.3.right.circle.fill",
                    isLoading: app.payments.inFlightMethod == .tapToPay,
                    isEnabled: draft.amount.isPositive && app.payments.inFlightMethod == nil
                ) {
                    onCollectTapToPay?()
                }
                Text(TapToPayCollectUI.holdCardPrompt)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
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

    // MARK: Donor phone / email + pay link

    private var resolvedPhone: String {
        if let typed = draft.newContact.phone.trimmedOrNil { return typed }
        return selectedContact?.phone ?? ""
    }

    private var resolvedEmail: String {
        if let typed = draft.newContact.email.trimmedOrNil { return typed }
        return selectedContact?.email ?? ""
    }

    private var selectedContact: Contact? {
        guard let id = draft.existingContactID else { return nil }
        var descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private var donorPhoneSection: some View {
        LabeledField(
            title: "Mobile number",
            text: Binding(
                get: { draft.newContact.phone },
                set: { draft.newContact.phone = $0; draft.touch() }
            ),
            placeholder: "To text the pay link",
            keyboard: .phonePad
        )
    }

    private var donorEmailSection: some View {
        LabeledField(
            title: "Email",
            text: Binding(
                get: { draft.newContact.email },
                set: { draft.newContact.email = $0; draft.touch() }
            ),
            placeholder: "To email the pay link",
            keyboard: .emailAddress,
            autocapitalization: .never
        )
    }

    @ViewBuilder
    private var payLinkSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if draft.method.isPayLink, draft.isPaymentConfirmed {
                Label("Paid — a letter can be issued.", systemImage: "checkmark.seal.fill")
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.positive)
            } else if draft.method.isPayLink, draft.paymentLinkURL != nil {
                InlineBanner(
                    kind: .info,
                    message: "Pay link sent. The gift stays unpaid until Stripe reports succeeded — pull to refresh or tap I got paid."
                )
                PrimaryButton(
                    title: "I got paid",
                    systemImage: "arrow.clockwise",
                    isLoading: isCheckingPayStatus,
                    isEnabled: !isCheckingPayStatus
                ) {
                    Task { await refreshPayStatus() }
                }
            }

            if !draft.isPaymentConfirmed {
                HStack(spacing: Space.sm) {
                    PrimaryButton(
                        title: "Text pay link",
                        systemImage: "message.fill",
                        isLoading: isCreatingPayLink && creatingPayLinkChannel == .sms,
                        isEnabled: draft.amount.isPositive && app.payments.canCreatePayLink && !isCreatingPayLink
                    ) {
                        requestPayLink(channel: .sms)
                    }
                    PrimaryButton(
                        title: "Email pay link",
                        systemImage: "envelope.fill",
                        isLoading: isCreatingPayLink && creatingPayLinkChannel == .email,
                        isEnabled: draft.amount.isPositive && app.payments.canCreatePayLink && !isCreatingPayLink
                    ) {
                        requestPayLink(channel: .email)
                    }
                }

                if !app.reachability.isOnline {
                    Text("Pay links need a connection. Cash and cheques still record.")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    // MARK: Manual methods

    /// Cash and cheque record immediately. Staff Apple Pay is not offered here.
    @ViewBuilder
    private var manualPaymentReassurance: some View {
        if draft.method == .cash || draft.method == .check {
            Label(
                "Nothing to charge — this records straight away, online or off.",
                systemImage: "checkmark.circle"
            )
            .font(Type.caption)
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private func methodCaption(_ option: PaymentCoordinator.MethodOption) -> String? {
        if option.method == .tapToPay, let reason = option.unavailableReason {
            return reason.shortLabel
        }
        return nil
    }

    private func requestPayLink(channel: PayLinkChannel) {
        paymentError = nil
        guard draft.amount.isPositive else { return }
        switch channel {
        case .sms:
            if !PayLinkMessage.isUsablePhone(resolvedPhone) {
                phonePrompt = resolvedPhone
                isAskingForPhone = true
                return
            }
        case .email:
            if !PayLinkMessage.isUsableEmail(resolvedEmail) {
                emailPrompt = resolvedEmail
                isAskingForEmail = true
                return
            }
        }
        Task { await sendPayLink(channel: channel) }
    }

    private func sendPayLink(channel: PayLinkChannel) async {
        guard let organization = app.activeOrganization() else { return }
        switch channel {
        case .sms:
            guard PayLinkMessage.isUsablePhone(resolvedPhone) else {
                phonePrompt = resolvedPhone
                isAskingForPhone = true
                return
            }
        case .email:
            guard PayLinkMessage.isUsableEmail(resolvedEmail) else {
                emailPrompt = resolvedEmail
                isAskingForEmail = true
                return
            }
        }
        isCreatingPayLink = true
        creatingPayLinkChannel = channel
        paymentError = nil
        defer {
            isCreatingPayLink = false
            creatingPayLinkChannel = nil
        }

        let contactName = selectedContact?.displayName
            ?? draft.newContact.name.trimmedOrNil
            ?? draft.newContact.contactPersonName.trimmedOrNil
            ?? ""

        do {
            switch channel {
            case .sms: persistPhoneIfNeeded()
            case .email: persistEmailIfNeeded()
            }
            let link = try await app.payments.createPayLink(
                for: draft,
                organization: organization,
                contactName: contactName,
                channel: channel
            )
            app.payments.applyPayLink(link, to: &draft, channel: channel)
            pendingPayLink = link
            switch channel {
            case .sms: presentPayLinkMessage(link)
            case .email: presentPayLinkEmail(link)
            }
            Haptics.success()
        } catch {
            Haptics.warning()
            paymentError = (error as? LocalizedError)?.errorDescription
                ?? "Could not create a pay link. Try again on a connection."
        }
    }

    private func presentPayLinkMessage(_ link: PayLink) {
        let body = PayLinkMessage.body(
            organizationName: app.activeOrganization()?.name ?? "",
            amount: draft.amount,
            url: link.url
        )
        if MessageComposer.canSendText {
            isPresentingMessage = true
        } else if let url = PayLinkMessage.smsURL(phone: resolvedPhone, body: body) {
            UIApplication.shared.open(url)
        } else {
            paymentError = "Messages is not available on this device. Copy the link from the gift once it is saved."
        }
    }

    private func presentPayLinkEmail(_ link: PayLink) {
        let organizationName = app.activeOrganization()?.name ?? ""
        let subject = PayLinkMessage.emailSubject(
            organizationName: organizationName,
            amount: draft.amount
        )
        let body = PayLinkMessage.emailBody(
            organizationName: organizationName,
            amount: draft.amount,
            url: link.url
        )
        pendingPayLinkMail = MailComposer.Message(
            recipients: [resolvedEmail],
            subject: subject,
            body: body,
            attachmentData: nil,
            attachmentFileName: ""
        )
        if MailComposer.canSendMail {
            isPresentingMail = true
        } else if let url = PayLinkMessage.mailtoURL(
            email: resolvedEmail,
            subject: subject,
            body: body
        ) {
            UIApplication.shared.open(url)
        } else {
            paymentError = "Mail is not available on this device. Copy the link from the gift once it is saved."
        }
    }

    private func refreshPayStatus() async {
        let sessionID = draft.checkoutSessionID ?? ""
        guard draft.method.isPayLink || !sessionID.isEmpty || draft.paymentLinkURL != nil else {
            return
        }
        isCheckingPayStatus = true
        paymentError = nil
        defer { isCheckingPayStatus = false }

        do {
            let status = try await app.payments.refreshPayLinkStatus(
                sessionID: sessionID,
                giftID: draft.id
            )
            app.payments.apply(status, to: &draft)
            if status.paid {
                Haptics.success()
            } else {
                paymentError = "Stripe has not recorded this as succeeded yet."
            }
        } catch {
            Haptics.warning()
            paymentError = (error as? LocalizedError)?.errorDescription
                ?? "Could not check payment status."
        }
    }

    private func syncPhoneFromContact() {
        guard draft.newContact.phone.trimmedOrNil == nil,
              let phone = selectedContact?.phone.trimmedOrNil else { return }
        draft.newContact.phone = phone
        draft.touch()
    }

    private func syncEmailFromContact() {
        guard draft.newContact.email.trimmedOrNil == nil,
              let email = selectedContact?.email.trimmedOrNil else { return }
        draft.newContact.email = email
        draft.touch()
    }

    private func persistPhoneIfNeeded() {
        guard let phone = draft.newContact.phone.trimmedOrNil,
              let contact = selectedContact else { return }
        contact.phone = phone
        try? context.save()
    }

    private func persistEmailIfNeeded() {
        guard let email = draft.newContact.email.trimmedOrNil,
              let contact = selectedContact else { return }
        contact.email = email
        try? context.save()
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
    var simulatedCaption: String? = nil
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
                    if let simulatedCaption {
                        Text(simulatedCaption)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.critical)
                    } else if let reason = option.unavailableReason {
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
