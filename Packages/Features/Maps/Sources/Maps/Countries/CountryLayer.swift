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
/// of the selected one — a raised look: a brighter fill, a fine white rim and
/// a drop shadow, all faded in by `lift`.
///
/// ⚠️ **THE SHADOW IS SCALED BY THE ZOOM.** A renderer draws in map points,
/// and a shadow offset or blur given in screen points would shrink to nothing
/// at a continent's zoom and swallow the country at a street's.
final class CountryRenderer: MKMultiPolygonRenderer {
    var style: CountryStyle = .unlocked { didSet { if style != oldValue { applyStyle() } } }
    /// How far the lifted copy has risen, 0...1: its opacity, and how far its
    /// shadow has spread. Stepped by `CountryLayer` to fade a pick in and out.
    var lift: CGFloat = 1 {
        didSet {
            guard lift != oldValue else { return }
            alpha = lift
            setNeedsDisplay()
        }
    }
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
            fillColor = UIColor.white.withAlphaComponent(style == .locked ? 0.2 : 0.12)
            strokeColor = .white
            // Fine: a rim, not a marker stroke ("trop grossier" at 3).
            lineWidth = 1.5
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
        // The shadow grows with the lift: the country rises off the map.
        context.setShadow(
            offset: CGSize(width: 0, height: 6 * lift / zoomScale),
            blur: 18 * lift / zoomScale,
            color: UIColor.black.withAlphaComponent(0.4).cgColor
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
/// `access`, and what a tap on one DOES is the host's (`onMapTapped`,
/// `onLockedBadgeTapped`). Locked countries also wear a badge at their centre
/// (`LockedCountryAnnotation`) with their rank.
///
/// ⚠️ **A TAP ON A MARKER IS THE MARKER'S.** The country tap runs alongside
/// the map's own recognisers and stands down when the touch landed on an
/// annotation view, so opening a post never also picks the country under it.
///
/// ⚠️ **A PICK IS INSTANT, LIKE A MARKER'S.** The tap no longer waits for a
/// double tap to fail (~0.3 s, felt as lag). It fires on the first touch-up,
/// and the host undoes it if another touch follows (`onTouchDown`): the second
/// tap of a double-tap zoom, or the start of a pan.
@MainActor
final class CountryLayer: NSObject {
    /// The map was tapped (not a marker): the country under the finger, or
    /// nil at sea.
    var onMapTapped: ((CountryAtlas.Country?) -> Void)?
    /// A finger came down on the map (not on a marker).
    var onTouchDown: (() -> Void)?
    /// The user started moving the map: a pan, a pinch or a rotation.
    var onMapGesture: (() -> Void)?

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
    /// The lifts being faded, in or out (`LiftFade`).
    private var fades: [LiftFade] = []
    private var fadeLink: CADisplayLink?
    private weak var tap: UITapGestureRecognizer?
    private(set) var selectedCode: String?
    /// Whether the borders are on the map (the atlas decodes off main first).
    var hasBorders: Bool { !shapes.isEmpty }
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
        mapView.addGestureRecognizer(tap)
        self.tap = tap
        // Watchers for the map being MOVED, alongside MapKit's own gestures:
        // they never take a touch, they only say it began.
        let watchers: [UIGestureRecognizer] = [
            UIPanGestureRecognizer(target: self, action: #selector(moved(_:))),
            UIPinchGestureRecognizer(target: self, action: #selector(moved(_:))),
            UIRotationGestureRecognizer(target: self, action: #selector(moved(_:))),
        ]
        for watcher in watchers {
            watcher.delegate = self
            watcher.cancelsTouchesInView = false
            watcher.delaysTouchesEnded = false
            mapView.addGestureRecognizer(watcher)
        }
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
            if lifted?.shape === shape { lifted?.renderer = renderer }
            if let index = fades.firstIndex(where: { $0.shape === shape }) {
                // Born at the fade's start: a pick fades in from nothing.
                renderer.lift = fades[index].from
                fades[index].renderer = renderer
            }
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

    /// Lifts `code` above the others, or lowers the one lifted (nil). The
    /// lift fades in (and out): the rim, the fill and the shadow rise
    /// together over `LiftFade.rise`, an ease-out, so a pick reads as the
    /// country coming up to the finger rather than a stamp.
    func select(_ code: String?, animated: Bool = true) {
        guard code != selectedCode, let mapView else { return }
        if let lifted {
            // A copy MapKit has not drawn yet has nothing to fade: it just goes.
            if animated, let renderer = lifted.renderer {
                fade(lifted.shape, renderer: renderer, from: renderer.lift, to: 0)
            } else {
                fades.removeAll { $0.shape === lifted.shape }
                mapView.removeOverlay(lifted.shape)
            }
        }
        lifted = nil
        selectedCode = code
        guard let code, let country = atlas.country(code: code) else { return }
        let shape = CountryShape(country: country, lifted: true)
        lifted = (shape, nil)
        if animated { fade(shape, renderer: nil, from: 0, to: 1) }
        mapView.addOverlay(shape, level: .aboveLabels)
    }

    // MARK: - Fading a lift

    /// One lift fading in or out. The clock starts when the renderer exists —
    /// MapKit asks for it a turn after the overlay is added.
    private struct LiftFade {
        static let rise: CFTimeInterval = 0.24
        static let fall: CFTimeInterval = 0.18
        let shape: CountryShape
        var renderer: CountryRenderer?
        let from: CGFloat
        let to: CGFloat
        var start: CFTimeInterval?
    }

    private func fade(_ shape: CountryShape, renderer: CountryRenderer?, from: CGFloat, to: CGFloat) {
        fades.removeAll { $0.shape === shape }
        fades.append(LiftFade(shape: shape, renderer: renderer, from: from, to: to, start: nil))
        renderer?.lift = from
        guard fadeLink == nil else { return }
        let link = CADisplayLink(target: FadeTicker(self), selector: #selector(FadeTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    fileprivate func stepFades(at now: CFTimeInterval) {
        var finished: [CountryShape] = []
        for index in fades.indices {
            guard let renderer = fades[index].renderer else { continue }
            let start = fades[index].start ?? now
            fades[index].start = start
            let rising = fades[index].to > fades[index].from
            let duration = rising ? LiftFade.rise : LiftFade.fall
            let progress = min(1, (now - start) / duration)
            let eased = 1 - pow(1 - progress, 3)
            renderer.lift = fades[index].from + (fades[index].to - fades[index].from) * eased
            if progress >= 1 { finished.append(fades[index].shape) }
        }
        for shape in finished {
            guard let index = fades.firstIndex(where: { $0.shape === shape }) else { continue }
            let fade = fades.remove(at: index)
            // Faded out: the copy leaves the map.
            if fade.to == 0 { mapView?.removeOverlay(shape) }
        }
        if fades.isEmpty {
            fadeLink?.invalidate()
            fadeLink = nil
        }
    }

    // MARK: - Touches

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let mapView else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        onMapTapped?(atlas.country(containing: coordinate))
    }

    @objc private func moved(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        onMapGesture?()
    }
}

/// A display link's target that does not retain the layer.
private final class FadeTicker: NSObject {
    weak var layer: CountryLayer?
    init(_ layer: CountryLayer) { self.layer = layer }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let layer else { return link.invalidate() }
        layer.stepFades(at: link.targetTimestamp)
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
        // Every finger that lands on the map, told once (by the tap).
        if gestureRecognizer === tap { onTouchDown?() }
        return true
    }
}
