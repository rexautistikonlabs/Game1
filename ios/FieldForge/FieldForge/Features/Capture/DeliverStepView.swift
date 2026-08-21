//
//  DeliverStepView.swift
//  FieldForge
//
//  Step 4: get it to them, and record the relationship.
//
//  The document already exists and is saved by the time this screen appears —
//  that is deliberate. Delivery can fail, be cancelled, or be impossible with no
//  signal, and none of those may cost the staffer the document they just made.
//  So this screen is about *sending*, plus the two things that are only worth
//  capturing once the transaction is done: the warmth rating and the follow-up.
//

import MessageUI
import SwiftData
import SwiftUI

struct DeliverStepView: View {

    @Binding var draft: DocumentDraft
    let committed: DraftCommitter.Result?

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @State private var isPresentingMail = false
    @State private var isPresentingShare = false
    @State private var shareURL: URL?
    @State private var deliveryMessage: String?
    @State private var deliveryKind: InlineBanner.Kind = .positive

    private var document: GeneratedDocument? { committed?.document }
    private var contact: Contact? { committed?.contact }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            successHeader

            if let document {
                deliveryOptions(for: document)
            }

            warmthSection
            followUpSection
            notesSection
        }
        .sheet(isPresented: $isPresentingMail) {
            if let document {
                MailComposer(message: DocumentMessageBuilder.mailMessage(for: document)) { result, _ in
                    isPresentingMail = false
                    handleMailResult(result, document: document)
                }
            }
        }
        .sheet(isPresented: $isPresentingShare) {
            if let shareURL, let document {
                DocumentShareSheet(
                    fileURLs: [shareURL],
                    subject: DocumentMessageBuilder.subject(for: document)
                ) { activity, completed in
                    isPresentingShare = false
                    guard completed else { return }
                    document.markSent(channel: friendlyChannelName(activity), actor: app.staffDisplayName)
                    try? context.save()
                    deliveryKind = .positive
                    deliveryMessage = "Sent."
                    Haptics.success()
                }
            }
        }
    }

    // MARK: Header

    private var successHeader: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(Palette.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(Type.section)
                        .foregroundStyle(Palette.textPrimary)
                    if let document {
                        Text(document.documentNumber)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .monospaced()
                    }
                }
            }

            if let deliveryMessage {
                InlineBanner(kind: deliveryKind, message: deliveryMessage)
            }
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        guard let document else { return "Visit saved" }
        let name = contact?.displayName ?? "the donor"
        return "\(document.kind.longLabel.capitalizedFirst) ready for \(name)"
    }

    // MARK: Delivery

    private func deliveryOptions(for document: GeneratedDocument) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Send it")

            if !app.reachability.isOnline {
                InlineBanner(
                    kind: .info,
                    message: "No signal. Queue it and FieldForge will send it the moment you are back on — or AirDrop it right now, which works without any connection."
                )
            }

            LabeledField(
                title: "Email",
                text: Binding(
                    get: { document.recipientEmail },
                    set: { document.recipientEmail = $0; try? context.save() }
                ),
                placeholder: "Where should it go?",
                keyboard: .emailAddress,
                autocapitalization: .never
            )

            if app.reachability.isOnline, MailComposer.canSendMail {
                PrimaryButton(
                    title: "Email it now",
                    systemImage: "envelope.fill",
                    isEnabled: document.recipientEmail.trimmedOrNil != nil
                ) {
                    isPresentingMail = true
                }
            } else {
                PrimaryButton(
                    title: "Queue it to send",
                    systemImage: "tray.and.arrow.down.fill",
                    isEnabled: document.recipientEmail.trimmedOrNil != nil,
                    subtitle: app.reachability.isOnline
                        ? "No Mail account on this iPhone"
                        : "Goes out automatically when you have signal"
                ) {
                    app.outbox.enqueueEmail(for: document)
                    deliveryKind = .info
                    deliveryMessage = "Queued. You will not have to remember it."
                    Haptics.success()
                }
            }

            HStack(spacing: Space.sm) {
                SecondaryAction(title: "AirDrop", symbol: "square.and.arrow.up") {
                    shareURL = DocumentEngine.temporaryFileURL(for: document)
                    isPresentingShare = shareURL != nil
                }
                SecondaryAction(title: "Print", symbol: "printer") {
                    DocumentPrinter.print(document: document) { completed in
                        guard completed else { return }
                        document.markPrinted(actor: app.staffDisplayName)
                        try? context.save()
                        deliveryKind = .positive
                        deliveryMessage = "Sent to the printer."
                    }
                }
                SecondaryAction(title: "Other", symbol: "ellipsis.circle") {
                    shareURL = DocumentEngine.temporaryFileURL(for: document)
                    isPresentingShare = shareURL != nil
                }
            }

            // The reassurance that makes queueing acceptable.
            Text("However you send it, the document is already saved. You can send it again any time from Documents.")
                .font(Type.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func handleMailResult(_ result: MFMailComposeResult, document: GeneratedDocument) {
        switch result {
        case .sent:
            document.markSent(channel: "Mail", actor: app.staffDisplayName)
            deliveryKind = .positive
            deliveryMessage = "Sent."
            Haptics.success()
        case .saved:
            document.markQueued(actor: app.staffDisplayName)
            deliveryKind = .info
            deliveryMessage = "Saved as a draft in Mail."
        case .failed:
            document.markFailed("Mail could not send it", actor: app.staffDisplayName)
            app.outbox.enqueueEmail(for: document)
            deliveryKind = .caution
            deliveryMessage = "Mail could not send it, so it is queued to try again."
        case .cancelled:
            break
        @unknown default:
            break
        }
        try? context.save()
        app.outbox.refreshCounts()
    }

    /// "com.apple.UIKit.activity.AirDrop" is not something to show a person.
    private func friendlyChannelName(_ activityType: String?) -> String {
        guard let activityType else { return "Shared" }
        if activityType.contains("AirDrop") { return "AirDrop" }
        if activityType.contains("Message") { return "Messages" }
        if activityType.contains("Mail") { return "Mail" }
        if activityType.contains("SaveToCameraRoll") { return "Photos" }
        if activityType.contains("CopyToPasteboard") { return "Copied" }
        return "Shared"
    }

    // MARK: Warmth

    /// The one-tap rating, at the end, when the staffer has just had the
    /// conversation and their read is freshest.
    private var warmthSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(
                title: "How did it go?",
                subtitle: "One tap. This is what makes the next visit easier."
            )
            WarmthPicker(warmth: Binding(
                get: { draft.warmth },
                set: { newValue in
                    draft.warmth = newValue
                    draft.touch()
                    applyWarmth(newValue)
                }
            ))
            .cardSurface()
        }
    }

    private func applyWarmth(_ warmth: Warmth) {
        guard let visit = committed?.visit, let contact else { return }
        visit.warmth = warmth
        visit.touch()
        if warmth == .doNotReturn {
            contact.isDoNotContact = true
        }
        contact.recomputeRollups()
        try? context.save()
        // The rating is the single most valuable thing a teammate can inherit,
        // so it goes out the moment it is tapped.
        app.projectToTeam(contact)
    }

    // MARK: Follow-up

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Toggle(isOn: Binding(
                get: { draft.wantsFollowUp },
                set: { draft.wantsFollowUp = $0; draft.touch(); syncFollowUp() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Remind me to follow up")
                        .font(Type.body)
                    Text(suggestedFollowUpDescription)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .tint(Palette.brand)
            .disabled(contact?.isDoNotContact == true)

            if draft.wantsFollowUp {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Picker("What for", selection: Binding(
                        get: { draft.followUpKind },
                        set: { draft.followUpKind = $0; draft.touch(); syncFollowUp() }
                    )) {
                        ForEach(FollowUpKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.brand)

                    DatePicker(
                        "When",
                        selection: Binding(
                            get: { draft.followUpDate },
                            set: { draft.followUpDate = $0; draft.touch(); syncFollowUp() }
                        ),
                        in: Date.now...,
                        displayedComponents: .date
                    )
                    .font(Type.body)

                    LabeledField(
                        title: "What to say",
                        text: Binding(
                            get: { draft.followUpNote },
                            set: { draft.followUpNote = $0; draft.touch(); syncFollowUp() }
                        ),
                        placeholder: "Your future self will thank you",
                        autocapitalization: .sentences,
                        axis: .vertical
                    )
                }
                .cardSurface(padding: Space.sm)
            }

            if contact?.isDoNotContact == true {
                Text("Reminders are off for this contact because they asked not to be contacted again.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var suggestedFollowUpDescription: String {
        guard let days = draft.outcome.suggestedFollowUpDays else {
            return "Not usually needed for this outcome"
        }
        if days >= 300 { return "Suggested: next year's ask" }
        if days >= 60 { return "Suggested: in about \(days / 30) months" }
        return "Suggested: in \(days) days"
    }

    /// The follow-up is created by the committer *before* this screen appears,
    /// so edits here have to be applied to the live record — or create it if the
    /// staffer only decided to add one now.
    private func syncFollowUp() {
        guard let contact else { return }

        if !draft.wantsFollowUp {
            if let existing = committed?.followUp {
                Task { await NotificationScheduler.cancel(existing) }
                context.delete(existing)
                try? context.save()
            }
            return
        }

        let followUp: FollowUp
        if let existing = committed?.followUp {
            followUp = existing
        } else {
            followUp = FollowUp()
            followUp.contact = contact
            followUp.isSharedWithTeam = app.entitlements.isSharingActive
            followUp.assignedToDisplayName = app.staffDisplayName
            context.insert(followUp)
        }

        followUp.kind = draft.followUpKind
        followUp.dueAt = draft.followUpDate
        followUp.note = draft.followUpNote
        followUp.updatedAt = .now
        try? context.save()
        Task { await NotificationScheduler.schedule(followUp) }
    }

    // MARK: Notes and tags

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Anything worth remembering?")

            DictationField(
                text: Binding(
                    get: { draft.visitNotes },
                    set: { draft.visitNotes = $0; draft.touch(); applyNotes() }
                ),
                wasDictated: Binding(
                    get: { draft.visitNotesWereDictated },
                    set: { draft.visitNotesWereDictated = $0; draft.touch() }
                ),
                placeholder: "Ask for Dolores. Best after two. Interested in the winter drive."
            )

            Picker("Best time to catch them", selection: Binding(
                get: { draft.contactWindow },
                set: { draft.contactWindow = $0; draft.touch(); applyContactWindow() }
            )) {
                ForEach(ContactWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.menu)
            .tint(Palette.brand)
        }
    }

    private func applyNotes() {
        guard let visit = committed?.visit else { return }
        visit.notes = draft.visitNotes
        visit.notesWereDictated = draft.visitNotesWereDictated
        visit.touch()
        try? context.save()
    }

    private func applyContactWindow() {
        guard let contact, draft.contactWindow != .unknown else { return }
        contact.contactWindow = draft.contactWindow
        contact.touch()
        try? context.save()
        app.projectToTeam(contact)
    }
}

// MARK: - Secondary action

private struct SecondaryAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.step()
            action()
        }) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 62)
            .foregroundStyle(Palette.brand)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
