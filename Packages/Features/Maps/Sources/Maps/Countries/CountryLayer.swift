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

    init(shape: CountryShape) {
        isLifted = shape.isLifted
        super.init(multiPolygon: shape)
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
/// forwards `rendererFor`; what a country's STYLE is (locked or not) and what
/// a tap on one DOES are the host's, through `styleFor` and `onCountryTapped`.
///
/// ⚠️ **A TAP ON A MARKER IS THE MARKER'S.** The country tap runs alongside
/// the map's own recognisers and stands down when the touch landed on an
/// annotation view, so opening a post never also picks the country under it.
@MainActor
final class CountryLayer: NSObject {
    /// The style of the country `code`. Asked when the borders are drawn and
    /// on `refreshStyles()`.
    var styleFor: (String) -> CountryStyle = { _ in .unlocked }
    /// A country was tapped (not a marker on it).
    var onCountryTapped: ((CountryAtlas.Country) -> Void)?

    private weak var mapView: MKMapView?
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
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
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
    }

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        guard let shape = overlay as? CountryShape else { return nil }
        let renderer = CountryRenderer(shape: shape)
        renderer.style = styleFor(shape.code)
        if shape.isLifted {
            lifted?.renderer = renderer
        } else {
            renderers[shape.code] = renderer
        }
        return renderer
    }

    /// Re-asks every country's style — after an unlock.
    func refreshStyles() {
        for (code, renderer) in renderers { renderer.style = styleFor(code) }
        lifted?.renderer?.style = styleFor(lifted?.shape.code ?? "")
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
