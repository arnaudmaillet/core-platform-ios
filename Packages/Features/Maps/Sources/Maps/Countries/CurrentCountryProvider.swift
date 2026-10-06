import CoreLocation
import UIKit

/// Whether the app may know where the device is.
public enum LocationPermission: Equatable, Sendable {
    /// Never asked — the map's locate button and card will ask, in context.
    case notAsked
    case allowed
    /// Denied or restricted: only iOS Settings can change it.
    case denied
}

/// The country the device is in — what opens on the map for free while the
/// person is there (guest mode §3.1, `dev/GUEST_MODE_REPORT.md`).
///
/// ⚠️ Asked IN CONTEXT only (`requestPermission()`, from the map's locate
/// button or its "See posts around you" card), never at launch.
@MainActor
public protocol CurrentCountryLocating: AnyObject {
    /// ISO alpha-2, or nil: no permission, no fix yet, or out at sea.
    var currentCountry: String? { get }
    var permission: LocationPermission { get }
    /// Asks for when-in-use permission the first time; afterwards re-reads
    /// where the device is.
    func requestPermission()
}

/// Asks the server whether the device's country may open (backend B10,
/// `geo_discovery.v1.GetCountryAccess`): it checks the code against the
/// network's GeoIP country, so a spoofed GPS position opens nothing.
public protocol CurrentCountryVerifying: Sendable {
    /// The country to open — `code` when granted, nil otherwise. Called with
    /// nil too: telling the server nothing is sent closes the country left
    /// behind (decision 10).
    func verify(_ code: String?) async -> String?
}

public extension Notification.Name {
    /// Posted by a `CurrentCountryLocating` when the country or the
    /// permission changed.
    static let currentCountryDidChange = Notification.Name("currentCountry.didChange")
}

/// `CurrentCountryLocating` over Core Location.
///
/// - **Approximate on purpose**: `kCLLocationAccuracyReduced` (and
///   `NSLocationDefaultAccuracyReduced` in the Info.plist) — borders are
///   kilometres wide, and a precise fix is more than the question needs.
/// - **Only the code leaves**: the coordinate is turned into a country on the
///   device (`CountryAtlas.country(owning:)`) and dropped. Nothing here sends
///   anything anywhere.
/// - **Kept current**: re-read at every foreground and on significant
///   location changes, so travelling opens the new country and the one left
///   behind closes again (decision 10) — the current country is never
///   stored as an unlock.
@MainActor
public final class CurrentCountryProvider: NSObject, CurrentCountryLocating {
    public private(set) var currentCountry: String?

    private let manager = CLLocationManager()
    private let resolve: (CLLocationCoordinate2D) -> String?
    /// Nil trusts the device (mock mode, tests).
    private let verifier: (any CurrentCountryVerifying)?
    /// The last code the device resolved, verified or not — what a new fix is
    /// compared against, so an unchanged country is not re-verified.
    private var resolvedCountry: String??
    private var verification: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var isUpdating = false
    #if DEBUG
    /// `-current-country XX`: the device stands in XX, permission granted,
    /// Core Location untouched — the unlocked-by-location map without a
    /// simulated route. `-current-country none` stands nowhere, permission
    /// denied — the card's Settings face.
    private let pinned: String??
    #endif

    public init(
        resolve: @escaping (CLLocationCoordinate2D) -> String? = { CountryAtlas.shared.country(owning: $0)?.code },
        verifier: (any CurrentCountryVerifying)? = nil
    ) {
        self.resolve = resolve
        self.verifier = verifier
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        pinned = arguments.firstIndex(of: "-current-country")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .map { $0 == "none" ? nil : $0.uppercased() }
        #endif
        super.init()
        #if DEBUG
        if let pinned {
            currentCountry = pinned
            return
        }
        #endif
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Already allowed on a previous run: no question, just the fix.
        if permission == .allowed { startUpdating() }
    }

    public var permission: LocationPermission {
        #if DEBUG
        if let pinned { return pinned == nil ? .denied : .allowed }
        #endif
        return Self.permission(for: manager.authorizationStatus)
    }

    static func permission(for status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        default: .denied
        }
    }

    public func requestPermission() {
        switch permission {
        case .notAsked: manager.requestWhenInUseAuthorization()
        case .allowed: refresh()
        case .denied: break
        }
    }

    private func refresh() {
        guard permission == .allowed else { return }
        manager.requestLocation()
    }

    private func startUpdating() {
        guard !isUpdating else { return }
        isUpdating = true
        manager.requestLocation()
        manager.startMonitoringSignificantLocationChanges()
    }

    private func stopUpdating() {
        isUpdating = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// The device resolved `country`: the server decides whether it opens
    /// (`verifier`), and only its answer is published.
    private func settle(on country: String?) {
        guard resolvedCountry != .some(country) else { return }
        resolvedCountry = .some(country)
        guard let verifier else {
            publish(country)
            return
        }
        verification?.cancel()
        verification = Task { [weak self] in
            let granted = await verifier.verify(country)
            guard !Task.isCancelled else { return }
            self?.publish(granted)
        }
    }

    private func publish(_ country: String?) {
        guard country != currentCountry else { return }
        currentCountry = country
        NotificationCenter.default.post(name: .currentCountryDidChange, object: self)
    }
}

extension CurrentCountryProvider: CLLocationManagerDelegate {
    // Core Location calls back on the thread that made the manager — this
    // type's, the main one.

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if permission == .allowed {
                startUpdating()
            } else {
                stopUpdating()
                // Permission withdrawn: the country it opened closes with it.
                settle(on: nil)
            }
            NotificationCenter.default.post(name: .currentCountryDidChange, object: self)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        MainActor.assumeIsolated {
            settle(on: resolve(coordinate))
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // No fix this time: the last country stands until a fix says otherwise.
    }
}
