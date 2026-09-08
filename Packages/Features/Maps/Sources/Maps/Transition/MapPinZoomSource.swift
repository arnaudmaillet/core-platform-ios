import CoreNavigation
import MapKit
import MediaPlayback
import UIKit
import MediaCore

/// The map side of the hero transition: the tapped pin. It can recompute its
/// own on-screen rect from the annotation's coordinate, so a dismiss returns to
/// where the pin is *now* — even after the user panned the map underneath the
/// open feed — and reports when the pin has scrolled off so the animator can
/// fall back to a centered collapse. It also builds the flying media card: a
/// `PinCardView`, the same component the pin itself renders, so the card is an
/// exact twin at the handshake instant by construction.
@MainActor
final class MapPinZoomSource: ZoomTransitionSource {
    private weak var mapView: MKMapView?
    private let annotation: any MKAnnotation
    private var thumbnail: UIImage?
    /// The face the tapped marker was wearing. A text pin has no thumbnail, so
    /// without this the flight card would take off as an empty square from a
    /// marker the viewer just saw showing a symbol.
    private var face: PinCardView.Face
    /// Mirrors the pin's live preview player onto the flight card's render
    /// surface; returns whether the pin was actually live. `nil` when the
    /// source can't be live (a cluster, or no playback coordinator).
    private let mirrorLive: ((VideoRenderView) -> Bool)?
    /// The same question `mirrorLive` answers as a side effect, asked without
    /// one: is the tapped pin previewing live? Read at staging, before there is
    /// a card to mirror onto. `nil` for a source that was never given the
    /// probe — see `zoomFlightCarriesLivePlayer`.
    private let isLivePreviewing: (() -> Bool)?
    /// The hierarchy level the tapped marker's ring announced (a semantic
    /// cluster's city/country color), so the flying card takes off as
    /// the marker's exact twin — ring included. `nil` flies the neutral ring.
    private var ringKind: MapPlace.Kind?
    /// Which picture the card must show at the DEPARTURE end, asked when a
    /// dismissal stages and never before — the viewer's position in the feed is
    /// the one thing about this flight that is unknowable at the tap.
    ///
    /// Nil for a source that has no pager behind it, which is every present:
    /// the card takes off as the marker, which is the only post there has been.
    private let departureCover: (() -> MapReturnCover)?
    /// A second, LATE answer for the row `departureCover` had to decline: a
    /// picture that was not in memory when the flight staged.
    ///
    /// The alternative is to make staging wait on a network read, which would
    /// stall the first frame of a gesture the finger is already driving. This
    /// instead lets the flight start on today's behaviour and upgrade itself if
    /// the picture lands in time — and simply not upgrade if it does not.
    /// Called at most once per staging, on the main actor.
    private let awaitDepartureCover: ((@escaping (MapReturnCover) -> Void) -> Void)?
    /// What the last staging resolved, held so the card built for THAT flight
    /// is the one it dresses.
    private var stagedCover: MapReturnCover = .none
    /// The card in the air, so a late picture can still reach it. Weak: the
    /// flight owns it, and a finished flight must not be revived by an image
    /// that arrived after the landing.
    private weak var flyingCard: PinCardView?
    /// Matches the tapped marker's own geometry so the hero starts pin-sized —
    /// 56 for a media square, 44 for a text circle. Taking it from the face is
    /// what keeps the handshake exact for both: a text pin whose flight started
    /// at 56 would jump a size the instant the card replaced it.
    private var side: CGFloat { face.side }

    /// - Parameters:
    ///   - annotation: the tapped pin *or* cluster; its coordinate anchors the
    ///     hero and lets a dismiss re-find it after the map pans.
    ///   - thumbnail: the pin's cover image to fly (nil for a cluster → a plain
    ///     square).
    ///   - face: which `PinCardView` face the marker was wearing — `.text`
    ///     flies the symbol, `.media` flies `thumbnail`.
    ///   - mirrorLive: attaches the pin's live preview player to the flight
    ///     card's surface, so an animating pin flies live instead of freezing.
    ///   - isLivePreviewing: whether it WOULD, asked at staging. Pass it
    ///     alongside `mirrorLive` or the destination defers its playback for a
    ///     flight that carries no player.
    ///   - departureCover: see the property. Omitted means "no pager behind
    ///     this flight", and the card behaves exactly as it always has.
    init(
        mapView: MKMapView,
        annotation: any MKAnnotation,
        thumbnail: UIImage?,
        face: PinCardView.Face = .media,
        ringKind: MapPlace.Kind? = nil,
        mirrorLive: ((VideoRenderView) -> Bool)? = nil,
        isLivePreviewing: (() -> Bool)? = nil,
        departureCover: (() -> MapReturnCover)? = nil,
        awaitDepartureCover: ((@escaping (MapReturnCover) -> Void) -> Void)? = nil
    ) {
        self.mapView = mapView
        self.annotation = annotation
        self.thumbnail = thumbnail
        self.face = face
        self.ringKind = ringKind
        self.mirrorLive = mirrorLive
        self.isLivePreviewing = isLivePreviewing
        self.departureCover = departureCover
        self.awaitDepartureCover = awaitDepartureCover
    }

    /// Re-reads the marker and asks where the viewer stopped.
    ///
    /// Both halves are staging-time questions with stale answers at the tap.
    /// The MARKER's: a reconcile can have re-faced it, re-ringed it or replaced
    /// it outright while the feed was open, and `makeMapReturnSource` already
    /// rebuilds a whole source for exactly that reason — this brings the same
    /// freshness to the source that has to survive the round trip. The
    /// VIEWER's: the feed is a pager, and which post they are leaving is
    /// decided entirely after this source was built.
    func zoomSourceWillStageDismissal() {
        if let view = mapView?.view(for: annotation) {
            thumbnail = (view as? MapClusterAnnotationView)?.heroImage
                ?? (view as? MapAnnotationView)?.heroImage
                ?? thumbnail
        }
        if let cluster = annotation as? MapComputedCluster {
            face = PinCardView.Face.of(cluster.representative)
            ringKind = cluster.isHierarchyMarker ? cluster.place?.kind : nil
        } else if let pin = (annotation as? MapAnnotation)?.pin {
            face = PinCardView.Face.of(pin)
        }

        stagedCover = departureCover?() ?? .none
        guard case .none = stagedCover, let awaitDepartureCover else { return }
        // Only the row that came back empty is worth waiting on: a resolved
        // cover is already the answer, and asking again could only replace it
        // with a later, equally correct one mid-flight.
        awaitDepartureCover { [weak self] cover in
            guard let self, case .none = self.stagedCover else { return }
            self.stagedCover = cover
            self.flyingCard?.setDeparturePicture(cover.image())
        }
    }

    /// The flying card: the pin's exact twin — same component, same cover
    /// image and, when the pin was live-previewing, the *same player* mirrored
    /// onto the card's own render surface (two layers, one clock), so the
    /// flight carries the live video rather than a frozen copy of it.
    func makeZoomFlightCard() -> any ZoomFlightCard {
        let card = PinCardView()
        card.setFace(face)
        card.setRing(
            color: MapMarkerRing.color(for: ringKind), width: MapMarkerRing.width(for: ringKind)
        )
        // ⚠️ READ NOW, for the reason the avatar and the icon below both give.
        // `thumbnail` is a snapshot taken at the TAP, and a marker's cover
        // arrives asynchronously — so a card built from it flies whatever the
        // marker had loaded a moment earlier, which for a slow pin is nothing.
        card.imageView.image = mapView?.wornCover(for: annotation) ?? thumbnail
        // ⚠️ READ NOW, NOT AT INIT. A text marker wears its author, and that
        // face arrives asynchronously — a card built from an answer captured
        // when the source was constructed flies the fallback glyph while the
        // pin behind it shows the avatar. Same reason `zoomHeroFrame` re-reads
        // the annotation's rect instead of remembering one.
        card.setTextAvatar(mapView?.wornAvatar(for: annotation))
        // ⚠️ AND ITS ICON, read now for exactly the reason the avatar is. A
        // flying card built without it wore `.icon` — which hides the cover host
        // — with nothing to draw, so an icon marker's flight took off blank
        // while the marker behind it was perfectly dressed. Nil is fine and is
        // the fallback: the card then shows the disc `setTextAvatar` just put
        // under it.
        card.setIcon(mapView?.wornIcon(for: annotation))
        // ⚠️ AND ITS PREVIEW SHEET — the layer that was MOVING. Without this the
        // card is a still of a marker the viewer just watched animate, and the
        // "exact twin" this file promises is one rung short. It also seats the
        // third rung: `setPreviewSheet` writes the sheet's own frame zero into
        // the cover, so the card falls to the same picture the marker does.
        card.setPreviewSheet(mapView?.wornPreview(for: annotation))
        // The other end of the flight, when it is not this marker. Nil on every
        // present and on every dismissal that lands where it took off, which
        // leaves the card's blend channel inert.
        //
        // ⚠️ Never both this and a mirrored preview. `PinCardView` fades its
        // live surface WITH the departure operand, on the reading that a
        // dismissal's video is the departing page's own picture in motion —
        // but `mirrorLive` is the ARRIVAL marker's preview, so a card holding
        // both would fade out the very thing it is landing on. The two cannot
        // meet today (a mirrored pin is a lone `MapAnnotation`, whose feed is
        // one post, so its departure and arrival are the same post and the
        // cover is already `none`); this keeps that true if a cluster ever
        // learns to preview.
        if mirrorLive == nil {
            card.setDeparturePicture(stagedCover.image())
            flyingCard = card
        }
        if let mirrorLive {
            card.adoptZoomLiveMedia { surface in
                guard let renderView = surface as? VideoRenderView else { return false }
                return mirrorLive(renderView)
            }
        }
        return card
    }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        guard let mapView, zoomSourceIsOnScreen else {
            return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: side)
        }
        let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        return mapView.convert(rect, to: container)
    }

    /// ⚠️ PRESENCE AS WELL AS POSITION, and the second half is not redundant.
    ///
    /// The rect test alone answers about a COORDINATE, and a marker that a
    /// reconcile removed while the feed was open still has one — inside the
    /// viewport, as often as not. The flight then declines the centred fallback
    /// it exists for and lands on a square of empty map instead, while
    /// `setZoomSourceHidden` silently no-ops because there is no view to hide.
    /// Asking the map whether it still holds the annotation is the difference
    /// between a graceful collapse and a card settling onto nothing.
    var zoomSourceIsOnScreen: Bool {
        guard let mapView,
              mapView.annotations.contains(where: { ($0 as AnyObject) === (annotation as AnyObject) })
        else { return false }
        return mapView.visibleMapRect.contains(MKMapPoint(annotation.coordinate))
    }

    /// A marker's card flies a sprite sheet — a bundled animation with no
    /// player behind it — unless the pin was previewing live, in which case
    /// `makeZoomFlightCard` mirrors the pooled player onto it.
    ///
    /// The destination reads this to decide whether to hold its own playback
    /// back for the flight. Both sides scope the pool by the post's id, so a
    /// mirrored preview really is the page's own player and a start on the page
    /// really would blank the card; a sheet is nobody's player and the page
    /// should begin decoding at take-off.
    ///
    /// ⚠️ Answered at staging and durable by construction, not by luck: the
    /// present path freezes the coordinator (`setSurfaceVisible(false,
    /// keeping:)`) in the same synchronous stretch that builds this source, so
    /// no pin can start previewing between this answer and the take-off. And a
    /// map source implements no `zoomLiveMediaSurfaceIfReady`, so a flight that
    /// left without a player can never acquire one in the air.
    ///
    /// A source given a mirror but no probe cannot tell, and says the
    /// conservative thing rather than guessing.
    var zoomFlightCarriesLivePlayer: Bool {
        Self.fliesLivePlayer(canMirror: mirrorLive != nil, isLivePreviewing: isLivePreviewing?())
    }

    /// The rule above, as arithmetic — pinnable without an `MKMapView`, which
    /// this test target deliberately never builds (instantiating one contacts
    /// MapKit's services, the render-server work the CI doctrine keeps out).
    ///
    /// - Parameters:
    ///   - canMirror: whether this source could mirror a player at all. A
    ///     cluster cannot: it has no single post to ask about.
    ///   - isLivePreviewing: whether the pin is previewing right now, or `nil`
    ///     when nobody can be asked.
    static func fliesLivePlayer(canMirror: Bool, isLivePreviewing: Bool?) -> Bool {
        guard canMirror else { return false }
        return isLivePreviewing ?? true
    }

    /// The map itself, not the whole screen.
    ///
    /// The depth cue is a scale about the receding view's centre, so everything
    /// inside it shrinks and drifts toward that centre. Applied to the view
    /// controller's view that took the filter bars with it — measured at 48.00pt
    /// tall dropping to 45.60 through a grab, while the app's tab bar, which
    /// lives outside the presenter, did not move at all. Half the bottom
    /// furniture receding and half of it grounded reads as a glitch, not depth.
    ///
    /// Naming the map puts the recede on the content, which is the only thing the
    /// cue is about, and leaves the bars where they were laid out. They still
    /// darken under the flight's dim — the dim covers the whole container, and
    /// opacity moves nothing.
    var zoomPresenterDepthView: UIView? { mapView }

    /// Hides the live pin while its twin is flying, and restores it when the
    /// flight is over — called by the drivers in the same transaction that
    /// installs or retires the card, so no frame can render both (or neither).
    func setZoomSourceHidden(_ hidden: Bool) {
        mapView?.view(for: annotation)?.isHidden = hidden
    }
}
