//
//  DocumentStepView.swift
//  FieldForge
//
//  Step 3: the dual document engine, as a screen.
//
//  The toggle at the top is the whole product in one control. Same gift, same
//  donor, same data — two completely different pieces of paper, switched
//  instantly, with a live preview so the staffer can see what they are about to
//  hand over. Nothing is re-entered. Nothing is lost by switching.
//

import PDFKit
import SwiftData
import SwiftUI
import UIKit

struct DocumentStepView: View {

    @Binding var draft: DocumentDraft
    @Binding var personalNote: String

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @State private var previewData: Data?
    @State private var isRendering = false
    @State private var isPresentingSignature = false
    @State private var readiness: DocumentEngine.Readiness?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            documentTypeToggle

            if let readiness, !readiness.blockers.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(readiness.blockers, id: \.self) { blocker in
                        InlineBanner(kind: .critical, message: blocker)
                    }
                }
            }

            if let readiness, !readiness.advisories.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(readiness.advisories, id: \.self) { advisory in
                        InlineBanner(kind: .info, message: advisory)
                    }
                }
            }

            signatureSection

            if draft.documentKind == .letter {
                personalNoteSection
            }

            previewSection
            taxLanguageSection
        }
        .task { await refresh() }
        .onChange(of: draft.documentKind) { _, _ in scheduleRefresh() }
        .onChange(of: draft.signaturePNG) { _, _ in scheduleRefresh() }
        .onChange(of: draft.useSavedSignature) { _, _ in scheduleRefresh() }
        .onChange(of: personalNote) { _, _ in scheduleRefresh() }
        .onChange(of: draft.amountText) { _, _ in scheduleRefresh() }
        .sheet(isPresented: $isPresentingSignature) {
            SignatureCaptureView { png in
                draft.signaturePNG = png
                draft.useSavedSignature = false
                draft.touch()
            }
        }
    }

    // MARK: The toggle

    /// A segmented control, but oversized and with an explanation under it. This
    /// is a consequential choice — a receipt and an IRS acknowledgment are not
    /// interchangeable — so it is worth two lines of copy rather than a tooltip.
    private var documentTypeToggle: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ForEach(DocumentKind.allCases) { kind in
                    Button {
                        guard draft.documentKind != kind else { return }
                        Haptics.selection()
                        draft.documentKind = kind
                        draft.touch()
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: kind.symbolName)
                                .font(.title2)
                            Text(kind.longLabel)
                                .font(Type.secondary.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 78)
                        .padding(Space.sm)
                        .foregroundStyle(draft.documentKind == kind ? Palette.onAccent : Palette.textPrimary)
                        .background(
                            draft.documentKind == kind ? Palette.brand : Palette.surface,
                            in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                                .strokeBorder(Palette.separator, lineWidth: draft.documentKind == kind ? 0 : 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.longLabel)
                    .accessibilityHint(kind.explanation)
                    .accessibilityAddTraits(draft.documentKind == kind ? [.isButton, .isSelected] : .isButton)
                }
            }

            Text(draft.documentKind.explanation)
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
                .animation(.snappy(duration: 0.18), value: draft.documentKind)

            if draft.amount.minorUnits >= TaxLanguage.Threshold.writtenAcknowledgmentRequired,
               draft.documentKind == .receipt,
               !draft.isInKind {
                InlineBanner(
                    kind: .caution,
                    message: "A gift of $250 or more needs a written acknowledgment for the donor to deduct it. The letter is the safer choice here.",
                    actionTitle: "Use the letter"
                ) {
                    draft.documentKind = .letter
                    draft.touch()
                }
            }
        }
    }

    // MARK: Signature

    private var savedSignature: UIImage? {
        app.activeOrganization()?.defaultSignatureData.flatMap(UIImage.init(data:))
    }

    private var currentSignature: UIImage? {
        if let png = draft.signaturePNG { return UIImage(data: png) }
        return draft.useSavedSignature ? savedSignature : nil
    }

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(
                title: "Signature",
                subtitle: draft.documentKind == .letter
                    ? "A signed letter reads as a letter and not a form"
                    : "Optional on a receipt, but it helps"
            )

            if let signature = currentSignature {
                HStack(spacing: Space.md) {
                    Image(uiImage: signature)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 48)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Signature captured")

                    Button("Change") { isPresentingSignature = true }
                        .font(Type.secondary.weight(.medium))
                        .foregroundStyle(Palette.brand)
                        .minimumTapTarget()
                }
                .cardSurface(padding: Space.sm)

                if draft.signaturePNG == nil, savedSignature != nil {
                    Text("Using your saved signature.")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                CaptureRow(
                    symbol: "signature",
                    title: "Sign now",
                    subtitle: "Draw with a finger — it embeds straight into the PDF"
                ) {
                    isPresentingSignature = true
                }

                if savedSignature != nil {
                    Button("Use my saved signature") {
                        draft.signaturePNG = nil
                        draft.useSavedSignature = true
                        draft.touch()
                    }
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.brand)
                    .minimumTapTarget()
                }
            }
        }
    }

    // MARK: Personal note

    /// One typed sentence is the difference between a form letter and a letter.
    private var personalNoteSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            LabeledField(
                title: "Add a personal line",
                text: $personalNote,
                placeholder: "Thank you for the forty blankets — they went out the same afternoon.",
                autocapitalization: .sentences,
                axis: .vertical
            )
            Text("Goes into the body of the letter, above the tax paragraph.")
                .font(Type.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(
                title: "Preview",
                subtitle: "Exactly what they will get"
            )

            ZStack {
                if let previewData, let document = PDFDocument(data: previewData) {
                    PDFThumbnailCard(document: document)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                        .fill(Palette.surface)
                        .frame(height: 260)
                        .overlay {
                            if isRendering {
                                ProgressView()
                            } else {
                                Text("Nothing to preview yet")
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                }
            }
            .animation(.snappy(duration: 0.2), value: previewData)
        }
    }

    // MARK: Tax language

    /// The exact paragraph that will print, shown before it prints. A staffer
    /// should never be surprised by what their organization's letter says.
    @ViewBuilder
    private var taxLanguageSection: some View {
        if let readiness, let paragraph = readiness.substantiationPreview.trimmedOrNil {
            DisclosureGroup("What the tax paragraph will say") {
                Text(paragraph)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Space.xs)
                    .textSelection(.enabled)
            }
            .tint(Palette.brand)
        }
    }

    // MARK: Rendering

    /// Debounced: typing a personal note should not re-render a PDF on every
    /// keystroke, and 300ms is below the threshold anyone notices.
    private func scheduleRefresh() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        guard let organization = app.activeOrganization() else { return }
        isRendering = true
        defer { isRendering = false }

        // A throwaway Gift, never inserted into any context. A SwiftData model
        // that has not been inserted behaves as a plain object, which is
        // exactly what a preview needs: rendering one must not create a record,
        // and must not burn a document number. `renderPreview` reads the
        // counter without advancing it, for the same reason.
        let gift = previewGift(organization: organization)
        let contact = previewContact()

        readiness = DocumentEngine.readiness(
            kind: draft.documentKind,
            gift: gift,
            organization: organization
        )

        previewData = DocumentEngine.renderPreview(
            kind: draft.documentKind,
            gift: gift,
            contact: contact,
            organization: organization,
            signature: currentSignature,
            personalNote: personalNote,
            signatoryNameOverride: draft.signatoryNameOverride.trimmedOrNil,
            signatoryTitleOverride: draft.signatoryTitleOverride.trimmedOrNil
        )
    }

    /// An unsaved, uninserted Gift carrying the draft's values, purely so the
    /// renderers can take their normal input.
    private func previewGift(organization: Organization) -> Gift {
        let gift = Gift(amount: draft.amount, method: draft.method, receivedAt: draft.giftDate)
        gift.currencyCode = organization.defaultCurrencyCode
        gift.fundName = draft.fundName.trimmedOrNil ?? organization.defaultFundName
        gift.referenceNumber = draft.referenceNumber
        gift.transactionIdentifier = draft.confirmedTransactionIdentifier
        gift.paymentInstrumentDescription = draft.confirmedInstrumentDescription
        gift.isPaymentConfirmed = draft.method.requiresNetwork
            ? draft.isPaymentConfirmed
            : (draft.method != .pledge)
        gift.inKindDescription = draft.inKindDescription
        gift.inKindQuantity = draft.inKindQuantity
        gift.donorEstimatedValueMinorUnits = draft.donorEstimatedValue.minorUnits
        gift.providedGoodsOrServices = draft.providedGoodsOrServices
        gift.goodsOrServicesDescription = draft.goodsOrServicesDescription
        gift.goodsOrServicesValueMinorUnits = draft.goodsOrServicesValue.minorUnits
        return gift
    }

    /// The chosen contact, or a stand-in built from the typed fields so the
    /// preview shows a real name and address rather than placeholders.
    private func previewContact() -> Contact? {
        if let id = draft.existingContactID {
            var descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let found = try? context.fetch(descriptor).first { return found }
        }
        guard !draft.newContact.isEmpty else { return nil }
        let fields = draft.newContact
        let contact = Contact(name: fields.name, kind: fields.kind, source: fields.source)
        contact.contactPersonName = fields.contactPersonName
        contact.contactPersonTitle = fields.contactPersonTitle
        contact.email = fields.email
        contact.addressLine1 = fields.addressLine1
        contact.addressLine2 = fields.addressLine2
        contact.city = fields.city
        contact.state = fields.state
        contact.postalCode = fields.postalCode
        return contact
    }
}

// MARK: - Small pieces

struct CaptureRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.step()
            action()
        }) {
            HStack(spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Palette.brand)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .cardSurface(padding: Space.sm)
        }
        .buttonStyle(.plain)
    }
}

/// A tappable first-page thumbnail that opens the full PDF.
struct PDFThumbnailCard: View {
    let document: PDFDocument
    @State private var isPresentingFullPreview = false

    var body: some View {
        Button {
            isPresentingFullPreview = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                PDFPageThumbnail(document: document)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .background(Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                            .strokeBorder(Palette.separator, lineWidth: 0.5)
                    )

                Label("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(Space.sm)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Document preview, \(document.pageCount) pages")
        .accessibilityHint("Double tap to view the whole document")
        .sheet(isPresented: $isPresentingFullPreview) {
            NavigationStack {
                PDFKitView(document: document)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Preview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isPresentingFullPreview = false }
                        }
                    }
            }
        }
    }
}

/// Renders the first page as an image. Cheaper than a live PDFView for a
/// thumbnail, and it does not steal scroll gestures from the form around it.
struct PDFPageThumbnail: View {
    let document: PDFDocument

    var body: some View {
        GeometryReader { proxy in
            if let page = document.page(at: 0) {
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(proxy.size.width / bounds.width, proxy.size.height / bounds.height)
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                Image(uiImage: page.thumbnail(of: size, for: .mediaBox))
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// A full `PDFView`, for reading the document properly.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.usePageViewController(false)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
