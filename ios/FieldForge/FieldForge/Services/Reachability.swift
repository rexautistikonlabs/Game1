//
//  Reachability.swift
//  FieldForge
//
//  Is there a network, and is it expensive?
//
//  This is not decoration. Every screen in this app changes behaviour based on
//  it: which payment buttons are live, whether a document is sent or queued,
//  whether an address is geocoded now or later. So it is a single observable
//  source of truth rather than scattered `NWPathMonitor` instances.
//
//  It reports what the OS knows, which is "there is a usable route", not "the
//  internet works". A hotel captive portal will read as online. The rest of the
//  app is written so that being wrong about this costs a retry, never data.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class Reachability {

    /// A usable route exists.
    private(set) var isOnline: Bool = true

    /// Cellular or a personal hotspot. Used to avoid pushing a batch of photos
    /// to shared team memory on someone's own data plan.
    private(set) var isExpensive: Bool = false

    /// Low Data Mode. Same idea, honoured for the same reason.
    private(set) var isConstrained: Bool = false

    /// True once the monitor has reported at least once. Before that the app
    /// optimistically assumes online, so a cold launch does not flash "offline".
    private(set) var hasReceivedFirstUpdate: Bool = false

    /// Fires on every transition to online. The outbox subscribes to this.
    var onBecameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.example.fieldforge.reachability")

    init(startImmediately: Bool = true) {
        if startImmediately { start() }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.apply(online: online, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func apply(online: Bool, expensive: Bool, constrained: Bool) {
        let wasOffline = !isOnline || !hasReceivedFirstUpdate
        isOnline = online
        isExpensive = expensive
        isConstrained = constrained
        hasReceivedFirstUpdate = true

        if online, wasOffline {
            AppLog.app.info("Network available")
            onBecameOnline?()
        } else if !online {
            AppLog.app.info("Network unavailable")
        }
    }

    /// Whether it is polite to move a lot of bytes right now.
    var isGoodForLargeUploads: Bool {
        isOnline && !isExpensive && !isConstrained
    }

    /// One line for the status pill in the navigation bar.
    var statusDescription: String {
        guard isOnline else { return "Offline — everything still saves" }
        if isConstrained { return "Low Data Mode" }
        if isExpensive { return "On cellular" }
        return "Online"
    }
}
