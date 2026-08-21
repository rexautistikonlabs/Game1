//
//  FollowUpRow.swift
//  FieldForge
//
//  A reminder with its action attached.
//
//  The button on the right is the whole point. A reminder that only says
//  "follow up with Dolores" is a chore; one that says it and offers a Call
//  button is a completed task. Shared between Today, the follow-ups list and
//  the contact detail screen so the affordance is identical everywhere.
//

import SwiftData
import SwiftUI

struct FollowUpRow: View {

    let followUp: FollowUp

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: Space.md) {
            Button {
                Haptics.success()
                followUp.complete()
                Task { await NotificationScheduler.cancel(followUp) }
                try? context.save()
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(Palette.textTertiary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(followUp.contact?.displayName ?? "Follow up")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                if let note = followUp.note.trimmedOrNil {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: Space.xs) {
                    Label(followUp.kind.label, systemImage: followUp.kind.symbolName)
                    Text("·")
                    Text(followUp.relativeDueDescription)
                    if !followUp.isNotificationScheduled, !followUp.isComplete {
                        Text("·")
                        Image(systemName: "bell.slash")
                            .accessibilityLabel("No notification scheduled")
                    }
                }
                .font(Type.caption)
                .foregroundStyle(followUp.isOverdue ? Palette.critical : Palette.textTertiary)
            }

            Spacer(minLength: Space.sm)

            if let url = actionURL {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: followUp.kind.symbolName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(width: 40, height: 40)
                        .background(Palette.brandMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(followUp.kind.label) \(followUp.contact?.displayName ?? "")")
            }
        }
        .cardSurface(padding: Space.sm)
        .swipeActions(edge: .trailing) {
            Button("Snooze a week") {
                followUp.snooze(byDays: 7)
                Task { await NotificationScheduler.schedule(followUp) }
                try? context.save()
            }
            .tint(Palette.caution)
        }
    }

    /// The one-tap action, when the contact has the means for it. Suppressed
    /// entirely for a do-not-contact record — the button existing at all would
    /// be an invitation to breach it.
    private var actionURL: URL? {
        guard let contact = followUp.contact, !contact.isDoNotContact else { return nil }
        switch followUp.kind {
        case .call, .collectPledge:
            return ContactActions.callURL(for: contact.phone)
        case .text:
            return ContactActions.messageURL(for: contact.phone)
        case .email, .thankYou, .sendDocument:
            return ContactActions.mailURL(for: contact.email, subject: emailSubject)
        case .visitAgain:
            return ContactActions.mapsURL(for: contact)
        case .other:
            return nil
        }
    }

    private var emailSubject: String {
        guard let name = app.activeOrganization()?.name.trimmedOrNil else { return "Thank you" }
        return "Thank you from \(name)"
    }
}
