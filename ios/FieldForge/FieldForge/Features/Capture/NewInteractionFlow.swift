//
//  NewInteractionFlow.swift
//  FieldForge
//
//  The four-step capture flow — Who, What, Document, Deliver.
//
//  Everything about this screen is arranged around the fact that a person is
//  standing in front of the staffer, waiting:
//
//    * Four steps, visible, so nobody wonders how much longer this takes.
//    * Every step is skippable except Who. A visit with a name and nothing else
//      is a valid, useful record.
//    * The draft is written to disk on every change. A dropped call at step
//      three loses nothing.
//    * The primary action is a single full-width button at the bottom, always in
//      the same place, always reachable with a thumb.
//    * Cancelling asks first, because backing out of a signed letter by mistake
//      would be infuriating.
//

import SwiftData
import SwiftUI

struct NewInteractionFlow: View {

    /// Pre-populated when resuming a draft, or when a contact was chosen from a
    /// list or a map pin.
    let initialDraft: DocumentDraft?

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var draft = DocumentDraft()
    @State private var step: Step = .who
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var isConfirmingCancel = false
    @State private var committed: DraftCommitter.Result?
    @State private var personalNote = ""

    enum Step: Int, CaseIterable, Identifiable {
        case who, what, document, deliver

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .who: return "Who"
            case .what: return "What"
            case .document: return "Document"
            case .deliver: return "Deliver"
            }
        }

        var symbol: String {
            switch self {
            case .who: return "person.crop.circle"
            case .what: return "dollarsign.circle"
            case .document: return "doc.text"
            case .deliver: return "paperplane"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator(current: step, reachable: reachableSteps) { target in
                    withAnimation(.snappy(duration: 0.22)) { step = target }
                }
                .padding(.horizontal, Space.screenEdge)
                .padding(.vertical, Space.sm)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        switch step {
                        case .who:
                            WhoStepView(draft: $draft)
                        case .what:
                            GiftStepView(draft: $draft)
                        case .document:
                            DocumentStepView(draft: $draft, personalNote: $personalNote)
                        case .deliver:
                            DeliverStepView(draft: $draft, committed: committed)
                        }
                    }
                    .padding(.horizontal, Space.screenEdge)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.xxl)
                }
                .background(Palette.background)
                // Re-measure on step change so the keyboard does not leave the
                // scroll view offset.
                .scrollDismissesKeyboard(.interactively)

                ActionBar {
                    if let errorMessage {
                        InlineBanner(kind: .critical, message: errorMessage)
                    }
                    primaryAction
                    if step != .who {
                        Button("Back") {
                            withAnimation(.snappy(duration: 0.22)) { step = previousStep }
                        }
                        .font(Type.secondary.weight(.medium))
                        .foregroundStyle(Palette.textSecondary)
                        .minimumTapTarget()
                    }
                }
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if draft.hasWho || draft.hasWhat {
                            isConfirmingCancel = true
                        } else {
                            finish(clearingDraft: true)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectivityPill(reachability: app.reachability, queuedCount: app.outbox.pendingCount)
                }
            }
            .confirmationDialog(
                "Discard this?",
                isPresented: $isConfirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Keep it for later") { finish(clearingDraft: false) }
                Button("Discard", role: .destructive) { finish(clearingDraft: true) }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Keeping it means FieldForge will offer to pick this up next time you open the app.")
            }
        }
        .task { await prepare() }
        // The whole promise of never losing a signature, a note, or a photo
        // comes down to this line.
        .onChange(of: draft) { _, newValue in
            DraftStore.save(newValue)
        }
    }

    // MARK: Setup

    private func prepare() async {
        if let initialDraft {
            draft = initialDraft
        } else {
            var fresh = DocumentDraft()
            fresh.fundName = app.activeOrganization()?.defaultFundName ?? ""
            fresh.method = app.reachability.isOnline ? .applePay : .cash
            draft = fresh
        }

        // Jump straight to the first incomplete step when resuming, rather than
        // making the staffer tap through what they already filled in.
        if draft.hasWhat {
            step = .document
        } else if draft.hasWho {
            step = .what
        }

        // A location fix, started immediately and never awaited by the UI. By
        // the time the staffer has typed a name it has usually arrived.
        if draft.latitude == nil {
            if let fix = await app.location.currentLocation() {
                draft.latitude = fix.coordinate.latitude
                draft.longitude = fix.coordinate.longitude
                draft.locationAccuracyMeters = fix.horizontalAccuracy
            }
        }
    }

    // MARK: Steps

    private var reachableSteps: Set<Step> {
        var reachable: Set<Step> = [.who]
        if draft.hasWho { reachable.insert(.what) }
        if draft.hasWho { reachable.insert(.document) }
        if committed != nil { reachable.insert(.deliver) }
        return reachable
    }

    private var previousStep: Step {
        Step(rawValue: max(0, step.rawValue - 1)) ?? .who
    }

    // MARK: Primary action

    @ViewBuilder
    private var primaryAction: some View {
        switch step {
        case .who:
            PrimaryButton(
                title: "Next",
                systemImage: "arrow.right",
                isEnabled: draft.hasWho
            ) {
                advance(to: .what)
            }

        case .what:
            VStack(spacing: Space.sm) {
                PrimaryButton(
                    title: draft.hasWhat ? "Next" : "Log the visit only",
                    systemImage: draft.hasWhat ? "arrow.right" : "checkmark"
                ) {
                    if draft.hasWhat {
                        advance(to: .document)
                    } else {
                        commitVisitOnly()
                    }
                }
                if draft.hasWhat {
                    Text("You can still change the document type on the next step.")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

        case .document:
            PrimaryButton(
                title: issueButtonTitle,
                systemImage: "signature",
                isLoading: isCommitting,
                isEnabled: canIssue
            ) {
                commitWithDocument()
            }

        case .deliver:
            PrimaryButton(title: "Done", systemImage: "checkmark") {
                finish(clearingDraft: true)
            }
        }
    }

    private var issueButtonTitle: String {
        draft.documentKind == .receipt ? "Issue receipt" : "Issue letter"
    }

    private var canIssue: Bool {
        guard !isCommitting, draft.hasWhat else { return false }
        guard let organization = app.activeOrganization() else { return false }
        return organization.isReadyToIssueDocuments
    }

    private func advance(to next: Step) {
        errorMessage = nil
        Haptics.step()
        withAnimation(.snappy(duration: 0.22)) { step = next }
    }

    // MARK: Committing

    private func commitVisitOnly() {
        perform(issueDocument: false) { _ in
            // A visit with no gift has nothing to deliver, so the flow ends
            // here rather than showing an empty delivery step.
            Haptics.success()
            finish(clearingDraft: true)
        }
    }

    private func commitWithDocument() {
        perform(issueDocument: true) { _ in
            Haptics.success()
            advance(to: .deliver)
        }
    }

    private func perform(
        issueDocument: Bool,
        onSuccess: @escaping (DraftCommitter.Result) -> Void
    ) {
        guard let organization = app.activeOrganization() else {
            errorMessage = DraftCommitter.CommitError.noOrganization.localizedDescription
            return
        }
        isCommitting = true
        errorMessage = nil

        let committer = DraftCommitter(
            context: context,
            organization: organization,
            staffDisplayName: app.staffDisplayName,
            entitlements: app.entitlements
        )

        do {
            let result = try committer.commit(
                draft: draft,
                issueDocument: issueDocument,
                personalNote: personalNote
            )
            committed = result

            if let followUp = result.followUp {
                Task { await NotificationScheduler.schedule(followUp) }
            }
            // Fill in the street address later if we only captured coordinates.
            if let latitude = draft.latitude, let longitude = draft.longitude,
               !result.contact.hasResolvedAddress {
                app.outbox.enqueueGeocode(
                    latitude: latitude,
                    longitude: longitude,
                    subjectID: result.contact.id,
                    isVisit: false
                )
            }

            app.projectToTeam(result.contact)

            isCommitting = false
            onSuccess(result)
        } catch {
            isCommitting = false
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    private func finish(clearingDraft: Bool) {
        if clearingDraft { DraftStore.clear() }
        app.outbox.refreshCounts()
        dismiss()
    }
}

// MARK: - Step indicator

/// Four dots and a label. Tappable for steps already reached, so going back to
/// fix a typo is one tap rather than three Backs.
private struct StepIndicator: View {
    let current: NewInteractionFlow.Step
    let reachable: Set<NewInteractionFlow.Step>
    let onSelect: (NewInteractionFlow.Step) -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(NewInteractionFlow.Step.allCases) { step in
                let isCurrent = step == current
                let isReachable = reachable.contains(step)
                let isPast = step.rawValue < current.rawValue

                Button {
                    guard isReachable, !isCurrent else { return }
                    onSelect(step)
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(fill(isCurrent: isCurrent, isPast: isPast))
                                .frame(width: 26, height: 26)
                            if isPast {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Palette.onAccent)
                            } else {
                                Image(systemName: step.symbol)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isCurrent ? .white : Palette.textTertiary)
                            }
                        }
                        Text(step.title)
                            .font(.caption2.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Palette.textPrimary : Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Space.minimumTarget)
                }
                .buttonStyle(.plain)
                .disabled(!isReachable)
                .accessibilityLabel("Step \(step.rawValue + 1) of 4: \(step.title)")
                .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(isReachable ? "Double tap to go to this step" : "Not available yet")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func fill(isCurrent: Bool, isPast: Bool) -> Color {
        if isPast { return Palette.positive }
        if isCurrent { return Palette.brand }
        return Palette.separator
    }
}

#Preview("Capture flow") {
    NewInteractionFlow(initialDraft: nil)
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
