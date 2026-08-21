//
//  LocationService.swift
//  FieldForge
//
//  One-shot location fixes for a GPS check-in, and a coarse region for the map.
//
//  Design decisions worth stating:
//
//    * When-in-use only. A fundraising app has no business tracking anybody in
//      the background, and asking for Always would be both intrusive and a
//      review risk.
//    * One-shot rather than continuous. A check-in needs one fix; leaving the
//      GPS on for a six-hour walking route would flatten the phone by lunchtime.
//    * A fix is never blocking. If the fix has not arrived in a few seconds the
//      visit saves without coordinates, because a note without a pin is worth
//      far more than a lost note.
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationService: NSObject {

    enum Authorization {
        case notDetermined
        case denied
        case restricted
        case authorized

        var canRequestFix: Bool { self == .authorized }
    }

    private(set) var authorization: Authorization = .notDetermined
    private(set) var lastKnownLocation: CLLocation?
    private(set) var isFixInFlight = false

    /// Set when a fix fails, so the check-in row can say why rather than just
    /// showing no pin.
    private(set) var lastErrorDescription: String?

    private let manager = CLLocationManager()
    private var fixContinuations: [CheckedContinuation<CLLocation?, Never>] = []
    private var authorizationContinuations: [CheckedContinuation<Authorization, Never>] = []
    private var timeoutTask: Task<Void, Never>?

    /// How long to wait for a fix before giving up and saving without one.
    var fixTimeout: Duration = .seconds(6)

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        authorization = Self.map(manager.authorizationStatus)
    }

    // MARK: Permission

    /// Asks for permission, lazily, at the moment the staffer taps a check-in.
    /// Returns the resulting state so the caller can proceed or explain.
    func requestAuthorizationIfNeeded() async -> Authorization {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: Fixes

    /// Returns a fix, or `nil` if permission is missing or the fix times out.
    ///
    /// A recent fix is reused: within thirty seconds and thirty metres the phone
    /// has not meaningfully moved, and the shop next door is not a different
    /// place worth spinning up the GPS for.
    func currentLocation(maximumAge: TimeInterval = 30) async -> CLLocation? {
        if let cached = lastKnownLocation,
           Date.now.timeIntervalSince(cached.timestamp) < maximumAge,
           cached.horizontalAccuracy > 0, cached.horizontalAccuracy < 60 {
            return cached
        }

        let state = await requestAuthorizationIfNeeded()
        guard state.canRequestFix else {
            lastErrorDescription = "Location permission is off, so this visit will not be pinned."
            return nil
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            fixContinuations.append(continuation)
            guard !isFixInFlight else { return }
            isFixInFlight = true
            lastErrorDescription = nil
            manager.requestLocation()
            startTimeout()
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let timeout = fixTimeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.isFixInFlight, !Task.isCancelled else { return }
            AppLog.location.info("Location fix timed out; saving without coordinates")
            self.lastErrorDescription = "Could not get a location in time. The visit was saved without a pin."
            self.deliver(nil)
        }
    }

    private func deliver(_ location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isFixInFlight = false
        let waiting = fixContinuations
        fixContinuations.removeAll()
        for continuation in waiting { continuation.resume(returning: location) }
    }

    private static func map(_ status: CLAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .notDetermined
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = Self.map(status)
            let waiting = self.authorizationContinuations
            self.authorizationContinuations.removeAll()
            for continuation in waiting { continuation.resume(returning: self.authorization) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Take the most accurate of the batch rather than simply the last.
        let best = locations
            .filter { $0.horizontalAccuracy > 0 }
            .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy })
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let best { self.lastKnownLocation = best }
            self.deliver(best ?? locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            AppLog.location.error("Location failed: \(description, privacy: .public)")
            self.lastErrorDescription = "Could not get a location. The visit will be saved without a pin."
            self.deliver(nil)
        }
    }
}

// MARK: - Reverse geocoding

/// Turning coordinates into a street address. Needs a network, so every call
/// site is written to work without it and to queue the lookup instead.
enum ReverseGeocoder {

    /// A single formatted address line, or `nil` if the lookup failed.
    static func address(for coordinate: CLLocationCoordinate2D) async -> ResolvedAddress? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return ResolvedAddress(placemark: placemark)
        } catch {
            AppLog.location.info("Reverse geocode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    struct ResolvedAddress {
        var street: String
        var city: String
        var state: String
        var postalCode: String
        var country: String
        var name: String

        init(placemark: CLPlacemark) {
            let number = placemark.subThoroughfare
            let road = placemark.thoroughfare
            street = [number, road].compactMap { $0 }.joined(separator: " ")
            city = placemark.locality ?? ""
            state = placemark.administrativeArea ?? ""
            postalCode = placemark.postalCode ?? ""
            country = placemark.country ?? ""
            // The name of a business at that address, when Apple knows one.
            // Genuinely useful: it often *is* the donor we are standing in.
            name = placemark.name ?? ""
        }

        var singleLine: String {
            [street, [city, state].filter { !$0.isEmpty }.joined(separator: ", "), postalCode]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }
}
