//
//  DocumentsListView.swift
//  FieldForge
//
//  Every document ever issued, searchable, re-sendable, re-printable.
//
//  This screen exists for one recurring phone call: "I can't find the receipt
//  you gave me in March." Search by name, amount, or document number, tap, send
//  it again. Thirty seconds.
//

import SwiftData
import SwiftUI

struct DocumentsListView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \GeneratedDocument.issuedAt, order: .reverse)
    private var documents: [GeneratedDocument]

    @State private var searchText = ""
    @State private var kindFilter: DocumentKind?
    @State private var stateFilter: DeliveryState?
    @State private var isPresentingOutbox = false

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "No documents yet",
                        message: "Receipts and acknowledgment letters you issue will all be here, ready to send again."
                    )
                } else {
                    list
                }
            }
            .background(Palette.background)
            .navigationTitle("Documents")
            .searchable(text: $searchText, prompt: "Name, number, or amount")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $kindFilter) {
                            Text("All types").tag(DocumentKind?.none)
                            ForEach(DocumentKind.allCases) { kind in
                                Label(kind.longLabel, systemImage: kind.symbolName)
                                    .tag(DocumentKind?.some(kind))
                            }
                        }
                        Divider()
                        Picker("Status", selection: $stateFilter) {
                            Text("Any status").tag(DeliveryState?.none)
                            ForEach(DeliveryState.allCases, id: \.rawValue) { state in
                                Label(state.label, systemImage: state.symbolName)
                                    .tag(DeliveryState?.some(state))
                            }
                        }
                    } label: {
                        Image(systemName: hasFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter documents")
                }
            }
            .sheet(isPresented: $isPresentingOutbox) { OutboxView() }
            .onDisappear {
                // Staged share files hold donor PDFs in a temporary directory.
                // Clear them when leaving rather than on a timer.
                DocumentEngine.clearStagedFiles()
            }
        }
    }

    private var list: some View {
        List {
            if app.outbox.pendingCount > 0 {
                Section {
                    Button {
                        isPresentingOutbox = true
                    } label: {
                        HStack(spacing: Space.md) {
                            Image(systemName: "tray.full.fill")
                                .foregroundStyle(Palette.caution)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(app.outbox.pendingCount) waiting to send")
                                    .font(Type.body.weight(.medium))
                                Text(app.reachability.isOnline ? "Ready to go out" : "Will send when you have signal")
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(minHeight: Space.minimumTarget)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                if filtered.isEmpty {
                    Text("Nothing matches.")
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(filtered) { document in
                        NavigationLink {
                            DocumentDetailView(document: document)
                        } label: {
                            DocumentRow(document: document)
                        }
                    }
                }
            } header: {
                Text(summaryHeader)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private var hasFilter: Bool { kindFilter != nil || stateFilter != nil }

    private var summaryHeader: String {
        let total = Money.sum(
            filtered
                .filter { $0.deliveryState != .superseded && $0.inKindDescription.trimmedOrNil == nil }
                .map(\.amount)
        )
        let count = filtered.count
        return "\(count) document\(count == 1 ? "" : "s") · \(total.formattedCompact) acknowledged"
    }

    private var filtered: [GeneratedDocument] {
        var result = documents

        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }
        if let stateFilter {
            result = result.filter { $0.deliveryState == stateFilter }
        } else {
            // Superseded copies are audit trail, not everyday reading.
            result = result.filter { $0.deliveryState != .superseded }
        }
        if let query = searchText.trimmedOrNil?.lowercased() {
            result = result.filter { $0.searchIndex.contains(query) }
        }
        return result
    }
}

// MARK: - Row

struct DocumentRow: View {
    let document: GeneratedDocument

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: document.kind.symbolName)
                .font(.body)
                .foregroundStyle(Palette.brand)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(document.recipientName.trimmedOrNil ?? "Unnamed")
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if document.isRevision {
                        Text("revised")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.caution.opacity(0.18), in: Capsule())
                            .foregroundStyle(Palette.caution)
                    }
                }
                Text(document.documentNumber)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .monospaced()
                HStack(spacing: 4) {
                    Image(systemName: document.deliveryState.symbolName)
                    Text(document.deliveryState.label)
                }
                .font(Type.caption)
                .foregroundStyle(stateColor)
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: 1) {
                Text(document.inKindDescription.trimmedOrNil == nil ? document.amount.formattedCompact : "In-kind")
                    .font(Type.caption.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .monospacedDigit()
                Text(document.issuedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(document.kind.longLabel) for \(document.recipientName), \(document.amount.formatted), \(document.deliveryState.label)"
        )
    }

    private var stateColor: Color {
        switch document.deliveryState {
        case .sent: return Palette.positive
        case .queued: return Palette.caution
        case .failed: return Palette.critical
        case .saved, .superseded: return Palette.textTertiary
        }
    }
}

#Preview("Documents") {
    DocumentsListView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
