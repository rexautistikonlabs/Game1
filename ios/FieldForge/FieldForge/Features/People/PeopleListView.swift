//
//  PeopleListView.swift
//  FieldForge
//
//  The CRM list. Searchable, filterable by warmth, sortable by the things a
//  fundraiser actually sorts by — who is warm, who gave most, who has not been
//  seen in a while.
//
//  Search is deliberately local and synchronous. There is no network round trip,
//  so it works at a doorstep, and with a few thousand contacts a filtered
//  in-memory pass is faster than a predicate rebuild on every keystroke.
//

import SwiftData
import SwiftUI

struct PeopleListView: View {

    let onStartCapture: (Contact) -> Void


    @Query(
        filter: #Predicate<Contact> { $0.isArchived == false },
        sort: \Contact.updatedAt,
        order: .reverse
    )
    private var contacts: [Contact]

    @State private var searchText = ""
    @State private var sort: SortOption = .recent
    @State private var warmthFilter: Warmth?
    @State private var isPresentingEditor = false

    enum SortOption: String, CaseIterable, Identifiable {
        case recent
        case warmest
        case biggestGivers
        case longestSinceVisit
        case alphabetical

        var id: String { rawValue }

        var label: String {
            switch self {
            case .recent: return "Recently touched"
            case .warmest: return "Warmest first"
            case .biggestGivers: return "Biggest givers"
            case .longestSinceVisit: return "Not seen longest"
            case .alphabetical: return "A–Z"
            }
        }

        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .warmest: return "sun.max"
            case .biggestGivers: return "dollarsign.circle"
            case .longestSinceVisit: return "hourglass"
            case .alphabetical: return "textformat.abc"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    EmptyStateView(
                        symbol: "person.crop.circle.badge.plus",
                        title: "No contacts yet",
                        message: "Tap Capture at your first door. Photograph the sign and FieldForge fills in the name and address for you."
                    )
                } else {
                    list
                }
            }
            .background(Palette.background)
            .navigationTitle("People")
            .searchable(text: $searchText, prompt: "Name, city, tag, or note")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SortOption.allCases) { option in
                                Label(option.label, systemImage: option.symbol).tag(option)
                            }
                        }
                        Divider()
                        Picker("Warmth", selection: $warmthFilter) {
                            Text("All").tag(Warmth?.none)
                            ForEach(Warmth.allCases) { warmth in
                                Label(warmth.label, systemImage: warmth.symbolName)
                                    .tag(Warmth?.some(warmth))
                            }
                        }
                    } label: {
                        Image(systemName: warmthFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Sort and filter")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isPresentingEditor = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a contact by hand")
                }
            }
            .sheet(isPresented: $isPresentingEditor) {
                ContactEditorView(contact: nil)
            }
        }
    }

    private var list: some View {
        List {
            if !filtered.isEmpty {
                Section {
                    ForEach(filtered) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact)
                        } label: {
                            ContactRow(contact: contact, sort: sort)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                onStartCapture(contact)
                            } label: {
                                Label("Capture", systemImage: "plus.circle")
                            }
                            .tint(Palette.brand)
                        }
                    }
                } header: {
                    Text(headerText)
                }
            } else {
                Section {
                    Text("Nothing matches.")
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private var headerText: String {
        let count = filtered.count
        let noun = count == 1 ? "contact" : "contacts"
        if let warmthFilter {
            return "\(count) \(noun) · \(warmthFilter.label)"
        }
        return "\(count) \(noun)"
    }

    // MARK: Filtering and sorting

    private var filtered: [Contact] {
        var result = contacts

        if let warmthFilter {
            result = result.filter { $0.warmth == warmthFilter }
        }

        if let query = searchText.trimmedOrNil?.lowercased() {
            result = result.filter { contact in
                contact.displayName.lowercased().contains(query)
                    || contact.contactPersonName.lowercased().contains(query)
                    || contact.city.lowercased().contains(query)
                    || contact.sharedNotes.lowercased().contains(query)
                    || contact.privateNotes.lowercased().contains(query)
                    || contact.tags.contains { $0.lowercased().contains(query) }
            }
        }

        switch sort {
        case .recent:
            return result.sorted { $0.updatedAt > $1.updatedAt }
        case .warmest:
            return result.sorted {
                if $0.warmth.rawValue != $1.warmth.rawValue {
                    return $0.warmth.rawValue > $1.warmth.rawValue
                }
                return $0.lifetimeGivingMinorUnits > $1.lifetimeGivingMinorUnits
            }
        case .biggestGivers:
            return result.sorted { $0.lifetimeGivingMinorUnits > $1.lifetimeGivingMinorUnits }
        case .longestSinceVisit:
            // Never-visited first: they are the ones most worth a knock.
            return result.sorted {
                ($0.lastVisitAt ?? .distantPast) < ($1.lastVisitAt ?? .distantPast)
            }
        case .alphabetical:
            return result.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }
}

// MARK: - Row

struct ContactRow: View {
    let contact: Contact
    var sort: PeopleListView.SortOption = .recent

    var body: some View {
        HStack(spacing: Space.md) {
            WarmthBadge(warmth: contact.warmth, showsLabel: false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(contact.displayName)
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                    if contact.isDoNotContact {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(Warmth.doNotReturn.tint)
                            .accessibilityLabel("Do not contact")
                    }
                    if contact.isSharedWithTeam {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityLabel("Shared with the team")
                    }
                }
                Text(contact.subtitle)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if let trailing = trailingDetail {
                    Text(trailing)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            Spacer(minLength: Space.sm)

            if contact.giftCount > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(contact.lifetimeGiving.formattedCompact)
                        .font(Type.caption.weight(.semibold))
                        .foregroundStyle(Palette.positive)
                        .monospacedDigit()
                    Text("\(contact.giftCount) gift\(contact.giftCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The third line changes with the sort, so the number you sorted by is
    /// always visible. Sorting by something you cannot see is disorienting.
    private var trailingDetail: String? {
        switch sort {
        case .longestSinceVisit:
            guard let last = contact.lastVisitAt else { return "Never visited" }
            return "Last seen \(last.formatted(.relative(presentation: .named)))"
        case .warmest:
            return contact.contactWindow == .unknown ? nil : "Best: \(contact.contactWindow.label.lowercased())"
        default:
            return nil
        }
    }

    private var accessibilityDescription: String {
        var parts = [contact.displayName, contact.warmth.label]
        if contact.giftCount > 0 {
            parts.append("given \(contact.lifetimeGiving.formatted)")
        }
        if contact.isDoNotContact { parts.append("do not contact") }
        return parts.joined(separator: ", ")
    }
}

#Preview("People") {
    PeopleListView(onStartCapture: { _ in })
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
