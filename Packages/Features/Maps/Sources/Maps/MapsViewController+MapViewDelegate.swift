import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// The map's delegate: markers, selection, regions, touch-down warm, idle
// preroll and flights (#2388, out of the map's file).

// MARK: - MKMapViewDelegate

extension MapsViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        countryLayer.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // A zoom/pan started: hold annotation mutations until it settles.
        isRegionTransitioning = true
        idlePrerollWork?.cancel()
        textBubbleRegionWillChange()
        #if DEBUG
        OfferLog.note("region will change")
        #endif
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Settled. The zoom level changed, so re-lay-out the clusters now (with
        // the settled projection), fold in anything a mid-flight diff staged,
        // then request the next page.
        isRegionTransitioning = false
        #if DEBUG
        logSettledCamera()
        #endif
        // The ceiling's camera distance, re-read at rest (#1907).
        depthClamp.calibrate()
        reconcileClustersForSettle()
        flushPendingDiffs()
        scheduleQuery()
        idlePrerollRested = false
        idlePrerollRetries = 0
        scheduleIdlePreroll()
        textBubbleRegionSettled()
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Land the ARRIVALS: scale-and-fade in, staggered across the batch.
        // This still fires for pins panning into the rendered region, not only
        // for a fresh query — which is what makes the map feel populated rather
        // than stamped.
        //
        // ⚠️ BUT NOT FOR EVERY VIEW MapKit HANDS OVER. It realizes the whole
        // visible set when the map comes back from a push, so popping the batch
        // meant the entire map re-landed on every return with nothing having
        // changed. The others are settled instead — explicitly, because a
        // recycled view can still be carrying a cancelled pop's alpha.
        let batch = Self.popPartition(views, pending: pendingPopIn) { view in
            view.annotation.map { ObjectIdentifier($0 as AnyObject) }
        }
        for view in batch.arriving {
            view.annotation.map { pendingPopIn.remove(ObjectIdentifier($0 as AnyObject)) }
        }
        // ⚠️ ONLY WHAT HAS SOMETHING TO SHOW LANDS. The map adds annotations
        // first and fetches their pictures second, never awaited, so popping
        // the whole batch lands bare squares that fill in afterwards. A marker
        // that is not dressed yet is held at zero and let in by its own report
        // — see `MapMarkerDressing` and `MapAnnotationPop.hold`.
        let dressed = batch.arriving.filter { ($0 as? any MapMarkerDressing)?.isDressed ?? true }
        let undressed = batch.arriving.filter { !(($0 as? any MapMarkerDressing)?.isDressed ?? true) }
        popChoreographer.popIn(dressed)
        popChoreographer.hold(undressed)
        popChoreographer.settle(batch.settled)
        // Annotation views now exist (clustering is current) → bind autoplay and
        // warm the visible posts so a tap opens instantly.
        refreshVideoPlayback()
        prewarmVisiblePosts()
        textBubbleViewsAdded(views)
        #if DEBUG
        debugOpenFirstPinIfRequested(among: views)
        debugOpenFirstClusterIfRequested(among: views)
        #endif
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        #if DEBUG
        MapChurnCounters.viewFor += 1
        #endif
        if let flag = annotation as? CountryFlagAnnotation {
            return countryLayer.view(for: flag, in: mapView)
        }
        if let cluster = annotation as? MapComputedCluster {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MapClusterAnnotationView.reuseIdentifier,
                for: annotation
            ) as? MapClusterAnnotationView
            view?.configure(
                with: cluster, dress: dress(for: cluster), imagePipeline: imagePipeline,
                iconCatalog: iconCatalog, previewCatalog: previewCatalog
            )
            // Instant tap — bypasses MapKit's ~0.3s selection delay.
            view?.onSelect = { [weak self, weak view] in
                self?.noteInstantTap(on: cluster)
                self?.openAnnotation(cluster, thumbnail: view?.heroImage)
            }
            view?.onDressed = { [weak self, weak view] in
                guard let self, let view else { return }
                popChoreographer.release(view)
            }
            // Back from a flight: reclaim the place a flag disc took while
            // the marker was hidden (see `MapAnnotationView.onReappear`).
            view?.onReappear = { [weak self] view in self?.countryLayer.giveWay(to: view.frame) }
            return view
        }
        guard let pinAnnotation = annotation as? MapAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: MapAnnotationView.reuseIdentifier,
            for: annotation
        ) as? MapAnnotationView
        view?.configure(
            with: pinAnnotation.pin, dress: dress(for: pinAnnotation), imagePipeline: imagePipeline,
            iconCatalog: iconCatalog, previewCatalog: previewCatalog
        )
        view?.onSelect = { [weak self, weak view] in
            self?.noteInstantTap(on: pinAnnotation)
            self?.openAnnotation(pinAnnotation, thumbnail: view?.heroImage)
        }
        view?.onTouchDown = { [weak self] in self?.beginPlaybackWarm(for: pinAnnotation) }
        view?.onTouchEnd = { [weak self] cancelled in self?.touchEnded(on: pinAnnotation, cancelled: cancelled) }
        view?.onDressed = { [weak self, weak view] in
            guard let self, let view else { return }
            popChoreographer.release(view)
            // Its preview sheet is on now: a candidate for the preroll (#654).
            scheduleIdlePreroll()
        }
        view?.onReappear = { [weak self] view in self?.countryLayer.giveWay(to: view.frame) }
        return view
    }


    /// Opens a tapped marker's post(s) with the hero transition — a single pin
    /// opens its post, a cluster opens all its members (their ids are already
    /// held locally, no extra round-trip). The re-entrancy guard makes this
    /// safe to call from both the instant tap recognizer and MapKit's own
    /// `didSelect` (the fallback): whichever lands first wins, the other is a
    /// no-op while the flight is alive.
    // MARK: - Touch-down warm (#646)

    /// A finger landed on a lone marker: start its post's page player
    /// now, at the clip time its sheet shows plus the decode, so the page that
    /// opens on touch-up joins a running player instead of starting one.
    ///
    /// ⚠️ INTENT, NOT PROXIMITY. No player is started for a marker nobody
    /// touches, and this one belongs to the post's page, not to the marker
    /// (`GeoDiscoveryRepository.previewVideoURL`'s rule stands).
    /// Whether a marker tap only closes the open offer and opens nothing
    /// (#686). Pure, for tests.
    static func markerTapClosesOffer(offerOpen: Bool) -> Bool { offerOpen }

    /// What a marker tap does while an offer is up (#760): another locked
    /// country's teaser moves the offer straight to that country; its own
    /// teaser leaves it be; any other marker closes it (#686).
    enum TapUnderOffer: Equatable { case switchTo(String), keep, close }

    static func tapUnderOffer(teaserCountry: String?, offeredCountry: String?) -> TapUnderOffer {
        guard let teaserCountry else { return .close }
        return teaserCountry == offeredCountry ? .keep : .switchTo(teaserCountry)
    }

    private func noteInstantTap(on annotation: any MKAnnotation) {
        instantTap = (ObjectIdentifier(annotation as AnyObject), CACurrentMediaTime())
    }

    /// Whether `didSelect` for `annotation` is the echo of an instant tap
    /// already handled. ⚠️ (#760) The echo used to reach `openAnnotation`
    /// with the offer the tap had just opened, and CLOSE it: the map zoomed
    /// in and straight back out.
    private func isEchoOfInstantTap(_ annotation: any MKAnnotation) -> Bool {
        guard let instantTap, instantTap.annotation == ObjectIdentifier(annotation as AnyObject) else { return false }
        return Self.isSelectionEcho(tappedAt: instantTap.at, now: CACurrentMediaTime())
    }

    /// MapKit selects ~0.3 s after the touch; a second deliberate tap on the
    /// same marker comes later than this. Pure, for tests.
    static func isSelectionEcho(tappedAt: CFTimeInterval, now: CFTimeInterval) -> Bool {
        now - tappedAt < 1.0
    }

    /// The locked country `annotation` is a teaser for, if it is one.
    private func lockedTeaserCountry(of annotation: any MKAnnotation) -> String? {
        guard let pin = (annotation as? MapComputedCluster)?.representative ?? (annotation as? MapAnnotation)?.pin,
              case .offer(let code) = Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: pin))
        else { return nil }
        return code
    }

    func beginPlaybackWarm(for annotation: MapAnnotation) {
        // ⚠️ NOT `pin.kind == .video`: production classifies every media pin
        // `.photo` (`GeoDiscoveryRepository.kind(for:)`), sheet-wearing ones
        // included. Whether there is a clip to warm is the POST's answer, and
        // the feed gives it (`FlightPlaybackWarm.warmableClip`).
        // No warm under an open offer: the tap will only close it (#686).
        guard offerSheet == nil, openGate.canOpen, playbackWarm?.postID != annotation.pin.postID else { return }
        endPlaybackWarm(opened: false)
        let time = warmMediaTime(for: annotation)
        // The marker the map prerolled: its player is already decoded and
        // paused — it plays on from the moment the marker shows now (#654).
        if promoteIdlePreroll(for: annotation.pin.postID, at: time) { return }
        // ONE player: a touch elsewhere spends the preroll's.
        endIdlePreroll()
        guard let warm = warmPlayback(annotation.pin.postID, time) else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] touch-down warm: nothing to warm for \(annotation.pin.postID.rawValue)")
            }
            #endif
            return
        }
        playbackWarm = (annotation.pin.postID, warm)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f touch-down warm %@ at %@", CACurrentMediaTime(),
                         annotation.pin.postID.rawValue, time.map { String(format: "%.2fs", $0) } ?? "start"))
        }
        #endif
    }

    /// The touch is over. A cancelled one (the map took it) lets go now; one
    /// that ended gives the tap its turn to open the post first.
    private func touchEnded(on annotation: MapAnnotation, cancelled: Bool) {
        guard let warm = playbackWarm, warm.postID == annotation.pin.postID else { return }
        guard !cancelled else { return endPlaybackWarm(opened: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmOpenWindow) { [weak self] in
            guard let self, let current = playbackWarm, current.warm === warm.warm else { return }
            endPlaybackWarm(opened: false)
        }
    }

    private func endPlaybackWarm(opened: Bool) {
        guard let warm = playbackWarm else { return }
        playbackWarm = nil
        warm.warm.end(opened: opened)
    }

    /// The clip time a warm for this marker should play from: the frame its
    /// sheet shows, plus the player's start-up.
    private func warmMediaTime(for annotation: MapAnnotation) -> TimeInterval? {
        guard case .sheet(let sheet)? = mapView.wornPreview(for: annotation)?.art,
              let frame = mapView.wornPreviewFrame(for: annotation) else { return nil }
        return MapPinZoomSource.flightMediaTime(sheet: sheet, displayedFrame: frame,
                                                lead: MapPinZoomSource.warmMediaLead)
    }

    // MARK: - Idle preroll (#654)

    /// The map came to rest: in `idlePrerollDelay`, preroll the player of the
    /// marker nearest the centre. A pan starting first cancels it.
    func scheduleIdlePreroll() {
        idlePrerollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateIdlePreroll() }
        idlePrerollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollDelay, execute: work)
    }

    /// ⚠️ ONE PLAYER, AND IT IS THE PAGE'S. The owner's call (2026-10-07):
    /// the marker nearest the centre gets its post's page player decoded to
    /// its first frame and paused, so a tap of any length flies live video
    /// from take-off. Nothing plays behind a marker
    /// (`GeoDiscoveryRepository.previewVideoURL`'s rule stands), and a paused
    /// player decodes nothing at rest.
    private func updateIdlePreroll() {
        guard !idlePrerollRested else { return }
        guard view.window != nil, activeTransition == nil, playbackWarm == nil, !isRegionTransitioning,
              offerSheet == nil,
              UIApplication.shared.applicationState == .active else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll: not now (window=\(view.window != nil) transition=\(activeTransition != nil) "
                      + "warm=\(playbackWarm != nil) moving=\(isRegionTransitioning) "
                      + "active=\(UIApplication.shared.applicationState == .active))")
            }
            #endif
            return endIdlePreroll()
        }
        let visible = mapView.visibleMapRect
        let candidates: [(id: PostID, point: MKMapPoint, annotation: MapAnnotation)] = mapView.annotations
            .compactMap { $0 as? MapAnnotation }
            .compactMap { annotation in
                let point = MKMapPoint(annotation.coordinate)
                guard visible.contains(point), mapView.view(for: annotation) != nil,
                      case .sheet? = mapView.wornPreview(for: annotation)?.art,
                      Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: annotation.pin)) == .open
                else { return nil }
                return (annotation.pin.postID, point, annotation)
            }
        let center = MKMapPoint(mapView.centerCoordinate)
        guard let chosen = Self.prerollCandidate(center: center, pins: candidates.map { ($0.id, $0.point) }),
              let annotation = candidates.first(where: { $0.id == chosen })?.annotation else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll: no sheet-wearing marker in view")
            }
            #endif
            return endIdlePreroll()
        }
        guard idlePreroll?.postID != chosen else { return }
        endIdlePreroll()
        guard let warm = prerollPlayback(chosen, warmMediaTime(for: annotation)) else {
            guard idlePrerollRetries < Self.idlePrerollRetryLimit else { return }
            idlePrerollRetries += 1
            let retry = DispatchWorkItem { [weak self] in self?.updateIdlePreroll() }
            idlePrerollWork = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollRetryDelay, execute: retry)
            return
        }
        idlePreroll = (chosen, warm)
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, idlePreroll?.warm === warm else { return }
            endIdlePreroll()
            idlePrerollRested = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                print("[zoom-live] idle preroll \(chosen.rawValue) let go: the map rested \(Int(Self.idlePrerollLifetime)) s")
            }
            #endif
        }
        idlePrerollExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idlePrerollLifetime, execute: expiry)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] idle preroll \(chosen.rawValue) of \(candidates.count) candidate(s)")
        }
        #endif
    }

    /// Hands the prerolled player to a touch or an open of its marker:
    /// playing on from `time`. False when the preroll is another marker's.
    private func promoteIdlePreroll(for postID: PostID, at time: TimeInterval?) -> Bool {
        guard let preroll = idlePreroll, preroll.postID == postID else { return false }
        idlePreroll = nil
        idlePrerollExpiry?.cancel()
        idlePrerollExpiry = nil
        preroll.warm.resume(at: time)
        playbackWarm = preroll
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] preroll promoted \(postID.rawValue) at \(time.map { String(format: "%.2fs", $0) } ?? "-")")
        }
        #endif
        return true
    }

    func endIdlePreroll() {
        idlePrerollWork?.cancel()
        idlePrerollWork = nil
        idlePrerollExpiry?.cancel()
        idlePrerollExpiry = nil
        guard let preroll = idlePreroll else { return }
        idlePreroll = nil
        preroll.warm.end(opened: false)
    }

    /// The marker a preroll goes to: the one nearest the centre. Pure, for tests.
    static func prerollCandidate(center: MKMapPoint, pins: [(id: PostID, point: MKMapPoint)]) -> PostID? {
        pins.min { center.distance(to: $0.point) < center.distance(to: $1.point) }?.id
    }

    func openAnnotation(_ annotation: any MKAnnotation, thumbnail: UIImage?) {
        // ⚠️ AN OPEN OFFER SWALLOWS THE TAP (#686), as a tap on the map does:
        // tapping away is "no thanks". Here, ahead of everything, so the
        // instant tap, MapKit's `didSelect`, VoiceOver and the DEBUG hooks all
        // meet it. A sheet already on its way down still swallows it — a fast
        // second tap must not open a post during the descent.
        if Self.markerTapClosesOffer(offerOpen: offerSheet != nil) {
            switch Self.tapUnderOffer(
                teaserCountry: lockedTeaserCountry(of: annotation), offeredCountry: offerSheet?.country.code
            ) {
            case .switchTo(let code):
                if let country = CountryAtlas.shared.country(code: code) { offer(country) }
            case .keep:
                break
            case .close:
                closeOffer(returning: true)
            }
            return
        }
        guard openGate.canOpen else { return }
        let postIDs = Self.postIDs(of: annotation)
        guard !postIDs.isEmpty else { return }
        // A locked country's marker is a teaser, not a door: it offers the
        // country — what the old locked badge did — and opens nothing.
        if let pin = (annotation as? MapComputedCluster)?.representative ?? (annotation as? MapAnnotation)?.pin,
           case .offer(let code) = Self.markerTap(for: dress(for: annotation), countryCode: countryCode(of: pin)) {
            if let country = CountryAtlas.shared.country(code: code) { offer(country) }
            return
        }
        let face = Self.face(of: annotation)
        #if DEBUG
        // Which face a tapped marker wears decides its TRANSITION
        // (`MapMarkerPresentation`: media flies, everything else slides in,
        // #2015). Without this line, "the present animation is wrong" and
        // "this marker is not the face you think" are indistinguishable from
        // outside.
        print("[maps] tap face=\(face) presentation=\(MapMarkerPresentation(face: face)) "
              + "posts=\(postIDs.count) first=\(postIDs.first?.rawValue ?? "-")")
        #endif
        switch MapMarkerPresentation(face: face, reducesMotion: HeroMotionPolicy.prefersNativePush) {
        case .plainPush where navigationController != nil:
            // ⚠️ EVERY NON-MEDIA MARKER (#2015, the owner 2026-11-01): a text
            // post — a text marker, an avatar, an emote, a GIF — opens with
            // the platform's own slide, and closes with it (the plain push
            // pins its native close). It opened as a window growing out of
            // the disc since #125. Through the feed's shared plain-push seam
            // so this screen gets the same swipe-back it gets everywhere.
            //
            // The map's own chrome is left alone on purpose: the filter bars
            // live in this view and slide out WITH it, where the flight has to
            // hide them because the map stays visible under the card. The tab
            // bar is hidden and restored by the seam, and previews stop and
            // resume through the ordinary appearance callbacks — all of which
            // are keyed on `activeTransition == nil`, which is exactly what
            // this path is. The marker stays on the map under the push.
            guard openGate.openBegan(.plainPush) else { return }
            // A HIERARCHY marker always offers its place page, whatever face
            // it wears (a city or country is a place before it is a
            // photograph): the same builder the hero's Case B uses, handed
            // through the seam so the DOWNWARD dismissal lands on it — the
            // rightward one is the plain slide back to the map. Same
            // criterion as the hero path — `isHierarchyMarker` — and a band's
            // group of one is its place's marker too (`hierarchyPlace(of:)`).
            let hierarchyPlace = Self.hierarchyPlace(of: annotation)
            let placePage: ((UIViewController) -> UIViewController)? = hierarchyPlace.map { place in
                let mapReturn = makeMapReturnSource(for: annotation)
                let markerClose = makeMarkerClose(for: annotation)
                let country = countryCode(of: annotation)
                let centre = annotation.coordinate
                return { [makeClusterGallery] feed in
                    makeClusterGallery(postIDs, place, country, centre, feed, mapReturn, markerClose)
                }
            }
            #if DEBUG
            // `-maps-open-place`: pushes the place page ON ITS OWN.
            //
            // ⚠️ THIS SCREEN HAD NO SCRIPTED ROUTE AT ALL. It is inserted under
            // the cluster feed and uncovered by a vertical dismissal — a gesture
            // no harness can inject, and the nearest arguments all land
            // somewhere else (`-snap-auto-dismiss` pops past it to the map, the
            // vertical grab opens the comments). So its layout could only ever
            // be judged by hand, and a change to it could only be verified by
            // asking someone to go and look.
            //
            // Pushed directly here it is the same controller with the same
            // content; what it does NOT exercise is the dismissal that normally
            // uncovers it, which keeps its own arguments.
            if ProcessInfo.processInfo.arguments.contains("-maps-open-place"),
               let placePage {
                navigationController?.pushViewController(placePage(UIViewController()), animated: true)
                return
            }
            #endif
            pushPlainSnapFeed(postIDs, self, placePage)
        case .plainPush, .hero:
            // No stack to push onto: the window has nowhere to open, so the
            // feed is presented instead — the same concession the plain push
            // already made.
            presentSnapFeed(postIDs: postIDs, from: annotation, thumbnail: thumbnail)
        }
    }

    /// Whether MapKit's selection of `annotation` opens it: never a country's
    /// flag disc, whose own recognizer took the tap (#760).
    static func mapSelectionOpens(_ annotation: any MKAnnotation) -> Bool {
        !(annotation is CountryFlagAnnotation)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // Deselect immediately so the pin can be tapped again after dismissal.
        // The instant-tap recognizer normally fires first; this is the fallback
        // (and clears MapKit's own selection either way).
        guard let annotation = view.annotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)
        // ⚠️ A COUNTRY'S FLAG DISC HAS TAKEN ITS TAP ALREADY (#760): its own
        // recognizer offered the country; MapKit's selection, landing a beat
        // later, read as a tap under the open offer and CLOSED it — the zoom
        // in and straight back out.
        guard Self.mapSelectionOpens(annotation), !isEchoOfInstantTap(annotation) else { return }

        let thumbnail = (view as? MapAnnotationView)?.heroImage
            ?? (view as? MapClusterAnnotationView)?.heroImage
        openAnnotation(annotation, thumbnail: thumbnail)
    }

    /// Everything the tapped marker stands for, in the order the feed should
    /// page through it: one post for a lone pin, the WHOLE group for a cluster
    /// with its representative first.
    ///
    /// The same answer whatever the posts are. A cluster's members are already
    /// held client-side (`MapClusterEngine` folded them), so a text post, a
    /// photo and a video that happen to sit on the same corner all travel
    /// together into one swipeable feed — the presentation differs (see
    /// `MapMarkerPresentation`), never the corpus.
    ///
    /// Pure and static so the passthrough can be tested without a live
    /// `MKMapView`: dropping members here would be invisible on screen — the
    /// feed would simply end early — which is exactly the kind of silent
    /// truncation a test has to pin.
    static func postIDs(of annotation: any MKAnnotation) -> [PostID] {
        switch annotation {
        case let pin as MapAnnotation: [pin.pin.postID]
        case let cluster as MapComputedCluster: cluster.memberIDs
        default: []
        }
    }

    /// The MARKER's window, asked for at close time.
    ///
    /// Identical to the arguments the text-pin route already passes, so the two
    /// routes' windows are the same window — a marker opened as a hero and a
    /// marker opened as a reveal close the same way. The extra `dismissalDidEnd`
    /// is the close-out the hero's own `onSourceReturned` performs and a card
    /// close never reaches; the concealment is paid back by the animator.
    func markerRevealOrigin(for annotation: any MKAnnotation) -> TextRevealOrigin {
        MapPinRevealSource.origin(
            mapView: mapView,
            annotation: annotation,
            face: Self.face(of: annotation),
            dress: dress(for: annotation),
            concealMarker: { [weak mapView] concealed in
                mapView?.view(for: annotation)?.isHidden = concealed
            },
            depthView: { [weak self] in self?.view },
            dismissalDidEnd: { [weak self] committed in
                guard let self else { return }
                // ⚠️ REPORTED WHATEVER THE OUTCOME. This is the reveal route's
                // ONLY terminal signal, and the gate needs the cancelled case
                // as much as the committed one.
                openGate.dismissalBegan()
                openGate.dismissalEnded(committed: committed)
                guard committed else { return }
                // A BACKSTOP — the close's commit has normally shown the dock.
                // A card close finished the flight's pop: the session's
                // close-out, the gate already settled above.
                activeSession?.close(.abandoned)
            }
        )
    }

    /// Which screen a card close is aiming at.
    ///
    /// ⚠️ THE POP'S DESTINATION DECIDES, not the post. A vertical grab lands on
    /// the place page and closes onto its Activity row; everything else — the
    /// chevron, a horizontal grab, and both axes when there is no place page at all —
    /// lands on the MAP, so it closes onto the marker whatever post the viewer
    /// paged to. Aiming a card at a screen the pop is not going to is how a
    /// close ends up with no animation at all.
    enum MapCardCloseTarget: Equatable { case marker, placeCard }

    static func closeTarget(axis: ZoomDismissAxis, hasLanding: Bool) -> MapCardCloseTarget {
        // Down onto the place page; right and up (the end of the list,
        // #761) onto the marker.
        axis.landsBeneath && hasLanding ? .placeCard : .marker
    }

    /// Where a place page goes when a vertical dismissal commits: beneath the
    /// feed it is landing from.
    ///
    /// Pure, and separate from the navigation call for the same reason
    /// `postIDs(of:)` is: the rule needs no live `MKMapView`, and a wrong
    /// answer here is invisible on screen until someone presses back.
    /// Nil means "nothing to do" — already inserted, or no feed to insert under.
    static func stack(
        _ current: [UIViewController], inserting landing: UIViewController,
        beneath feed: UIViewController
    ) -> [UIViewController]? {
        guard !current.contains(landing),
              let index = current.firstIndex(of: feed) else { return nil }
        var next = current
        next.insert(landing, at: index)
        return next
    }

    /// …and back out again when that dismissal is abandoned.
    static func stack(
        _ current: [UIViewController], removing landing: UIViewController
    ) -> [UIViewController]? {
        guard current.contains(landing) else { return nil }
        return current.filter { $0 !== landing }
    }

    /// The face the tapped marker is wearing, so the flight card takes off as
    /// its twin — a symbol pin must not fly as an empty square.
    /// Internal (not private) only for the +QA hooks.
    static func face(of annotation: any MKAnnotation) -> PinCardView.Face {
        let pin = (annotation as? MapAnnotation)?.pin
            ?? (annotation as? MapComputedCluster)?.representative
        return pin.map(PinCardView.Face.of) ?? .media
    }

    private func presentSnapFeed(postIDs: [PostID], from annotation: any MKAnnotation, thumbnail: UIImage?) {
        // The page about to open joins the player its touch-down started
        // (#646); any other post's warm has nothing to hand over. One with a
        // picture already FLIES: the card carries it from its first frame.
        // An open with no touch-down (VoiceOver, a programmatic select) still
        // takes the marker's preroll (#654); any other post's goes.
        if playbackWarm == nil, let pin = annotation as? MapAnnotation {
            _ = promoteIdlePreroll(for: pin.pin.postID, at: warmMediaTime(for: pin))
        }
        endIdlePreroll()
        let warm = playbackWarm.flatMap { postIDs.first == $0.postID ? $0.warm : nil }
        let warmFlies = warm?.hasPicture ?? false
        endPlaybackWarm(opened: warm != nil)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print("[zoom-live] open: warm=\(warm == nil ? "none" : (warmFlies ? "flies" : "no picture yet"))")
        }
        #endif
        let feedVC = makeSnapFeed(postIDs)
        guard let nav = navigationController,
              let destination = feedVC as? any ZoomTransitionDestination else {
            // ⚠️ THE DEFENSIVE BRANCH TAKES THE LOCK TOO. It set neither flag,
            // so two taps could `present` twice — and presenting over a
            // presentation raises rather than degrades.
            guard openGate.openBegan(.modalFallback) else { return }
            // Defensive: without the hero seam (or a stack), show it plainly.
            if let nav = navigationController {
                feedVC.hidesBottomBarWhenPushed = true
                nav.pushViewController(feedVC, animated: true)
            } else {
                present(feedVC, animated: true)
            }
            return
        }
        // A live-previewing pin flies live: its pooled player is mirrored onto
        // the flight card's own render surface (same player → same frame), so
        // the flight never freezes the preview mid-loop.
        let tappedID = (annotation as? MapAnnotation)?.pin.postID
        let coordinator = videoCoordinator
        let source = MapPinZoomSource(
            mapView: mapView,
            annotation: annotation,
            thumbnail: thumbnail,
            face: Self.face(of: annotation),
            // The marker's flag border and badge ride the flight, so the card
            // is the tapped marker's twin down to its furniture — neutral for
            // anything that isn't the active band's own marker.
            dress: dress(for: annotation),

            // A touch-down warm with a picture is the page's own player, live
            // (#646): the card flies it from take-off — no sheet, no fade —
            // and the page, told so, joins it rather than starting its own.
            mirrorLive: warmFlies ? warm.map { warm in { renderView in warm.mirror(onto: renderView) } }
                : tappedID.map { id in
                { renderView in coordinator.mirrorLivePreview(of: id, to: renderView) }
            },
            // Asked while this transition is being constructed — before the
            // freeze three dozen lines below, which is what makes the answer
            // hold for the whole flight.
            isLivePreviewing: warmFlies ? { true } : tappedID.map { id in
                { coordinator.isLivePreviewing(id) }
            },
            // Asked at DISMISSAL staging, so it reports where the viewer
            // actually stopped rather than where they started. The card lands
            // on this marker either way; only its departure face adapts.
            departureCover: { [weak self, weak feedVC] in
                self?.returnCover(to: annotation, leaving: feedVC) ?? .none
            },
            awaitDepartureCover: { [weak self, weak feedVC] report in
                self?.awaitReturnCover(to: annotation, leaving: feedVC, then: report)
            }
        )
        // A *push*, not a modal: the feed joins this tab's stack, so the one
        // navigation bar cross-fades the map's items into the feed's back item
        // + author capsule natively — no second bar to pop in over the first.
        // The transition object is the stack's delegate for the feed's
        // lifetime.
        guard openGate.openBegan(.hero) else { return }
        let session = HeroPushSession(source: source, destination: destination, on: nav)
        let transition = session.controller
        activeSession = session

        // CASE B (cluster-gallery milestone): a HIERARCHY marker — the active
        // band's own city or country cluster — carries a place page beneath
        // its feed. The page joins the stack invisibly in the same
        // transaction as the feed (UIKit animates a stack whose last element
        // is new exactly like a push, and never even loads the mid
        // controller's view), and the VERTICAL grab closes the active post
        // onto the page's Activity row instead of back to the pin — as the
        // card close beside this flight (`attachCardCloseAlongsideFlight`),
        // for EVERY post: the page refuses a hero (`zoomLandingAcceptsHero`),
        // so the vertical flight driver below stays armed only to decline.
        // ORDINARY clusters
        // — proximity groups, even ones whose members happen to share a leaf
        // place — and local single pins skip all of this: only a city or a
        // country has a place page (product call, 2026-08-31). A band's group
        // of ONE is a city or a country, and gets it (`hierarchyPlace(of:)`).
        var gallery: UIViewController?
        if let place = Self.hierarchyPlace(of: annotation) {
            let built = makeClusterGallery(
                postIDs, place, countryCode(of: annotation), annotation.coordinate, feedVC,
                makeMapReturnSource(for: annotation),
                makeMarkerClose(for: annotation)
            )
            gallery = built
            if let gallerySource = built as? any ZoomTransitionSource {
                transition.setDismissSource(gallerySource, for: built)
                // ⚠️ NOT UPWARD (#761): the end of the list closes to the map,
                // through the marker driver below.
                transition.attachInteractiveDismissal(
                    to: feedVC.view, axes: [.vertical], armsUpward: false, towards: gallerySource
                ) { [built, weak nav, weak feedVC] in
                    // ⚠️ THE PAGE JOINS THE STACK HERE, at the last moment
                    // before the pop that lands on it — the mirror of the
                    // reveal route's own splice. `built` is captured STRONGLY:
                    // the dismiss target holds it weakly, so until this runs
                    // this closure chain is the page's only owner.
                    //
                    // A plain stack transaction with nothing transitioning,
                    // which is the one condition under which it is reliable.
                    if let nav, let feedVC,
                       let plan = Self.stack(
                           nav.viewControllers, inserting: built, beneath: feedVC
                       ) {
                        nav.setViewControllers(plan, animated: false)
                    }
                    // Nothing about the dock here: this pop lands on the place
                    // page, and the feed brings the bar back through UIKit once
                    // the release commits. The filter bars are invisible under
                    // the gallery either way.
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-grab-log") {
                        print("[caseb] splice+pop delegate=\(nav?.delegate.map { "\(type(of: $0))" } ?? "nil")"
                              + " stack=\(nav?.viewControllers.map { "\(type(of: $0))" } ?? [])")
                    }
                    #endif
                    feedVC?.closeScreen(whenBusy: .drop)
                }
            }
            // Its landing is the session's `.toIntermediate` ending (below).
        }

        // ONE close-out per ending (`HeroPushSession.Ending`). The session has
        // already ended its leases on the stack's delegate slot; a place page
        // that leased it on top keeps it.
        //
        // ⚠️ `.reversed` is the flight caught mid-air and thrown back, which
        // once had no handler here at all: the latch stayed set and every
        // marker tap for the rest of the session did nothing.
        session.onClose = { [weak self, source] ending in
            guard let self else { return }
            self.activeSession = nil
            self.barsStack.alpha = 1
            switch ending {
            case .toIntermediate:
                // The gallery is the screen now, an ordinary one; the map's
                // chrome settles silently beneath it (invisible until the
                // gallery pops, when `viewWillAppear` resumes previews). The
                // present flight hid the tapped marker, and nothing on the
                // gallery path would ever restore it.
                self.openGate.dismissedToIntermediate()
                source.setZoomSourceHidden(false)
                return
            case .reversed:
                self.openGate.presentationCancelled()
                // The card close armed beside the flight serves a feed that
                // never showed; released a turn later, as the closing callbacks
                // of these objects may still be unwinding.
                let abandonedClose = self.cardClose
                self.cardClose = nil
                DispatchQueue.main.async { withExtendedLifetime(abandonedClose) {} }
            case .returned:
                self.openGate.dismissalBegan()
                self.openGate.dismissalEnded(committed: true)
            case .abandoned:
                break // whoever ended it settled the gate
            }
            self.tabBarController?.showTabBarNativelyNextTurn()
            self.videoCoordinator.setSurfaceVisible(true)
            self.idlePrerollRested = false
            self.refreshVideoPlayback()
            self.scheduleIdlePreroll()
            // The flight froze the bars' inset (`syncBarsPosition` stands down
            // while one is up); the screen is at rest again.
            self.syncBarsPosition()
        }

        var didLand = false
        transition.onDestinationShown = { [weak self, weak transition] in
            // Landed (fires again if a detail above the feed pops back — the
            // flight-scoped work must run once): release the donor player.
            guard !didLand else { return }
            didLand = true
            self?.openGate.destinationShown()
            self?.videoCoordinator.stopAll()

            #if DEBUG
            // `[delay]`, for the reason its two siblings grew one: a run that
            // PAGES the feed first cannot be scripted against a hard-coded
            // 1.5s, and the vertical dismissal onto a place page is only
            // interesting once the viewer has moved off the post the cluster
            // opened on.
            if let position = ProcessInfo.processInfo.arguments
                .firstIndex(of: "-maps-demo-grab") {
                let arguments = ProcessInfo.processInfo.arguments
                let delay = position + 1 < arguments.count
                    ? (Double(arguments[position + 1]) ?? 1.5) : 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    transition?.debugScriptedGrab()
                }
            }
            #endif
        }
        // ⚠️ THE BAR IS NOT THE FLIGHT'S, and nothing here writes its alpha.
        // UIKit shows it once the close is committed (`viewWillAppear`'s
        // policy, and the feed's own close); this is the backstop. See
        // `TabBarRevealPolicy`.
        transition.onDismissalCancelled = { [weak self, gallery, weak nav, weak feedVC] in
            // The feed is STAYING, so the gate does not reopen — it goes back to
            // `.open`, which is what `committed: false` means.
            self?.openGate.dismissalBegan()
            self?.openGate.dismissalEnded(committed: false)
            // The feed is staying up: the filter bars go back down behind it.
            // The dock was never raised — it waits for a COMMITTED release.
            self?.barsStack.alpha = 0
            // ⚠️ THE UNDO IS NOW A REMOVAL, and it used to be an insertion.
            //
            // With the page off the stack at rest, an abandoned VERTICAL grab
            // is a page that was spliced in and never landed on — so this takes
            // it back out, and the back button and the horizontal close keep
            // their map landing. `gallery` is captured STRONGLY on purpose:
            // between the splice and this cancel, this closure chain is the
            // only thing keeping it alive.
            //
            // Deferred one runloop turn, and that hop is load-bearing: this
            // callback fires inside `completeTransition(false)`'s own call
            // stack, and a `setViewControllers` issued there is silently
            // swallowed by UIKit's post-cancel bookkeeping — measured in-sim.
            DispatchQueue.main.async { [weak nav] in
                guard let nav, let gallery,
                      let plan = Self.stack(nav.viewControllers, removing: gallery)
                else { return }
                nav.setViewControllers(plan, animated: false)
            }
        }
        // Accessing `view` loads it so the grab-to-dismiss pan can attach.
        if let clusterGallery = gallery {
            // Case B's HORIZONTAL escape: straight back to the map.
            //
            // ⚠️ IT NO LONGER DROPS ANYTHING, because there is nothing on the
            // stack to drop — the page is spliced in by the vertical grab
            // alone. This used to reorder the stack first (a scrubbed multi-pop
            // is not an option: UIKit commits a popTo's mutation at begin and a
            // cancel does not restore it, see `InteractivePopToStackTests`), and
            // keeping a now-redundant removal would hide a regression of the
            // new invariant rather than expose it. What is left is the
            // ordinary, fully cancellable single pop the pin grab has always
            // been, landing on the map so the default (pin) source flies the
            // card home. Axes stay disjoint with the gallery driver above:
            // exactly one of the two ever claims a drag.
            _ = clusterGallery
            // Right, and up past the end of the list (#761): both to the map.
            transition.attachInteractiveDismissal(to: feedVC.view, axes: [.horizontal, .upward]) {
                [weak feedVC] in
                // The bottom chrome comes back from `viewWillAppear`, which
                // this pop runs — see the pin grab below.
                feedVC?.closeScreen(whenBusy: .drop)
            }
        } else {
            // Case A (single pin / generic cluster): both axes fly home to
            // the pin.
            transition.attachInteractiveDismissal(to: feedVC.view) { [weak feedVC] in
                // ⚠️ NOTHING ABOUT THE DOCK AT GRAB-BEGIN any more. It used to
                // put the bar's state back here at alpha 0 and show it at the
                // landing. A grab is a question until it is released: the pop
                // below runs this screen's `viewWillAppear`, which restores the
                // filter bars and hands the dock to `TabBarRevealPolicy` —
                // UIKit shows it when the release commits.
                feedVC?.closeScreen(whenBusy: .drop)
            }
        }
        // Map is covered by the feed → stop its previews, except the tapped
        // pin's, which the flight card is still rendering. Set *before* the
        // push so the map's viewWillDisappear sweep is a no-op that can't
        // touch the donor.
        videoCoordinator.setSurfaceVisible(false, keeping: tappedID)
        // Tab bar managed by hand, NOT hidesBottomBarWhenPushed: that flag's
        // bottom-bar choreography doesn't scrub with a custom interactive pop
        // (the bar snaps in at pop-begin and flashes over the feed when a grab
        // cancels). By hand — through UIKit's API, on UIKit's animation — it
        // leaves with the lift-off, stays hidden through cancelled grabs,
        // and comes back once a close is committed. Constraint: a
        // programmatic cross-tab route while the feed is pushed would find the
        // bar hidden — today no such route fires from inside the feed.
        tabBarController?.hideTabBarNatively()
        setFilterBar(hidden: true)
        session.takeDelegateSlot()
        // ⚠️ NOT pre-paying the destination's layout here, and the empty space
        // is deliberate.
        //
        // For You calls `zoomPrepareForPresentation` before its own push, and
        // the same call was added here for parity. It is the wrong trade on
        // this screen: the map builds a FRESH feed on every tap
        // (`makeSnapFeed`), so the layout it pre-pays is a cold one, and it
        // runs synchronously — plus a `CATransaction.flush` — between the
        // finger coming up and the flight starting. Reported as a long pause
        // between tapping a marker and the animation beginning, which is worse
        // than the frame pacing it was buying: a stall the viewer is waiting
        // through beats one they are watching an animation through.
        //
        // The seam is left in place (`ZoomTransitionDestination`), because the
        // measurement that would justify calling it — a cold feed laid out off
        // the tap's critical path — is the thing to take before trying again.
        // ⚠️ AN ORDINARY PUSH, WHATEVER CASE THIS IS — and the place page is
        // NOT in it.
        //
        // It used to join the stack in the same transaction as the feed, on the
        // reasoning that the gallery is never SEEN. True, and beside the point:
        // a stack is not only what is drawn, it is what BACK means. With the
        // page sitting under the feed, the chevron's single pop landed on a
        // place page the viewer had never asked for and had no way to predict
        // — filmed twice, from a country marker and from a city one.
        //
        // The reveal route reached this conclusion first and states it in its
        // own words (`FeedFeatureBuilder.pushWithoutFlight`): the page is
        // INSERTED for a committed vertical dismissal and taken out again if
        // that dismissal is abandoned, "so the back button and the horizontal
        // close keep their map landing". Two routes, one rule, and only one of
        // them had it.
        nav.pushViewController(feedVC, animated: true)
        // ⚠️ UNCONDITIONALLY, INCLUDING CASE A. A single pin had no slide
        // driver at all, so its chevron fell through to UIKit's native pop —
        // the hero declines a `.card` close outright, and nothing else was
        // listening. `arbitratesWithHeroGrab` keeps the two grabs disjoint and
        // the `.hero` forward happens before any geometry is read, so a media
        // post's close is still the flight.
        attachCardCloseAlongsideFlight(
            feed: feedVC, gallery: gallery,
            markerOrigin: markerRevealOrigin(for: annotation), on: nav
        )
    }

    /// A dismissal for the posts this flight cannot carry.
    ///
    /// ⚠️ THE FEED IS A PAGER AND THE PRESENTATION WAS CHOSEN AT THE TAP. A
    /// media-faced marker opens with a hero; swipe to a TEXT post and there is
    /// no media left for that hero to fly. Both zoom grabs then refuse —
    /// `ZoomDismissInteractionController` gates on `zoomDismissalKind != .card`
    /// BEFORE it looks at the axis, so the horizontal one refuses too — and
    /// the native edge pop is already disclaimed. Measured: on that page the
    /// drag did nothing at all, on either axis, and the back chevron was the
    /// only way out.
    ///
    /// For You hit this first and answered it with exactly this driver
    /// (`attachCardCloseAlongsideFlight`); Case B never received the
    /// equivalent. `arbitratesWithHeroGrab` is what divides the work: each
    /// side refuses the other's kind, so exactly one claims any grab.
    private func attachCardCloseAlongsideFlight(
        feed: UIViewController, gallery: UIViewController?,
        markerOrigin: TextRevealOrigin, on nav: UINavigationController
    ) {
        // Optional now: the MARKER landing needs no place page, so the driver
        // must exist even when there is none to land on.
        let landing = gallery as? any CardCloseLanding
        let slide = InteractiveSlideDismissal()
        cardClose = slide
        // It holds the stack's slot on the flight's behalf.
        activeSession?.registerForwarder(slide)
        #if DEBUG
        print("[card-close] map armed placePage=\(landing != nil)")
        #endif
        // ⚠️ FIRST, because arming resets the driver — every setter below
        // (`fallbackSlideAxis` among them) has to land after it.
        armCardClose(slide, feed: feed, landing: landing, markerOrigin: markerOrigin)
        // ⚠️ DOWNWARD ONTO A PLACE PAGE, EVERY POST IS THIS DRIVER'S — media
        // included. After the arming above, which resets it.
        //
        // The page's landing is its ACTIVITY row, with the post the viewer is
        // on moved to the top (`PlaceProfileViewController.cardCloseGeometry`):
        // the close a TEXT marker's feed has always had, and the one filmed as
        // right (Paris). A media marker's feed used to hand a photograph's
        // downward close to the hero instead, which flew it onto a DISCOVER
        // tile — the tab chosen by the kind of post the marker wore (Lyon).
        // The page now refuses a flight (`zoomLandingAcceptsHero`), and this
        // asks that same answer, so the vertical hero grab and this driver
        // cannot both decline — or both claim — one drag. Rightward, and with
        // no page at all, the hero keeps every photograph it had.
        let gallerySource = gallery as? any ZoomTransitionSource
        slide.heroClaimsAxis = { [weak gallerySource] axis in
            !axis.landsBeneath || gallerySource?.zoomLandingAcceptsHero != false
        }
        // ⚠️ THE DEFAULT AXES, deliberately restored. Restricting the window
        // to `[.vertical]` made a horizontal grab a percent-driven SLIDE, and
        // the chevron a plain one — which is the fallback that was filmed. Both
        // now close as a window onto the marker; `fallbackSlideAxis` stays as
        // the floor for the case where no geometry could be staged at all.
        slide.fallbackSlideAxis = .horizontal
        // The bottom chrome is NOT the closing window's: the filter bars come
        // back from `viewWillAppear` and the dock through UIKit once the close
        // is committed (the feed's own close, and `viewWillAppear`'s policy),
        // with the marker origin's `dismissalDidEnd` as the landing's
        // backstop — exactly as the hero's own return does.
        slide.onWillBeginPop = { [weak nav, weak feed, gallery] axis in
            guard axis.landsBeneath, let gallery, let nav, let feed,
                  let plan = Self.stack(
                      nav.viewControllers, inserting: gallery, beneath: feed
                  )
            else { return }
            nav.setViewControllers(plan, animated: false)
            // ⚠️ AND OUT AGAIN FOR AN ABANDONED SWIPE — the removal the hero's
            // own vertical grab has in `onDismissalCancelled`, which this
            // driver now needs for every post rather than only text ones:
            // left spliced, the back button that follows lands on a place page
            // the viewer never asked for. Both hops are load-bearing, for the
            // reasons `FeedFeatureBuilder.pushWithoutFlight` measured: the
            // coordinator exists only once the pop has begun (next turn), and
            // a `setViewControllers` inside `completeTransition(false)`'s call
            // stack is silently swallowed.
            DispatchQueue.main.async { [weak nav, weak feed] in
                guard let coordinator = feed?.transitionCoordinator else { return }
                coordinator.animate(alongsideTransition: nil) { context in
                    guard context.isCancelled else { return }
                    DispatchQueue.main.async { [weak nav, weak feed] in
                        guard let nav, let feed, nav.topViewController === feed,
                              let plan = Self.stack(nav.viewControllers, removing: gallery)
                        else { return }
                        nav.setViewControllers(plan, animated: false)
                    }
                }
            }
        }
        // The backstop: whatever animated the close, no tile stays hidden. The
        // staging above conceals one, and only the reveal's own completion
        // pays that back — a pop finished by anything else would leave a hole
        // in the mosaic for good.
        slide.onFeedPopped = { [weak self, weak landing, weak nav, gallery] _ in
            landing?.clearLandingConcealment()
            // Idempotent, and only where there is a page: a card close that was
            // armed and then abandoned leaves it spliced in, and the back
            // button must still find the map. Case A never had one.
            if let gallery, let nav,
               let plan = Self.stack(nav.viewControllers, removing: gallery),
               nav.topViewController !== gallery {
                nav.setViewControllers(plan, animated: false)
            }
            self?.cardClose = nil
        }
        // AFTER the push, so the flight controller is what `install` captures
        // and a `.hero` pop forwards straight back to it.
        slide.install(on: nav)
        #if DEBUG
        debugScriptCardCloseIfRequested(slide)
        #endif
    }

    /// The map's two landings, armed through the SHARED helper
    /// (`armAsCardCloseAlongsideFlight`) — the close For You, a profile and
    /// the place page's own tiles make.
    ///
    /// What the helper brings is the shared rules: both axes, arbitrated
    /// against the hero grab, the reset, and a staging asked ONLY for a close
    /// that carries a card. What stays here is only the landing: the marker's
    /// window, or the place page's card.
    ///
    /// ⚠️ RESTAGED ON EVERY ATTEMPT (`restagesOnEveryAttempt`), not once.
    /// The helper's latch assumes one landing per presentation; this screen
    /// has two, chosen by the AXIS. Latched, a vertical grab abandoned
    /// half-way would leave the place card's geometry armed for the chevron
    /// that follows, and the window would shrink onto a tile that is not on
    /// screen. So each landing keeps its own rule inside the staging:
    ///
    /// * the MARKER is rebuilt at every ask — a pure build whose rect and
    ///   stand-in are resolved at ask time (`MapPinRevealSource.origin`), so a
    ///   recycled or moved marker view is found again on the next attempt;
    /// * the PLACE CARD is staged once and remembered, because its staging
    ///   ADOPTS a tile (a move that undoes itself if repeated) — and handed
    ///   back on a later vertical attempt, even after a marker attempt
    ///   replaced it in between.
    private func armCardClose(
        _ slide: InteractiveSlideDismissal, feed: UIViewController,
        landing: (any CardCloseLanding)?, markerOrigin: TextRevealOrigin
    ) {
        var placeCardGeometry: RevealGeometry?
        // ⚠️ `slide` WEAKLY: the driver owns this closure and the closure
        // writes back through the driver, so a strong capture is a retain
        // cycle — every card close ever staged would keep its driver alive
        // for the life of the process, one per opened post, and invisible to
        // every census, because what leaks is a DRIVER and nothing counts
        // those. `cardClose = nil` cannot help: the cycle holds the object
        // whether or not this controller still points at it.
        slide.armAsCardCloseAlongsideFlight(
            on: feed, restagesOnEveryAttempt: true
        ) { [weak self, weak landing, weak slide] feed, axis in
            guard let self, let slide else { return false }
            switch Self.closeTarget(axis: axis, hasLanding: landing != nil) {
            case .marker:
                slide.revealGeometry = self.makeRevealGeometry(feed, markerOrigin, nil)
            case .placeCard:
                if placeCardGeometry == nil {
                    placeCardGeometry = landing?.cardCloseGeometry(dismissing: feed)
                }
                // Nil (no card to aim at yet) leaves the plain slide, and the
                // next attempt asks again.
                slide.revealGeometry = placeCardGeometry
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-grab-log") {
                print("[card-close] stage axis=\(axis)"
                      + " geometry=\(slide.revealGeometry != nil)")
            }
            #endif
            return slide.revealGeometry != nil
        }
    }
}
