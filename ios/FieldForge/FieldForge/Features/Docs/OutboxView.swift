//
//  OutboxView.swift
//  FieldForge
//
//  The queue, and the batch-send flow.
//
//  This screen is the honest answer to "offline email". iOS cannot send mail
//  without a person, so instead of pretending, FieldForge collects everything
//  that could not go out and walks the staffer through it in one sitting — at
//  the end of a route, over a coffee, one tap per document.
//
//  If the organization has wired up a `MailTransport`, this screen is empty
//  because everything drained by itself. Both paths are first class.
//

import MessageUI
import SwiftData
import SwiftUI

struct OutboxView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \OutboxItem.createdAt) private var items: [OutboxItem]

    @State private var presentingIndex: Int?
    @State private var pending: [(item: OutboxItem, document: GeneratedDocument)] = []
    @State private var sentCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if pending.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Palette.background)
            .navigationTitle("Outbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectivityPill(reachability: app.reachability, queuedCount: pending.count)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !pending.isEmpty {
                    ActionBar {
                        PrimaryButton(
                            title: pending.count == 1 ? "Send it" : "Send all \(pending.count)",
                            systemImage: "paperplane.fill",
                            isEnabled: app.reachability.isOnline && MailComposer.canSendMail
                        ) {
                            presentingIndex = 0
                        }
                        if !app.reachability.isOnline {
                            Text("Waiting for a connection. Nothing is lost.")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                        } else if !MailComposer.canSendMail {
                            Text("No Mail account is set up on this iPhone. AirDrop or print from Documents instead.")
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .sheet(isPresented: Binding(
                get: { presentingIndex != nil },
                set: { if !$0 { presentingIndex = nil } }
            )) {
                composerSheet
            }
        }
    }

    // MARK: Composer chain

    /// Presents the composers one after another. Each `onFinish` advances to the
    /// next, so a staffer taps Send, Send, Send and the queue empties.
    @ViewBuilder
    private var composerSheet: some View {
        if let index = presentingIndex, pending.indices.contains(index) {
            let entry = pending[index]
            MailComposer(message: DocumentMessageBuilder.mailMessage(for: entry.document)) { result, _ in
                app.outbox.recordPresentationResult(
                    for: entry.item,
                    document: entry.document,
                    sent: result == .sent
                )
                if result == .sent { sentCount += 1 }

                // Advance, or finish.
                let next = index + 1
                if next < pending.count, result != .cancelled {
                    presentingIndex = next
                } else {
                    presentingIndex = nil
                    Task { await refresh() }
                }
            }
        }
    }

    // MARK: Content

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            EmptyStateView(
                symbol: sentCount > 0 ? "checkmark.circle.fill" : "tray",
                title: sentCount > 0 ? "All sent" : "Nothing waiting",
                message: sentCount > 0
                    ? "\(sentCount) document\(sentCount == 1 ? "" : "s") on their way."
                    : "Anything you create without signal shows up here, and goes out the moment you are back on."
            )

            if MailTransportRegistry.supportsUnattendedSending {
                InlineBanner(
                    kind: .info,
                    message: "This organization has a mail service configured, so documents send themselves without you having to be here."
                )
                .padding(.horizontal, Space.screenEdge)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(Array(pending.enumerated()), id: \.element.item.id) { index, entry in
                    HStack(spacing: Space.md) {
                        Image(systemName: entry.document.kind.symbolName)
                            .foregroundStyle(Palette.brand)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.document.recipientName.trimmedOrNil ?? "Unnamed")
                                .font(Type.body.weight(.medium))
                            Text(entry.document.recipientEmail)
                                .font(Type.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                            if entry.item.attemptCount > 0 {
                                Text("Tried \(entry.item.attemptCount) time\(entry.item.attemptCount == 1 ? "" : "s")\(entry.item.lastError.trimmedOrNil.map { " · \($0)" } ?? "")")
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.caution)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: Space.sm)

                        Button("Send") { presentingIndex = index }
                            .font(Type.secondary.weight(.semibold))
                            .buttonStyle(.borderless)
                            .disabled(!app.reachability.isOnline || !MailComposer.canSendMail)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Give up", role: .destructive) {
                            app.outbox.abandon(entry.item)
                            Task { await refresh() }
                        }
                    }
                }
            } header: {
                Text("Waiting to send")
            } footer: {
                Text("iOS will not let an app send email on its own, so FieldForge queues these and hands you the composers in one go. The documents themselves are already saved.")
            }

            if !abandoned.isEmpty {
                Section("Given up on") {
                    ForEach(abandoned) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.label)
                                .font(Type.body)
                            if let error = item.lastError.trimmedOrNil {
                                Text(error)
                                    .font(Type.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
    }

    private var abandoned: [OutboxItem] {
        items.filter { $0.isAbandoned }
    }

    private func refresh() async {
        await app.outbox.drain()
        pending = app.outbox.itemsNeedingPresentation()
        app.outbox.refreshCounts()
    }
}

#Preview("Outbox") {
    OutboxView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
