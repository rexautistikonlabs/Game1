//
//  OutboxProcessor.swift
//  FieldForge
//
//  Draining the offline queue.
//
//  Two classes of work, handled differently and honestly:
//
//    * Silent work — reverse geocoding, and syncing to shared team memory. This
//      drains by itself the moment a network appears, with backoff.
//
//    * Work needing a person — emailing a donor their PDF. iOS has no
//      unattended mail send without a backend (see DocumentExporter), so these
//      items are collected and the Outbox screen walks the staffer through the
//      composers in one batch. That is one tap per document at the end of a
//      route, instead of forty separate acts of remembering.
//
//  If a `MailTransport` has been registered, the email items drain silently too
//  and the staffer never sees the Outbox screen at all.
//

import CoreLocation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class OutboxProcessor {

    /// Live counts for the badge and the Outbox screen.
    private(set) var pendingCount: Int = 0
    private(set) var needsAttentionCount: Int = 0
    private(set) var isDraining: Bool = false
    private(set) var lastDrainAt: Date?

    private let container: ModelContainer
    private let reachability: Reachability

    init(container: ModelContainer, reachability: Reachability) {
        self.container = container
        self.reachability = reachability
        // Draining on every reconnection is the entire promise of "offline
        // first": the staffer does not have to remember to press anything.
        reachability.onBecameOnline = { [weak self] in
            Task { await self?.drain() }
        }
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Enqueueing

    /// Queues an email for a document. Idempotent per document: re-queueing the
    /// same document replaces the pending item rather than sending twice.
    func enqueueEmail(for document: GeneratedDocument) {
        guard let recipient = document.recipientEmail.trimmedOrNil else { return }

        removePendingItems(kind: .emailDocument, subjectID: document.id)

        let payload = OutboxItem.EmailPayload(
            recipient: recipient,
            subject: DocumentMessageBuilder.subject(for: document),
            body: DocumentMessageBuilder.body(for: document),
            fileName: document.suggestedFileName
        )
        let item = OutboxItem(
            kind: .emailDocument,
            subjectID: document.id,
            payload: OutboxItem.encodePayload(payload)
        )
        context.insert(item)
        document.markQueued()
        save()
        refreshCounts()
    }

    /// Queues a reverse geocode for a visit or contact that only has
    /// coordinates. The pin already works; this fills in the street later.
    func enqueueGeocode(latitude: Double, longitude: Double, subjectID: UUID, isVisit: Bool) {
        removePendingItems(kind: .reverseGeocode, subjectID: subjectID)
        let payload = OutboxItem.GeocodePayload(
            latitude: latitude,
            longitude: longitude,
            targetIsVisit: isVisit
        )
        let item = OutboxItem(
            kind: .reverseGeocode,
            subjectID: subjectID,
            payload: OutboxItem.encodePayload(payload)
        )
        context.insert(item)
        save()
        refreshCounts()
    }

    // MARK: Draining

    /// Works through everything that can be done without a person.
    func drain() async {
        guard reachability.isOnline, !isDraining else { return }
        isDraining = true
        defer {
            isDraining = false
            lastDrainAt = .now
            refreshCounts()
        }

        let items = fetchPending()
        guard !items.isEmpty else { return }
        AppLog.outbox.info("Draining \(items.count, privacy: .public) queued items")

        for item in items where item.isReadyToRetry {
            switch item.kind {
            case .reverseGeocode:
                await processGeocode(item)
            case .emailDocument:
                await processEmail(item)
            case .syncUpstream:
                // Shared team memory rides on SwiftData's own CloudKit mirroring,
                // which drains itself. The row exists so the UI can show that
                // something is still in flight.
                item.recordSuccess()
            }
            save()
        }

        purgeCompletedItems(olderThan: 7)
        save()
    }

    private func processGeocode(_ item: OutboxItem) async {
        guard let payload = item.decodePayload(OutboxItem.GeocodePayload.self) else {
            item.recordFailure("Unreadable location payload")
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
        guard let resolved = await ReverseGeocoder.address(for: coordinate) else {
            item.recordFailure("Address lookup did not return a result")
            return
        }

        if payload.targetIsVisit {
            if let visit = fetchVisit(id: item.subjectID) {
                visit.resolvedAddress = resolved.singleLine
                visit.touch()
            }
        } else if let contact = fetchContact(id: item.subjectID) {
            // Never overwrite an address a person typed. Machine-filled fields
            // only ever fill blanks.
            if contact.addressLine1.trimmedOrNil == nil { contact.addressLine1 = resolved.street }
            if contact.city.trimmedOrNil == nil { contact.city = resolved.city }
            if contact.state.trimmedOrNil == nil { contact.state = resolved.state }
            if contact.postalCode.trimmedOrNil == nil { contact.postalCode = resolved.postalCode }
            contact.hasResolvedAddress = true
            contact.touch()
        }
        item.recordSuccess()
    }

    private func processEmail(_ item: OutboxItem) async {
        guard MailTransportRegistry.supportsUnattendedSending else {
            // Left pending on purpose: the Outbox screen will present it.
            return
        }
        guard let payload = item.decodePayload(OutboxItem.EmailPayload.self),
              let document = fetchDocument(id: item.subjectID) else {
            item.recordFailure("The document for this email is no longer available")
            return
        }

        let message = MailComposer.Message(
            recipients: [payload.recipient],
            subject: payload.subject,
            body: payload.body,
            attachmentData: document.pdfData ?? DocumentEngine.reprint(document),
            attachmentFileName: payload.fileName
        )

        do {
            try await MailTransportRegistry.current.send(message)
            document.markSent(channel: "Server")
            item.recordSuccess()
        } catch {
            document.markFailed(error.localizedDescription)
            item.recordFailure(error.localizedDescription)
        }
    }

    // MARK: Items needing a person

    /// Email items the staffer has to walk through, newest last so the Outbox
    /// screen presents them in the order they were created.
    func itemsNeedingPresentation() -> [(item: OutboxItem, document: GeneratedDocument)] {
        guard !MailTransportRegistry.supportsUnattendedSending else { return [] }
        return fetchPending()
            .filter { $0.kind == .emailDocument }
            .compactMap { item in
                guard let document = fetchDocument(id: item.subjectID) else { return nil }
                return (item, document)
            }
            .sorted { $0.item.createdAt < $1.item.createdAt }
    }

    /// Called after the staffer sends (or cancels) a composer.
    func recordPresentationResult(for item: OutboxItem, document: GeneratedDocument, sent: Bool) {
        if sent {
            document.markSent(channel: "Mail")
            item.recordSuccess()
        } else {
            // A cancelled composer is not a failure — the document stays queued
            // so it is not lost, and no retry counter is burned.
            document.markQueued()
        }
        save()
        refreshCounts()
    }

    /// Gives up on an item at the staffer's request. The record survives so the
    /// history still shows the document was never delivered.
    func abandon(_ item: OutboxItem) {
        item.isAbandoned = true
        if let document = fetchDocument(id: item.subjectID) {
            document.markFailed("Sending was cancelled")
        }
        save()
        refreshCounts()
    }

    // MARK: Counts

    func refreshCounts() {
        let pending = fetchPending()
        pendingCount = pending.count
        needsAttentionCount = pending.filter { $0.attemptCount >= 3 }.count
            + fetchAbandoned().count
    }

    // MARK: Fetches

    private func fetchPending() -> [OutboxItem] {
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.completedAt == nil && $0.isAbandoned == false },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchAbandoned() -> [OutboxItem] {
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.isAbandoned == true }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchDocument(id: UUID) -> GeneratedDocument? {
        var descriptor = FetchDescriptor<GeneratedDocument>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchVisit(id: UUID) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchContact(id: UUID) -> Contact? {
        var descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func removePendingItems(kind: OutboxKind, subjectID: UUID) {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { item in
                item.subjectID == subjectID && item.completedAt == nil && item.kindRawValue == kindRaw
            }
        )
        for item in (try? context.fetch(descriptor)) ?? [] {
            context.delete(item)
        }
    }

    /// Completed rows are kept briefly so the Outbox screen can say "3 sent"
    /// instead of going mysteriously empty, then cleaned up.
    private func purgeCompletedItems(olderThan days: Int) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) else { return }
        // `?? .distantFuture` rather than an `if let`: the predicate macro
        // translates a nil-coalesce cleanly into a store query, and a pending
        // item (nil completedAt) must never match.
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { item in
                (item.completedAt ?? Date.distantFuture) < cutoff
            }
        )
        for item in (try? context.fetch(descriptor)) ?? [] {
            context.delete(item)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.outbox.error("Could not save outbox changes: \(error.localizedDescription, privacy: .public)")
        }
    }
}
