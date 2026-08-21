//
//  RootView.swift
//  FieldForge
//
//  Five tabs and one very large button.
//
//  Navigation shape, and why: the capture flow is presented as a sheet from a
//  floating action button rather than living in a tab, because it is a task with
//  a beginning and an end — and because the button can then sit in the bottom
//  third of the screen where a thumb actually reaches. Tabs are for browsing;
//  the button is for working.
//

import SwiftData
import SwiftUI

struct RootView: View {

    @Environment(\.appEnvironment) private var app

    @Environment(\.modelContext) private var context

    /// Most recently touched contact, for the "last contact" shortcut. Limited
    /// to one row so this costs nothing on every render.
    @Query(
        filter: #Predicate<Contact> { $0.isArchived == false },
        sort: \Contact.updatedAt,
        order: .reverse
    )
    private var recentContacts: [Contact]

    /// Left-handed users get the whole capture control mirrored. Stored rather
    /// than guessed: handedness is not something to infer from behaviour.
    @AppStorage("fieldforge.prefersLeftHandedCapture")
    private var prefersLeftHandedCapture = false

    @State private var selectedTab: Tab = .today
    @State private var isPresentingCapture = false
    @State private var resumedDraft: DocumentDraft?
    @State private var isShowingResumePrompt = false
    @State private var oneShotMode: TextCaptureScannerView.Mode?
    @State private var oneShotMessage: String?
    @State private var isPresentingRoute = false

    enum Tab: String, Hashable {
        case today, people, map, documents, settings

        var title: String {
            switch self {
            case .today: return "Today"
            case .people: return "People"
            case .map: return "Map"
            case .documents: return "Documents"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .today: return "sun.horizon.fill"
            case .people: return "person.2.fill"
            case .map: return "map.fill"
            case .documents: return "doc.text.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        ZStack(alignment: prefersLeftHandedCapture ? .bottomLeading : .bottomTrailing) {
            TabView(selection: $selectedTab) {
                TodayView(
                    onStartCapture: startCapture,
                    onStartRoute: { isPresentingRoute = true }
                )
                    .tabItem { Label(Tab.today.title, systemImage: Tab.today.symbol) }
                    .tag(Tab.today)

                PeopleListView(onStartCapture: startCaptureFor)
                    .tabItem { Label(Tab.people.title, systemImage: Tab.people.symbol) }
                    .tag(Tab.people)

                WarmthMapView(onStartCapture: startCaptureFor)
                    .tabItem { Label(Tab.map.title, systemImage: Tab.map.symbol) }
                    .tag(Tab.map)

                DocumentsListView()
                    .tabItem { Label(Tab.documents.title, systemImage: Tab.documents.symbol) }
                    .tag(Tab.documents)

                SettingsView()
                    .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.symbol) }
                    .tag(Tab.settings)
            }
            .tint(Palette.brand)

            // The button is hidden on Settings and Documents: it would be noise
            // over a form, and a floating control over a PDF preview is worse.
            if selectedTab == .today || selectedTab == .people || selectedTab == .map {
                QuickCaptureButton(
                    onCapture: startCapture,
                    onShortcut: handle(shortcut:),
                    lastContactName: lastContact?.displayName,
                    prefersLeftHand: prefersLeftHandedCapture
                )
                .padding(prefersLeftHandedCapture ? .leading : .trailing, Space.screenEdge)
                // Clear of the tab bar, in the bottom third where a thumb
                // reaches without shifting grip.
                .padding(.bottom, 72)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: selectedTab)
        .sheet(isPresented: $isPresentingCapture) {
            NewInteractionFlow(initialDraft: resumedDraft)
                .interactiveDismissDisabled(true)
        }
        // The one-action path: scan, and the contact and visit are already
        // saved by the time the capture flow opens on the gift step.
        .sheet(item: $oneShotMode) { mode in
            TextCaptureScannerView(mode: mode) { candidate, frame in
                Task { await completeOneShot(candidate: candidate, frame: frame, mode: mode) }
            }
        }
        .sheet(isPresented: $isPresentingRoute) {
            NavigationStack {
                RouteModeView(onStartCapture: { contact in
                    isPresentingRoute = false
                    startCaptureFor(contact: contact)
                })
            }
        }
        .task {
            // An unfinished draft means the app died mid-flow. Offering it back
            // is the difference between "the app lost my letter" and "the app
            // remembered".
            if DraftStore.hasDraft, let draft = DraftStore.load(), draft.hasWho || draft.hasWhat {
                resumedDraft = draft
                isShowingResumePrompt = true
            }
        }
        .alert("Pick up where you left off?", isPresented: $isShowingResumePrompt) {
            Button("Continue") { isPresentingCapture = true }
            Button("Start fresh", role: .destructive) {
                DraftStore.clear()
                resumedDraft = nil
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(resumeMessage)
        }
        .overlay(alignment: .top) {
            if let oneShotMessage {
                InlineBanner(kind: .positive, message: oneShotMessage)
                    .padding(.horizontal, Space.screenEdge)
                    .padding(.top, Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        // Self-dismissing: a confirmation that needs dismissing
                        // is another tap, which defeats the point.
                        try? await Task.sleep(for: .seconds(3))
                        self.oneShotMessage = nil
                    }
            } else if let notice = app.globalNotice {
                InlineBanner(kind: .critical, message: notice, actionTitle: "Dismiss") {
                    app.globalNotice = nil
                }
                .padding(.horizontal, Space.screenEdge)
                .padding(.top, Space.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var resumeMessage: String {
        guard let draft = resumedDraft else { return "" }
        let name = draft.newContact.name.trimmedOrNil ?? "a contact"
        if draft.hasWhat {
            return "You had an unfinished \(draft.documentKind.longLabel.lowercased()) for \(name). Nothing was lost."
        }
        return "You had an unfinished visit for \(name). Nothing was lost."
    }

    private var lastContact: Contact? { recentContacts.first }

    private func startCapture() {
        resumedDraft = nil
        isPresentingCapture = true
    }

    /// Second tap of the two-tap promise. Every branch either opens something
    /// immediately or commits a record — none of them lands on another menu.
    private func handle(shortcut: QuickCaptureButton.Shortcut) {
        switch shortcut {
        case .scanSign:
            oneShotMode = .sign
        case .scanCard:
            oneShotMode = .businessCard
        case .lastContact:
            guard let lastContact else { return }
            startCaptureFor(contact: lastContact)
        }
    }

    /// Commits the scan, then opens the flow already past the who-step.
    private func completeOneShot(
        candidate: ParsedContactCandidate,
        frame: Data?,
        mode: TextCaptureScannerView.Mode
    ) async {
        oneShotMode = nil

        guard let organization = app.activeOrganization() else {
            app.globalNotice = OneShotCapture.CaptureError.noOrganization.localizedDescription
            return
        }

        // Never awaited before committing: a fix that has not arrived must not
        // cost the staffer the record.
        let fix = await app.location.currentLocation(maximumAge: 120)

        let capture = OneShotCapture(
            context: context,
            organization: organization,
            staffDisplayName: app.staffDisplayName,
            isSharingActive: app.entitlements.isSharingActive
        )

        do {
            let result = try capture.commit(
                candidate: candidate,
                source: mode.source,
                location: fix,
                attachmentData: frame
            )
            app.projectToTeam(result.contact)
            Haptics.success()

            oneShotMessage = result.matchedExisting
                ? "Back at \(result.contact.displayName) — visit saved."
                : "Added \(result.contact.displayName) and saved the visit."

            resumedDraft = .continuing(
                from: result,
                defaultFund: organization.defaultFundName
            )
            isPresentingCapture = true
        } catch {
            Haptics.warning()
            app.globalNotice = error.localizedDescription
        }
    }

    /// Starts the flow with a contact already chosen, from a list row or a map
    /// pin. Saves the staffer the "who" step entirely.
    private func startCaptureFor(contact: Contact) {
        var draft = DocumentDraft()
        draft.existingContactID = contact.id
        draft.fundName = app.activeOrganization()?.defaultFundName ?? ""
        resumedDraft = draft
        isPresentingCapture = true
    }
}

#Preview("Root") {
    RootView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
