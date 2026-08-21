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

    @State private var selectedTab: Tab = .today
    @State private var isPresentingCapture = false
    @State private var resumedDraft: DocumentDraft?
    @State private var isShowingResumePrompt = false

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
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                TodayView(onStartCapture: startCapture)
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
                CaptureButton(action: startCapture)
                    .padding(.trailing, Space.screenEdge)
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
            if let notice = app.globalNotice {
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

    private func startCapture() {
        resumedDraft = nil
        isPresentingCapture = true
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

/// The floating action button. Oversized, labelled, and the only thing on screen
/// with a shadow — so it reads as the primary action without a tooltip.
private struct CaptureButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.step()
            action()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                Text("Capture")
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 54)
            .foregroundStyle(.white)
            .background(Palette.brand, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture a new interaction")
        .accessibilityHint("Record a visit, take a payment, and issue a receipt or letter")
    }
}

#Preview("Root") {
    RootView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
