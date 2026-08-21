//
//  OrganizationEditorView.swift
//  FieldForge
//
//  The letterhead editor. This is where a nonprofit's documents stop looking
//  like an app's output and start looking like their own.
//
//  The live preview at the top is the point. Branding decisions made against an
//  abstract form come out wrong; made against a rendering of the actual letter,
//  they come out right the first time.
//

import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct OrganizationEditorView: View {

    @Bindable var organization: Organization

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @State private var logoItem: PhotosPickerItem?
    @State private var isPresentingSignature = false
    @State private var previewKind: DocumentKind = .letter
    @State private var previewData: Data?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        List {
            previewSection
            identitySection
            addressSection
            brandingSection
            signatureSection
            numberingSection
            taxSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Letterhead")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await loadLogo(item) }
        }
        .sheet(isPresented: $isPresentingSignature) {
            SignatureCaptureView { png in
                organization.defaultSignatureData = png
                save()
            }
        }
        .task { await renderPreview() }
        .onChange(of: previewKind) { _, _ in scheduleRender() }
        // Every field that changes the rendered page re-renders the preview.
        // These live on the List rather than on the individual Sections:
        // attaching a modifier to a Section turns it into an ordinary view and
        // silently breaks the List's sectioning.
        .onChange(of: organization.name) { _, _ in scheduleRender() }
        .onChange(of: organization.ein) { _, _ in scheduleRender() }
        .onChange(of: organization.city) { _, _ in scheduleRender() }
        .onChange(of: organization.brandColorHex) { _, _ in scheduleRender() }
        .onChange(of: organization.usesColorBandLetterhead) { _, _ in scheduleRender() }
        .onChange(of: organization.letterheadTagline) { _, _ in scheduleRender() }
        .onChange(of: organization.signatoryName) { _, _ in scheduleRender() }
        .onChange(of: organization.defaultSignatureData) { _, _ in scheduleRender() }
        .onChange(of: organization.printsDonorEstimatedValueOnInKind) { _, _ in scheduleRender() }
        .onChange(of: organization.customTaxNote) { _, _ in scheduleRender() }
        .onChange(of: organization.is501c3) { _, _ in scheduleRender() }
        .onChange(of: organization.addressLine1) { _, _ in scheduleRender() }
    }

    // MARK: Preview

    private var previewSection: some View {
        Section {
            Picker("Preview", selection: $previewKind) {
                ForEach(DocumentKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if let previewData, let pdf = PDFDocument(data: previewData) {
                PDFThumbnailCard(document: pdf)
                    .listRowInsets(EdgeInsets())
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 120)
            }

            if !organization.missingRequiredBrandingFields.isEmpty {
                ForEach(organization.missingRequiredBrandingFields, id: \.self) { missing in
                    Label(missing, systemImage: "exclamationmark.circle.fill")
                        .font(Type.caption)
                        .foregroundStyle(Palette.caution)
                }
            }
            ForEach(organization.brandingSuggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "lightbulb")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("How it will look")
        } footer: {
            Text("This is rendered with example figures, using exactly the templates your real documents use.")
        }
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            TextField("Name on the letterhead", text: $organization.name)
                .textInputAutocapitalization(.words)
                .onSubmit(save)
            TextField("Registered legal name (if different)", text: $organization.legalName)
                .textInputAutocapitalization(.words)
            TextField("EIN — 12-3456789", text: $organization.ein)
                .keyboardType(.numbersAndPunctuation)

            Toggle("We are a 501(c)(3)", isOn: $organization.is501c3)
                .tint(Palette.brand)

            if !organization.is501c3 {
                Label(
                    "Letters will state that contributions are not deductible. That protects your donors.",
                    systemImage: "info.circle"
                )
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
            }

            TextField("Fiscal sponsor (optional)", text: $organization.fiscalSponsorNote)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Who you are")
        } footer: {
            Text("The EIN is what makes an acknowledgment useful to a donor's accountant. A fiscally sponsored project should enter the sponsor here.")
        }
    }

    // MARK: Address

    private var addressSection: some View {
        Section("Where you are") {
            TextField("Street", text: $organization.addressLine1)
                .textInputAutocapitalization(.words)
            TextField("Suite (optional)", text: $organization.addressLine2)
            TextField("City", text: $organization.city)
                .textInputAutocapitalization(.words)
            HStack {
                TextField("State", text: $organization.state)
                    .textInputAutocapitalization(.characters)
                TextField("ZIP", text: $organization.postalCode)
                    .keyboardType(.numbersAndPunctuation)
            }
            TextField("Phone", text: $organization.phone)
                .keyboardType(.phonePad)
            TextField("Email", text: $organization.email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Website", text: $organization.website)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    // MARK: Branding

    private var brandingSection: some View {
        Section {
            HStack(spacing: Space.md) {
                if let data = organization.logoData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 52)
                } else {
                    RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                        .fill(Palette.background)
                        .frame(width: 80, height: 52)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(Palette.textTertiary)
                        )
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    PhotosPicker(selection: $logoItem, matching: .images) {
                        Text(organization.logoData == nil ? "Add a logo" : "Change logo")
                            .font(Type.secondary.weight(.medium))
                    }
                    if organization.logoData != nil {
                        Button("Remove") {
                            organization.logoData = nil
                            save()
                            scheduleRender()
                        }
                        .font(Type.caption)
                        .foregroundStyle(Palette.critical)
                    }
                }
            }

            colorPicker

            Toggle("Full-colour letterhead band", isOn: $organization.usesColorBandLetterhead)
                .tint(Palette.brand)
                .disabled(!app.entitlements.isEnabled(.advancedBranding))

            if !app.entitlements.isEnabled(.advancedBranding) {
                LockedFeatureRow(feature: .advancedBranding)
            }

            TextField("Tagline (optional)", text: $organization.letterheadTagline)
                .textInputAutocapitalization(.sentences)

            if app.entitlements.isEnabled(.advancedBranding) {
                TextField("Footer line (optional)", text: $organization.letterFooterNote)
                    .textInputAutocapitalization(.sentences)
            }
        } header: {
            Text("Branding")
        } footer: {
            Text("A logo and one colour are free, forever. A donor's receipt should never depend on somebody's subscription.")
        }
    }

    /// Preset swatches rather than a full colour picker. Every preset is dark
    /// enough to print legibly, which a free-form picker cannot guarantee.
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Brand colour")
                .font(Type.label)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(Color.brandPresets, id: \.self) { hex in
                        let isSelected = organization.brandColorHex.caseInsensitiveCompare(hex) == .orderedSame
                        Button {
                            Haptics.selection()
                            organization.brandColorHex = hex
                            save()
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? Palette.brand)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle().strokeBorder(
                                        isSelected ? Palette.textPrimary : .clear,
                                        lineWidth: 2.5
                                    )
                                    .padding(-3)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Brand colour \(hex)")
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Signature

    private var signatureSection: some View {
        Section {
            TextField("Who signs letters", text: $organization.signatoryName)
                .textInputAutocapitalization(.words)
            TextField("Their title", text: $organization.signatoryTitle)
                .textInputAutocapitalization(.words)

            if let data = organization.defaultSignatureData, let image = UIImage(data: data) {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 44)
                    Spacer()
                    Button("Change") { isPresentingSignature = true }
                        .font(Type.secondary.weight(.medium))
                }
            } else {
                Button {
                    isPresentingSignature = true
                } label: {
                    Label("Save a signature", systemImage: "signature")
                }
            }
        } header: {
            Text("Signature")
        } footer: {
            Text("Saving one here means you are not drawing a signature with a fingertip at every door. You can still sign an individual document by hand.")
        }
    }

    // MARK: Numbering

    private var numberingSection: some View {
        Section {
            TextField("Receipt prefix", text: $organization.receiptPrefix)
                .textInputAutocapitalization(.characters)
            TextField("Letter prefix", text: $organization.letterPrefix)
                .textInputAutocapitalization(.characters)

            LabeledContent("Next receipt") {
                Text(DocumentNumberer.format(
                    prefix: organization.receiptPrefix.trimmedOrNil ?? "RCT",
                    year: organization.sequenceYear,
                    sequence: organization.nextReceiptSequence,
                    deviceTag: app.entitlements.needsDeviceTaggedDocumentNumbers ? organization.deviceTag : nil
                ))
                .monospaced()
                .foregroundStyle(Palette.textSecondary)
            }
            LabeledContent("Next letter") {
                Text(DocumentNumberer.format(
                    prefix: organization.letterPrefix.trimmedOrNil ?? "ACK",
                    year: organization.sequenceYear,
                    sequence: organization.nextLetterSequence,
                    deviceTag: app.entitlements.needsDeviceTaggedDocumentNumbers ? organization.deviceTag : nil
                ))
                .monospaced()
                .foregroundStyle(Palette.textSecondary)
            }

            TextField("Default fund", text: $organization.defaultFundName)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Numbering")
        } footer: {
            Text(app.entitlements.needsDeviceTaggedDocumentNumbers
                 ? "The two letters at the end are this iPhone's tag, so two people working offline can never mint the same number. Counters reset each January."
                 : "Counters reset each January.")
        }
    }

    // MARK: Tax language

    private var taxSection: some View {
        Section {
            Toggle("Print the donor's estimated value on in-kind letters", isOn: $organization.printsDonorEstimatedValueOnInKind)
                .tint(Palette.brand)

            Label(
                organization.printsDonorEstimatedValueOnInKind
                    ? "The figure will be printed and clearly labelled as the donor's own estimate, not yours."
                    : "Recommended. The safest practice is to describe donated property and let the donor value it.",
                systemImage: organization.printsDonorEstimatedValueOnInKind ? "exclamationmark.triangle" : "checkmark.shield"
            )
            .font(Type.caption)
            .foregroundStyle(organization.printsDonorEstimatedValueOnInKind ? Palette.caution : Palette.positive)

            TextField("Extra sentence for every letter (optional)", text: $organization.customTaxNote, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Tax language")
        } footer: {
            Text("FieldForge follows IRS Publication 1771. If your counsel wants a specific sentence added, put it above and it will appear on every letter.")
        }
    }

    // MARK: Plumbing

    private func loadLogo(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        // Downscale before storing. A 12-megapixel logo would bloat every PDF
        // and every sync, and 600pt on the long edge is more than a letterhead
        // needs even at print resolution.
        let maxDimension: CGFloat = 600
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        // PNG, so a logo with a transparent background stays transparent over
        // the letterhead band.
        organization.logoData = resized.pngData()
        save()
        scheduleRender()
    }

    private func save() {
        organization.touch()
        try? context.save()
    }

    private func scheduleRender() {
        save()
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await renderPreview()
        }
    }

    /// Renders the templates with example figures. Never inserted, never saved,
    /// and it does not advance the document counters.
    private func renderPreview() async {
        let gift = Gift(amount: Money(dollars: 250), method: .applePay)
        gift.fundName = organization.defaultFundName
        gift.isPaymentConfirmed = true
        gift.paymentInstrumentDescription = "Visa 4242"
        gift.currencyCode = organization.defaultCurrencyCode

        let contact = Contact(name: "Delgado Hardware", kind: .business)
        contact.contactPersonName = "Ana Delgado"
        contact.contactPersonTitle = "Owner"
        contact.addressLine1 = "128 River Street"
        contact.city = organization.city.trimmedOrNil ?? "Rockford"
        contact.state = organization.state.trimmedOrNil ?? "IL"
        contact.postalCode = organization.postalCode.trimmedOrNil ?? "61104"

        previewData = DocumentEngine.renderPreview(
            kind: previewKind,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: organization.defaultSignatureData.flatMap(UIImage.init(data:)),
            personalNote: "Your gift arrived the same week we ran out of shelf space, which is the best possible problem to have."
        )
    }
}

#Preview("Letterhead") {
    let container = Persistence.previewContainer()
    let organizations = (try? container.mainContext.fetch(FetchDescriptor<Organization>())) ?? []
    NavigationStack {
        if let organization = organizations.first {
            OrganizationEditorView(organization: organization)
        } else {
            Text("Seed data unavailable")
        }
    }
    .environment(\.appEnvironment, AppEnvironment.preview())
    .modelContainer(container)
}
