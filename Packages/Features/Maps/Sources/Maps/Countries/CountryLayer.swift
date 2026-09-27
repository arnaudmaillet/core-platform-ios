import MapKit
import UIKit

/// How a country is drawn.
enum CountryStyle: Equatable {
    /// Open to the account: its posts are on the map. Just a border.
    case unlocked
    /// Not unlocked yet: shaded, so the map reads as "yours" and "not yet".
    case locked
}

/// One country's outline on the map, carrying its ISO code.
final class CountryShape: MKMultiPolygon {
    let code: String
    /// Whether this is the lifted copy drawn over the others for the
    /// selected country.
    let isLifted: Bool

    init(country: CountryAtlas.Country, lifted: Bool = false) {
        code = country.code
        isLifted = lifted
        let polygons = country.polygons.compactMap { polygon -> MKPolygon? in
            guard let outer = polygon.first, outer.count >= 3 else { return nil }
            let holes = polygon.dropFirst().map { MKPolygon(coordinates: $0, count: $0.count) }
            return MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes)
        }
        super.init(polygons)
    }
}

/// Draws a country: a border, a shade when locked, and — for the lifted copy
/// of the selected one — a raised look: a brighter fill, a white rim and a
/// drop shadow.
///
/// ⚠️ **THE SHADOW IS SCALED BY THE ZOOM.** A renderer draws in map points,
/// and a shadow offset or blur given in screen points would shrink to nothing
/// at a continent's zoom and swallow the country at a street's.
final class CountryRenderer: MKMultiPolygonRenderer {
    var style: CountryStyle = .unlocked { didSet { if style != oldValue { applyStyle() } } }
    private let isLifted: Bool

    convenience init(shape: CountryShape) {
        self.init(overlay: shape)
    }

    /// ⚠️ **THE OVERLAY INIT, NOT `init(multiPolygon:)`.** MapKit's
    /// `init(multiPolygon:)` calls `init(overlay:)` on `self`, and a Swift
    /// subclass that declares its own designated init does not inherit it: the
    /// map trapped on "unimplemented initializer" the moment the borders drew.
    override init(overlay: any MKOverlay) {
        isLifted = (overlay as? CountryShape)?.isLifted ?? false
        super.init(overlay: overlay)
        applyStyle()
    }

    private func applyStyle() {
        if isLifted {
            fillColor = UIColor.white.withAlphaComponent(style == .locked ? 0.22 : 0.12)
            strokeColor = .white
            lineWidth = 3
        } else {
            switch style {
            case .unlocked:
                fillColor = .clear
                strokeColor = UIColor.black.withAlphaComponent(0.22)
                lineWidth = 1
            case .locked:
                fillColor = UIColor(white: 0.05, alpha: 0.28)
                strokeColor = UIColor.white.withAlphaComponent(0.55)
                lineWidth = 1
            }
        }
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard isLifted else { return super.draw(mapRect, zoomScale: zoomScale, in: context) }
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 6 / zoomScale),
            blur: 18 / zoomScale,
            color: UIColor.black.withAlphaComponent(0.45).cgColor
        )
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        context.restoreGState()
    }
}

/// The world's country borders on the map, and choosing one.
///
/// Owns the overlays and their renderers, the tap that picks a country, and
/// the selected one's lifted copy. The map view controller installs it and
/// forwards `rendererFor` and `viewFor`; which countries are open comes from
/// `access`, and what a tap on one DOES is the host's (`onCountryTapped`,
/// `onLockedBadgeTapped`). Locked countries also wear a badge at their centre
/// (`LockedCountryAnnotation`) with their rank and likes.
///
/// ⚠️ **A TAP ON A MARKER IS THE MARKER'S.** The country tap runs alongside
/// the map's own recognisers and stands down when the touch landed on an
/// annotation view, so opening a post never also picks the country under it.
@MainActor
final class CountryLayer: NSObject {
    /// A country was tapped (not a marker on it).
    var onCountryTapped: ((CountryAtlas.Country) -> Void)?

    /// A locked country's badge was tapped.
    var onLockedBadgeTapped: ((CountryAtlas.Country) -> Void)?
    /// Which countries are open, and their standings. Nil: every country is
    /// open and nothing is sold (the fleet, until the backend carries it).
    var access: (any CountryAccess)?

    private weak var mapView: MKMapView?
    private var badges: [String: LockedCountryAnnotation] = [:]
    private var shapes: [String: CountryShape] = [:]
    private var renderers: [String: CountryRenderer] = [:]
    private var lifted: (shape: CountryShape, renderer: CountryRenderer?)?
    private(set) var selectedCode: String?
    private let atlas: CountryAtlas

    init(atlas: CountryAtlas = .shared) {
        self.atlas = atlas
    }

    /// Adds the borders and the tap. The atlas is decoded off the main thread
    /// first; the borders appear when it is ready.
    func install(on mapView: MKMapView) {
        self.mapView = mapView
        mapView.register(
            LockedCountryAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: LockedCountryAnnotationView.reuseIdentifier
        )
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        // ⚠️ A DOUBLE TAP ZOOMS, it does not pick. Without this the first tap
        // of a double-tap zoom lifted (or offered) the country under it. The
        // twin recognises alongside MapKit's own double tap and does nothing;
        // the pick waits for it to fail (~0.25s, the platform's own delay).
        let doubleTap = UITapGestureRecognizer()
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesEnded = false
        doubleTap.delegate = self
        tap.require(toFail: doubleTap)
        mapView.addGestureRecognizer(doubleTap)
        mapView.addGestureRecognizer(tap)
        Task { [weak self] in
            let countries = await Task.detached(priority: .userInitiated) { CountryAtlas.shared.countries }.value
            self?.addBorders(for: countries)
        }
    }

    private func addBorders(for countries: [CountryAtlas.Country]) {
        guard let mapView else { return }
        let shapes = countries.map { CountryShape(country: $0) }
        self.shapes = Dictionary(uniqueKeysWithValues: shapes.map { ($0.code, $0) })
        mapView.addOverlays(shapes, level: .aboveRoads)
        refreshBadges()
    }

    /// The style `code` is drawn in: open, or locked.
    func style(for code: String) -> CountryStyle {
        guard let access else { return .unlocked }
        return access.isUnlocked(code) ? .unlocked : .locked
    }

    /// Puts a badge on every locked country that has a standing, and takes
    /// it off every unlocked one.
    func refreshBadges() {
        guard let mapView, !shapes.isEmpty else { return }
        var wanted: [String: LockedCountryAnnotation] = [:]
        if let access {
            for country in atlas.countries where !access.isUnlocked(country.code) {
                guard let standing = access.standing(of: country.code) else { continue }
                wanted[country.code] = badges[country.code]?.standing == standing
                    ? badges[country.code]
                    : LockedCountryAnnotation(country: country, standing: standing)
            }
        }
        let gone = badges.filter { wanted[$0.key] !== $0.value }.map(\.value)
        let new = wanted.filter { badges[$0.key] !== $0.value }.map(\.value)
        if !gone.isEmpty { mapView.removeAnnotations(gone) }
        if !new.isEmpty { mapView.addAnnotations(new) }
        badges = wanted
    }

    /// The badge view for a locked country.
    func view(for badge: LockedCountryAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: LockedCountryAnnotationView.reuseIdentifier, for: badge
        ) as? LockedCountryAnnotationView ?? LockedCountryAnnotationView(
            annotation: badge, reuseIdentifier: LockedCountryAnnotationView.reuseIdentifier
        )
        view.annotation = badge
        view.onSelect = { [weak self] in
            guard let self, let country = self.atlas.country(code: badge.code) else { return }
            self.onLockedBadgeTapped?(country)
        }
        return view
    }

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        guard let shape = overlay as? CountryShape else { return nil }
        let renderer = CountryRenderer(shape: shape)
        renderer.style = style(for: shape.code)
        if shape.isLifted {
            lifted?.renderer = renderer
        } else {
            renderers[shape.code] = renderer
        }
        return renderer
    }

    /// Re-asks every country's style — after an unlock.
    func refreshStyles() {
        for (code, renderer) in renderers { renderer.style = style(for: code) }
        lifted?.renderer?.style = style(for: lifted?.shape.code ?? "")
        refreshBadges()
    }

    /// Lifts `code` above the others, or lowers the one lifted (nil).
    func select(_ code: String?) {
        guard code != selectedCode, let mapView else { return }
        if let lifted { mapView.removeOverlay(lifted.shape) }
        lifted = nil
        selectedCode = code
        guard let code, let country = atlas.country(code: code) else { return }
        let shape = CountryShape(country: country, lifted: true)
        lifted = (shape, nil)
        mapView.addOverlay(shape, level: .aboveLabels)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let mapView else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        guard let country = atlas.country(containing: coordinate) else {
            select(nil)
            return
        }
        onCountryTapped?(country)
    }
}

extension CountryLayer: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is MKAnnotationView { return false }
            if current === mapView { break }
            view = current.superview
        }
        return true
    }
}
