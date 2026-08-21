//
//  DocumentDetailView.swift
//  FieldForge
//
//  One document: read it, send it again, print it, or re-issue a corrected copy.
//
//  The re-issue behaviour is the part worth understanding. A document that has
//  been handed to a donor is a historical fact and is never edited. Correcting
//  one produces a new document with a revision suffix, marks the original
//  superseded, and keeps both — so if a donor turns up with the old copy, the
//  history explains itself.
//

import PDFKit
import SwiftData
import SwiftUI

struct DocumentDetailView: View {

    let document: GeneratedDocument

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @State private var isPresentingMail = false
    @State private var isPresentingShare = false
    @State private var shareURL: URL?
    @State private var isConfirmingReissue = false
    @State private var statusMessage: String?
    @State private var statusKind: InlineBanner.Kind = .positive
    @State private var pdf: PDFDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let statusMessage {
                    InlineBanner(kind: statusKind, message: statusMessage)
                }

                if document.deliveryState == .superseded {
                    InlineBanner(
                        kind: .caution,
                        message: "This copy has been re-issued. The corrected version is the current one."
                    )
                }

                if let pdf {
                    PDFThumbnailCard(document: pdf)
                }

                factsSection
                sendSection
                integritySection
                reissueSection
            }
            .padding(.horizontal, Space.screenEdge)
            .padding(.bottom, Space.xxl)
        }
        .background(Palette.background)
        .navigationTitle(document.documentNumber)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            pdf = DocumentEngine.pdfDocument(for: document)
        }
        .sheet(isPresented: $isPresentingMail) {
            MailComposer(message: DocumentMessageBuilder.mailMessage(for: document)) { result, _ in
                isPresentingMail = false
                if result == .sent {
                    document.markSent(channel: "Mail")
                    try? context.save()
                    statusKind = .positive
                    statusMessage = "Sent again."
                }
            }
        }
        .sheet(isPresented: $isPresentingShare) {
            if let shareURL {
                DocumentShareSheet(
                    fileURLs: [shareURL],
                    subject: DocumentMessageBuilder.subject(for: document)
                ) { _, completed in
                    isPresentingShare = false
                    guard completed else { return }
                    document.markSent(channel: "Shared")
                    try? context.save()
                }
            }
        }
        .confirmationDialog(
            "Issue a corrected copy?",
            isPresented: $isConfirmingReissue,
            titleVisibility: .visible
        ) {
            Button("Re-issue as \(document.kind.longLabel.lowercased())") {
                reissue(as: document.kind)
            }
            Button("Re-issue as \(document.kind.other.longLabel.lowercased())") {
                reissue(as: document.kind.other)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original stays in your records, marked as re-issued. The new copy gets a revision number so the donor can tell which is current.")
        }
    }

    // MARK: Facts

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "What this says")
            VStack(spacing: Space.xs) {
                LabeledRow(label: "Type", value: document.kind.longLabel, systemImage: document.kind.symbolName)
                LabeledRow(label: "Issued", value: document.issuedAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                LabeledRow(label: "To", value: document.recipientName, systemImage: "person")
                if let inKind = document.inKindDescription.trimmedOrNil {
                    LabeledRow(label: "Donated", value: inKind, systemImage: "shippingbox")
                } else {
                    LabeledRow(label: "Amount", value: document.amount.formatted, systemImage: "dollarsign", isMonospaced: true)
                    if document.deductibleAmountMinorUnits != document.amountMinorUnits {
                        LabeledRow(
                            label: "Deductible",
                            value: document.deductibleAmount.formatted,
                            systemImage: "function",
                            valueColor: Palette.positive,
                            isMonospaced: true
                        )
                    }
                }
                LabeledRow(label: "Method", value: document.giftMethodLabel, systemImage: "creditcard")
                if let fund = document.fundName.trimmedOrNil {
                    LabeledRow(label: "Fund", value: fund, systemImage: "folder")
                }
                if let signatory = document.signatoryName.trimmedOrNil {
                    LabeledRow(label: "Signed by", value: signatory, systemImage: "signature")
                }
            }
            .cardSurface(padding: Space.sm)

            if let language = document.taxLanguageUsed.trimmedOrNil {
                DisclosureGroup("The tax paragraph as issued") {
                    Text(language)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, Space.xs)
                }
                .tint(Palette.brand)
            }
        }
    }

    // MARK: Send

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Send it again")

            LabeledField(
                title: "Email",
                text: Binding(
                    get: { document.recipientEmail },
                    set: { document.recipientEmail = $0; try? context.save() }
                ),
                placeholder: "Where to",
                keyboard: .emailAddress,
                autocapitalization: .never
            )

            if app.reachability.isOnline, MailComposer.canSendMail {
                PrimaryButton(
                    title: "Email it",
                    systemImage: "envelope.fill",
                    isEnabled: document.canBeEmailed
                ) {
                    isPresentingMail = true
                }
            } else {
                PrimaryButton(
                    title: "Queue it",
                    systemImage: "tray.and.arrow.down.fill",
                    isEnabled: document.recipientEmail.trimmedOrNil != nil,
                    subtitle: app.reachability.isOnline ? nil : "Sends itself when you are back on"
                ) {
                    app.outbox.enqueueEmail(for: document)
                    statusKind = .info
                    statusMessage = "Queued."
                }
            }

            HStack(spacing: Space.sm) {
                Button {
                    shareURL = DocumentEngine.temporaryFileURL(for: document)
                    isPresentingShare = shareURL != nil
                } label: {
                    Label("Share or AirDrop", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Space.minimumTarget)
                }
                .buttonStyle(.bordered)

                Button {
                    DocumentPrinter.print(document: document) { completed in
                        guard completed else { return }
                        document.markSent(channel: "Print")
                        try? context.save()
                    }
                } label: {
                    Label("Print", systemImage: "printer")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Space.minimumTarget)
                }
                .buttonStyle(.bordered)
            }

            if let sentAt = document.sentAt {
                Text("Last sent \(sentAt.formatted(date: .abbreviated, time: .shortened)) by \(document.deliveryChannel.trimmedOrNil ?? "an unknown route").")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            if let error = document.lastDeliveryError.trimmedOrNil {
                Text("Last attempt failed: \(error)")
                    .font(Type.caption)
                    .foregroundStyle(Palette.critical)
            }
        }
    }

    // MARK: Integrity

    /// The checksum is not security theatre. A donor and a finance office can
    /// compare it to establish that two copies of a PDF are the same document,
    /// which is occasionally exactly the question in an audit.
    private var integritySection: some View {
        DisclosureGroup("Record details") {
            VStack(alignment: .leading, spacing: Space.xs) {
                LabeledRow(
                    label: "Checksum",
                    value: String(document.pdfChecksum.prefix(16)),
                    systemImage: "number.square"
                )
                LabeledRow(
                    label: "Size",
                    value: Int64(document.pdfData?.count ?? 0).formatted(.byteCount(style: .file)),
                    systemImage: "internaldrive"
                )
                if document.revision > 0 {
                    LabeledRow(label: "Revision", value: "\(document.revision)", systemImage: "arrow.triangle.2.circlepath")
                }
                if let issuer = document.createdByDisplayName.trimmedOrNil {
                    LabeledRow(label: "Issued by", value: issuer, systemImage: "person.badge.shield.checkmark")
                }
            }
            .padding(.top, Space.xs)
        }
        .tint(Palette.brand)
    }

    // MARK: Re-issue

    private var reissueSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                isConfirmingReissue = true
            } label: {
                Label("Issue a corrected copy", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Space.minimumTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.brand)
            .disabled(document.gift == nil)

            if document.gift == nil {
                Text("The original gift record is gone, so this document can only be re-printed as stored.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .cardSurface()
    }

    private func reissue(as kind: DocumentKind) {
        do {
            let reissued = try DocumentEngine.reissue(
                document,
                as: kind,
                includeDeviceTagInNumber: app.entitlements.needsDeviceTaggedDocumentNumbers,
                context: context
            )
            pdf = DocumentEngine.pdfDocument(for: reissued)
            statusKind = .positive
            statusMessage = "Re-issued as \(reissued.documentNumber)."
            Haptics.success()
        } catch {
            statusKind = .critical
            statusMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
