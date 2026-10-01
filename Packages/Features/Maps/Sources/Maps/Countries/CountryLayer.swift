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
/// `onLockedCountryTapped`, `onCountryTapped`). A country that no post marker
/// stands for — the host says which do (`setCountriesWithMarkers`) — wears
/// its flag in a disc at its label point (`CountryFlagAnnotation`), darkened
/// under a lock when it is locked.
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

    /// A locked country's flag disc was tapped.
    var onLockedCountryTapped: ((CountryAtlas.Country) -> Void)?
    /// An open country's flag disc was tapped.
    var onCountryTapped: ((CountryAtlas.Country) -> Void)?
    /// Which countries are open, and their standings. Nil: every country is
    /// open and nothing is sold (the fleet, until the backend carries it).
    var access: (any CountryAccess)?

    private weak var mapView: MKMapView?
    private var flags: [String: CountryFlagAnnotation] = [:]
    /// The countries a post marker currently stands for — no disc for those.
    private var countriesWithMarkers: Set<String> = []
    /// Every country's place by population, for the discs' priority where
    /// there is no standing (the fleet, or a country the backend has not
    /// ranked).
    private lazy var populationRanks: [String: Int] = Dictionary(
        uniqueKeysWithValues: atlas.countries
            .sorted { $0.population > $1.population }
            .enumerated()
            .map { ($1.code, $0 + 1) }
    )
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
            CountryFlagAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: CountryFlagAnnotationView.reuseIdentifier
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
            let countries = await Task.detached(priority: .userInitiated) {
                let countries = CountryAtlas.shared.countries
                // Every flag's picture and colours, off the main thread, before
                // the discs go on the map — the world zoom asks for two hundred
                // of them in one turn.
                FlagPalette.warm(countries.map(\.code))
                return countries
            }.value
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

    /// The countries a post marker stands for right now, told by the host
    /// after every layout: those wear no disc, every other country does.
    /// Free when nothing changed — the map re-lays out many times a second
    /// under a finger, and a set that did not move must not touch the map.
    func setCountriesWithMarkers(_ codes: Set<String>) {
        guard codes != countriesWithMarkers else { return }
        countriesWithMarkers = codes
        refreshBadges()
    }

    /// The disc a country wears, or nil when a post marker stands for it.
    func wantsFlag(for country: CountryAtlas.Country) -> (isLocked: Bool, rank: Int)? {
        guard !countriesWithMarkers.contains(country.code) else { return nil }
        let isLocked = access.map { !$0.isUnlocked(country.code) } ?? false
        let rank = access?.standing(of: country.code)?.rank
            ?? populationRanks[country.code]
            ?? atlas.countries.count
        return (isLocked, rank)
    }

    /// Puts a flag disc on every country no post marker stands for, and takes
    /// it off every country one now does. A disc whose lock or rank changed is
    /// replaced (its view reads both when it is configured).
    func refreshBadges() {
        guard let mapView, !shapes.isEmpty else { return }
        var wanted: [String: CountryFlagAnnotation] = [:]
        for country in atlas.countries {
            guard let flag = wantsFlag(for: country) else { continue }
            if let current = flags[country.code], current.isLocked == flag.isLocked, current.rank == flag.rank {
                wanted[country.code] = current
            } else {
                wanted[country.code] = CountryFlagAnnotation(country: country, isLocked: flag.isLocked, rank: flag.rank)
            }
        }
        let gone = flags.filter { wanted[$0.key] !== $0.value }.map(\.value)
        let new = wanted.filter { flags[$0.key] !== $0.value }.map(\.value)
        if !gone.isEmpty { mapView.removeAnnotations(gone) }
        if !new.isEmpty { mapView.addAnnotations(new) }
        flags = wanted
    }

    /// The disc view for a country.
    func view(for flag: CountryFlagAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: CountryFlagAnnotationView.reuseIdentifier, for: flag
        ) as? CountryFlagAnnotationView ?? CountryFlagAnnotationView(
            annotation: flag, reuseIdentifier: CountryFlagAnnotationView.reuseIdentifier
        )
        configure(view, for: flag)
        return view
    }

    /// Dresses a disc and says what its tap does: a locked country is
    /// OFFERED, an open one is shown.
    func configure(_ view: CountryFlagAnnotationView, for flag: CountryFlagAnnotation) {
        view.annotation = flag
        view.onSelect = { [weak self] in
            guard let self, let country = self.atlas.country(code: flag.code) else { return }
            if flag.isLocked {
                self.onLockedCountryTapped?(country)
            } else {
                self.onCountryTapped?(country)
            }
        }
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
