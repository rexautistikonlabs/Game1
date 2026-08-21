//
//  WhoStepView.swift
//  FieldForge
//
//  Step 1: who is this?
//
//  Five ways in, ordered by how fast they are:
//    1. Camera at the sign — OCR fills the name and often the address.
//    2. Business card scan.
//    3. A nearby contact we have already met (the highest-value shortcut there
//       is: it turns a cold approach into "good to see you again").
//    4. A contact from the phone's address book.
//    5. Typing a name, which is always available and needs one field.
//

import CoreLocation
import SwiftData
import SwiftUI
import UIKit

struct WhoStepView: View {

    @Binding var draft: DocumentDraft

    @Environment(\.appEnvironment) private var app

    @Query(sort: \Contact.updatedAt, order: .reverse) private var allContacts: [Contact]

    @State private var searchText = ""
    @State private var isPresentingSignScanner = false
    @State private var isPresentingCardScanner = false
    @State private var isPresentingSystemPicker = false
    @State private var scanFeedback: String?
    @State private var isEditingDetails = false
    /// Set when the staffer chose to type a name rather than scan. Without it,
    /// an empty name field would collapse the form the moment it appeared.
    @State private var isTypingManually = false
    @State private var nearby: [Contact] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let contact = selectedContact {
                selectedContactCard(contact)
            } else if !draft.newContact.isEmpty || isTypingManually {
                newContactCard
            } else {
                captureOptions
                nearbySection
                searchSection
            }
        }
        .task { await refreshNearby() }
        .sheet(isPresented: $isPresentingSignScanner) {
            TextCaptureScannerView(mode: .sign) { candidate in
                apply(candidate, source: .signOCR)
            }
        }
        .sheet(isPresented: $isPresentingCardScanner) {
            TextCaptureScannerView(mode: .businessCard) { candidate in
                apply(candidate, source: .businessCard)
            }
        }
        .sheet(isPresented: $isPresentingSystemPicker) {
            SystemContactPicker { contact in
                isPresentingSystemPicker = false
                apply(ContactParser.parse(contact), source: .deviceContacts)
            } onCancel: {
                isPresentingSystemPicker = false
            }
        }
    }

    // MARK: Chosen contact

    private var selectedContact: Contact? {
        guard let id = draft.existingContactID else { return nil }
        return allContacts.first { $0.id == id }
    }

    private func selectedContactCard(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.displayName)
                        .font(Type.section)
                        .foregroundStyle(Palette.textPrimary)
                    Text(contact.subtitle)
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Space.sm)
                WarmthBadge(warmth: contact.warmth)
            }

            if contact.isDoNotContact {
                InlineBanner(
                    kind: .critical,
                    message: contact.doNotContactReason.trimmedOrNil
                        ?? "This contact asked not to be contacted again."
                )
            }

            // The paragraph that makes shared memory worth paying for: the
            // staffer knows who they are talking to before they open their mouth.
            if contact.giftCount > 0 || contact.visitCount > 0 {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if contact.giftCount > 0 {
                        LabeledRow(
                            label: "Given before",
                            value: "\(contact.lifetimeGiving.formatted) over \(contact.giftCount) gift\(contact.giftCount == 1 ? "" : "s")",
                            systemImage: "gift.fill",
                            isMonospaced: true
                        )
                    }
                    if let last = contact.lastVisitAt {
                        LabeledRow(
                            label: "Last visit",
                            value: last.formatted(.relative(presentation: .named)),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    if contact.contactWindow != .unknown {
                        LabeledRow(
                            label: "Best time",
                            value: contact.contactWindow.label,
                            systemImage: "sun.max"
                        )
                    }
                }
                .cardSurface(padding: Space.sm)
            }

            if let notes = contact.sharedNotes.trimmedOrNil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What we know")
                        .font(Type.label)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                    Text(notes)
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: Space.sm)
            }

            Button("Choose someone else") {
                draft.existingContactID = nil
                draft.touch()
            }
            .font(Type.secondary.weight(.medium))
            .foregroundStyle(Palette.brand)
            .minimumTapTarget()
        }
        .cardSurface()
    }

    // MARK: New contact being typed or scanned

    private var newContactCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let scanFeedback {
                InlineBanner(kind: .positive, message: scanFeedback)
            }

            if draft.newContact.source.needsHumanReview {
                InlineBanner(
                    kind: .caution,
                    message: "Read from a photo — worth a glance before it goes on a tax letter."
                )
            }

            LabeledField(
                title: "Name",
                text: Binding(
                    get: { draft.newContact.name },
                    set: { draft.newContact.name = $0; draft.touch() }
                ),
                placeholder: "Business or person",
                autocapitalization: .words,
                isRequired: true
            )

            Picker("Kind", selection: Binding(
                get: { draft.newContact.kind },
                set: { draft.newContact.kind = $0; draft.touch() }
            )) {
                ForEach(ContactKind.allCases) { kind in
                    Label(kind.label, systemImage: kind.symbolName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .tint(Palette.brand)

            DisclosureGroup("More details", isExpanded: $isEditingDetails) {
                VStack(alignment: .leading, spacing: Space.md) {
                    LabeledField(
                        title: "Person",
                        text: Binding(
                            get: { draft.newContact.contactPersonName },
                            set: { draft.newContact.contactPersonName = $0; draft.touch() }
                        ),
                        placeholder: "Ask for…",
                        autocapitalization: .words
                    )
                    LabeledField(
                        title: "Their role",
                        text: Binding(
                            get: { draft.newContact.contactPersonTitle },
                            set: { draft.newContact.contactPersonTitle = $0; draft.touch() }
                        ),
                        placeholder: "Owner, manager…",
                        autocapitalization: .words
                    )
                    LabeledField(
                        title: "Email",
                        text: Binding(
                            get: { draft.newContact.email },
                            set: { draft.newContact.email = $0; draft.touch() }
                        ),
                        placeholder: "For sending the receipt",
                        keyboard: .emailAddress,
                        autocapitalization: .never
                    )
                    LabeledField(
                        title: "Phone",
                        text: Binding(
                            get: { draft.newContact.phone },
                            set: { draft.newContact.phone = $0; draft.touch() }
                        ),
                        placeholder: "",
                        keyboard: .phonePad
                    )
                    LabeledField(
                        title: "Street",
                        text: Binding(
                            get: { draft.newContact.addressLine1 },
                            set: { draft.newContact.addressLine1 = $0; draft.touch() }
                        ),
                        placeholder: "Needed for a mailed letter",
                        autocapitalization: .words
                    )
                    HStack(spacing: Space.sm) {
                        LabeledField(
                            title: "City",
                            text: Binding(
                                get: { draft.newContact.city },
                                set: { draft.newContact.city = $0; draft.touch() }
                            ),
                            placeholder: "",
                            autocapitalization: .words
                        )
                        LabeledField(
                            title: "State",
                            text: Binding(
                                get: { draft.newContact.state },
                                set: { draft.newContact.state = $0; draft.touch() }
                            ),
                            placeholder: "",
                            autocapitalization: .characters
                        )
                        .frame(width: 90)
                        LabeledField(
                            title: "ZIP",
                            text: Binding(
                                get: { draft.newContact.postalCode },
                                set: { draft.newContact.postalCode = $0; draft.touch() }
                            ),
                            placeholder: "",
                            keyboard: .numbersAndPunctuation
                        )
                        .frame(width: 100)
                    }
                }
                .padding(.top, Space.sm)
            }
            .tint(Palette.brand)

            if draft.latitude != nil {
                Label("Location captured", systemImage: "mappin.and.ellipse")
                    .font(Type.caption)
                    .foregroundStyle(Palette.positive)
            }

            Button("Start over") {
                draft.newContact = DocumentDraft.NewContactFields()
                scanFeedback = nil
                isTypingManually = false
                draft.touch()
            }
            .font(Type.secondary.weight(.medium))
            .foregroundStyle(Palette.textSecondary)
            .minimumTapTarget()
        }
        .cardSurface()
    }

    // MARK: Capture options

    private var captureOptions: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Who are you with?", subtitle: "The fastest way is usually the camera")

            CaptureOptionRow(
                symbol: "camera.viewfinder",
                title: "Photograph the sign",
                subtitle: "Reads the name and address off the storefront",
                isPrimary: true
            ) {
                isPresentingSignScanner = true
            }

            CaptureOptionRow(
                symbol: "person.text.rectangle",
                title: "Scan a business card"
            ) {
                isPresentingCardScanner = true
            }

            CaptureOptionRow(
                symbol: "person.crop.circle.badge.plus",
                title: "From my contacts"
            ) {
                isPresentingSystemPicker = true
            }

            CaptureOptionRow(
                symbol: "keyboard",
                title: "Type a name"
            ) {
                isTypingManually = true
                draft.newContact.source = .manual
                draft.touch()
            }
        }
    }

    // MARK: Nearby known contacts

    /// Contacts within a couple of hundred metres. This is the shortcut that
    /// makes shared memory pay for itself — walking up to a business somebody
    /// else already visited and knowing it.
    @ViewBuilder
    private var nearbySection: some View {
        if !nearby.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(title: "Right here", subtitle: "Already in your records")
                ForEach(nearby.prefix(5)) { contact in
                    ContactPickRow(contact: contact) {
                        choose(contact)
                    }
                }
            }
        }
    }

    private func refreshNearby() async {
        guard let fix = await app.location.currentLocation(maximumAge: 120) else { return }
        let radius: CLLocationDistance = 250
        nearby = allContacts
            .filter { !$0.isArchived }
            .compactMap { contact -> (Contact, CLLocationDistance)? in
                guard let coordinate = contact.coordinate else { return nil }
                let distance = fix.distance(from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ))
                return distance <= radius ? (contact, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: Search

    private var searchResults: [Contact] {
        guard let query = searchText.trimmedOrNil?.lowercased() else { return [] }
        return allContacts
            .filter { contact in
                contact.displayName.lowercased().contains(query)
                    || contact.contactPersonName.lowercased().contains(query)
                    || contact.city.lowercased().contains(query)
                    || contact.tags.contains { $0.lowercased().contains(query) }
            }
            .prefix(8)
            .map { $0 }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader(title: "Or find someone")
            TextField("Search your contacts", text: $searchText)
                .textFieldStyle(.plain)
                .padding(Space.sm)
                .frame(minHeight: Space.minimumTarget)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: 0.5)
                )
                .autocorrectionDisabled()

            ForEach(searchResults) { contact in
                ContactPickRow(contact: contact) { choose(contact) }
            }

            if searchText.trimmedOrNil != nil, searchResults.isEmpty {
                Text("No match. Photograph the sign or type the name instead.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Actions

    private func choose(_ contact: Contact) {
        Haptics.selection()
        draft.existingContactID = contact.id
        draft.newContact = DocumentDraft.NewContactFields()
        isTypingManually = false
        if draft.recipientEmail.trimmedOrNil == nil, let email = contact.email.trimmedOrNil {
            draft.recipientEmail = email
        }
        draft.touch()
    }

    private func apply(_ candidate: ParsedContactCandidate, source: ContactSource) {
        isPresentingSignScanner = false
        isPresentingCardScanner = false

        // If we already know this business, prefer the existing record — the
        // history on it is worth far more than a fresh duplicate.
        if let existing = matchExisting(candidate) {
            scanFeedback = "Matched an existing record for \(existing.displayName)."
            choose(existing)
            return
        }

        candidate.apply(to: &draft.newContact, source: source)
        if draft.recipientEmail.trimmedOrNil == nil, let email = candidate.email.trimmedOrNil {
            draft.recipientEmail = email
        }
        let filled = [
            candidate.name.trimmedOrNil != nil ? "name" : nil,
            candidate.addressLine1.trimmedOrNil != nil ? "address" : nil,
            candidate.phone.trimmedOrNil != nil ? "phone" : nil,
            candidate.email.trimmedOrNil != nil ? "email" : nil,
        ].compactMap { $0 }

        scanFeedback = filled.isEmpty
            ? "Could not read that. Type the name instead."
            : "Filled in \(filled.formatted(.list(type: .and))). Check it before you send."
        Haptics.success()
        draft.touch()
    }

    /// Duplicate detection: same name, or same name within the same city. Not
    /// clever, and it does not need to be — the staffer confirms either way.
    private func matchExisting(_ candidate: ParsedContactCandidate) -> Contact? {
        guard let name = candidate.name.trimmedOrNil?.lowercased() else { return nil }
        return allContacts.first { contact in
            let existing = contact.displayName.lowercased()
            guard existing == name || existing.contains(name) || name.contains(existing) else {
                return false
            }
            // Guard against matching two different "Corner Store"s in one city.
            if let city = candidate.city.trimmedOrNil?.lowercased(),
               let existingCity = contact.city.trimmedOrNil?.lowercased() {
                return city == existingCity
            }
            return true
        }
    }
}

// MARK: - Rows

private struct CaptureOptionRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var isPrimary: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.step()
            action()
        }) {
            HStack(spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isPrimary ? .white : Palette.brand)
                    .frame(width: 40, height: 40)
                    .background(isPrimary ? Palette.brand : Palette.brandMuted, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))

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
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }
}

private struct ContactPickRow: View {
    let contact: Contact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                WarmthBadge(warmth: contact.warmth, showsLabel: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.displayName)
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text(contact.subtitle)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                if contact.giftCount > 0 {
                    Text(contact.lifetimeGiving.formattedCompact)
                        .font(Type.caption.weight(.semibold))
                        .foregroundStyle(Palette.positive)
                        .monospacedDigit()
                }
            }
            .cardSurface(padding: Space.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(contact.displayName), \(contact.warmth.label)")
        .accessibilityHint("Double tap to record an interaction with this contact")
    }
}

// MARK: - Field

/// A labelled text field. Used throughout the app so every form field has the
/// same touch target, the same label placement, and the same required marker.
struct LabeledField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var isRequired: Bool = false
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(title)
                    .font(Type.label)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
                if isRequired {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(Palette.critical)
                }
            }
            TextField(placeholder, text: $text, axis: axis)
                .font(Type.body)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .padding(Space.sm)
                .frame(minHeight: Space.minimumTarget)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRequired ? "\(title), required" : title)
    }
}
