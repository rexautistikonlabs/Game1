//
//  ContactEditorView.swift
//  FieldForge
//
//  Creating or correcting a contact by hand. A plain form — the interesting
//  entry paths (camera, card, address book) all live in the capture flow, and
//  this is the one that has to be complete rather than fast.
//

import SwiftData
import SwiftUI

struct ContactEditorView: View {

    /// Nil creates a new contact.
    let contact: Contact?

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: ContactKind = .business
    @State private var personName = ""
    @State private var personTitle = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var postalCode = ""
    @State private var contactWindow: ContactWindow = .unknown
    @State private var tagInput = ""
    @State private var tags: [String] = []
    @State private var isDoNotContact = false
    @State private var doNotContactReason = ""

    private var isNew: Bool { contact == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Kind", selection: $kind) {
                        ForEach(ContactKind.allCases) { option in
                            Label(option.label, systemImage: option.symbolName).tag(option)
                        }
                    }
                    TextField("Person to ask for", text: $personName)
                        .textInputAutocapitalization(.words)
                    TextField("Their role", text: $personTitle)
                        .textInputAutocapitalization(.words)
                }

                Section("Reach") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Street", text: $addressLine1)
                        .textInputAutocapitalization(.words)
                    TextField("Suite, unit (optional)", text: $addressLine2)
                    TextField("City", text: $city)
                        .textInputAutocapitalization(.words)
                    HStack {
                        TextField("State", text: $state)
                            .textInputAutocapitalization(.characters)
                        TextField("ZIP", text: $postalCode)
                            .keyboardType(.numbersAndPunctuation)
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("A street address is only needed if you will post a letter. Emailed and handed-over documents do not need one.")
                }

                Section("Working with them") {
                    Picker("Best time", selection: $contactWindow) {
                        ForEach(ContactWindow.allCases) { window in
                            Text(window.label).tag(window)
                        }
                    }

                    HStack {
                        TextField("Add a tag", text: $tagInput)
                            .textInputAutocapitalization(.never)
                            .onSubmit(addTag)
                        Button("Add", action: addTag)
                            .disabled(tagInput.trimmedOrNil == nil)
                    }

                    if !tags.isEmpty {
                        TagChips(tags: tags) { tag in
                            tags.removeAll { $0 == tag }
                        }
                    }
                }

                Section {
                    Toggle("Do not contact again", isOn: $isDoNotContact)
                        .tint(Palette.critical)
                    if isDoNotContact {
                        TextField("Why (for the record)", text: $doNotContactReason, axis: .vertical)
                    }
                } footer: {
                    Text("Turning this on stops reminders, greys their map pin, and warns anyone who opens their record.")
                }

                if !isNew, let contact {
                    Section("Record") {
                        LabeledContent("Added", value: contact.createdAt.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Source", value: contact.source.label)
                        if let added = contact.createdByDisplayName.trimmedOrNil {
                            LabeledContent("Added by", value: added)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New contact" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmedOrNil == nil && personName.trimmedOrNil == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let contact else { return }
        name = contact.name
        kind = contact.kind
        personName = contact.contactPersonName
        personTitle = contact.contactPersonTitle
        phone = contact.phone
        email = contact.email
        addressLine1 = contact.addressLine1
        addressLine2 = contact.addressLine2
        city = contact.city
        state = contact.state
        postalCode = contact.postalCode
        contactWindow = contact.contactWindow
        tags = contact.tags
        isDoNotContact = contact.isDoNotContact
        doNotContactReason = contact.doNotContactReason
    }

    private func addTag() {
        guard let cleaned = tagInput.trimmedOrNil else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            tags.append(cleaned)
        }
        tagInput = ""
    }

    private func save() {
        let target: Contact
        if let contact {
            target = contact
        } else {
            target = Contact(name: name, kind: kind, source: .manual)
            target.organization = app.activeOrganization()
            target.createdByDisplayName = app.staffDisplayName
            target.isSharedWithTeam = app.entitlements.isSharingActive
            context.insert(target)
        }

        target.name = name
        target.kind = kind
        target.contactPersonName = personName
        target.contactPersonTitle = personTitle
        target.phone = phone
        target.email = email
        target.addressLine1 = addressLine1
        target.addressLine2 = addressLine2
        target.city = city
        target.state = state
        target.postalCode = postalCode
        target.contactWindow = contactWindow
        target.tags = tags
        target.isDoNotContact = isDoNotContact
        target.doNotContactReason = isDoNotContact ? doNotContactReason : ""
        target.recomputeRollups()

        do {
            try context.save()
            Haptics.success()
            dismiss()
        } catch {
            AppLog.app.error("Could not save contact: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Follow-up editor

/// Adding or editing a reminder. Small enough to live here rather than in a
/// file of its own.
struct FollowUpEditorView: View {

    let contact: Contact
    var existing: FollowUp?

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FollowUpKind = .thankYou
    @State private var dueAt = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var note = ""
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What for") {
                    Picker("Action", selection: $kind) {
                        ForEach(FollowUpKind.allCases) { option in
                            Label(option.label, systemImage: option.symbolName).tag(option)
                        }
                    }
                }

                Section {
                    DatePicker("When", selection: $dueAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("A reminder set for midnight arrives at 9am instead — nobody wants to be woken up about a thank-you note.")
                }

                Section("What to say") {
                    TextField("Your future self will thank you", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }

                if notificationsDenied {
                    Section {
                        Label(
                            "Notifications are off for FieldForge, so this will only show up on the Today screen.",
                            systemImage: "bell.slash"
                        )
                        .font(Type.caption)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New reminder" : "Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if let existing {
                    kind = existing.kind
                    dueAt = existing.dueAt
                    note = existing.note
                }
            }
            .task {
                notificationsDenied = !(await NotificationScheduler.requestAuthorizationIfNeeded())
            }
        }
    }

    private func save() {
        let followUp: FollowUp
        if let existing {
            followUp = existing
        } else {
            followUp = FollowUp()
            followUp.contact = contact
            followUp.isSharedWithTeam = app.entitlements.isSharingActive
            followUp.assignedToDisplayName = app.staffDisplayName
            context.insert(followUp)
        }
        followUp.kind = kind
        followUp.dueAt = dueAt
        followUp.note = note
        followUp.updatedAt = .now

        try? context.save()
        Task { await NotificationScheduler.schedule(followUp) }
        Haptics.success()
        dismiss()
    }
}
