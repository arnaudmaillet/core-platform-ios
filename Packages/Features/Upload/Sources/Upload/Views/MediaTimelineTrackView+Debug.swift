import DesignSystem
import MediaPlayback
import UIKit

// The track's test hooks (#2388), DEBUG only.
extension MediaTimelineTrackView {
    #if DEBUG
    /// Internal for tests: the track's own state, and re-entry through the very
    /// routines a finger uses rather than around them.
    var debugTimeline: MediaTimeline { timeline }
    var debugFrameCount: Int { tiles.count }
    /// Internal for tests: the picture each square of film is SHOWING, keyed by
    /// its place on the track.
    ///
    /// ⚠️ **THE PICTURE ITSELF, NOT THE SECOND IT OUGHT TO BE.** Asking the track
    /// which second a tile stands for and comparing it with the same function's
    /// answer proves nothing; the only question that cannot be laundered is which
    /// image is on screen. The suite pairs this with a provider that hands back a
    /// different object per second.
    /// Every square of film on screen: where it is DRAWN and what it is SHOWING.
    /// A test pairs this with a provider that hands back a different object per
    /// second, which is how it can ask whether a piece's film travelled with it.
    ///
    /// ⚠️ **DRAWN**: where a square has a view, `from`/`width` are that view's
    /// rectangle in film coordinates (which are content x), read through the
    /// window it stands in.
    var debugFilm: [(piece: Int, from: CGFloat, width: CGFloat, picture: UIImage?)] {
        squares.map { square in
            guard let view = tiles[square.place] else {
                return (square.piece, square.from, square.width, nil)
            }
            let drawn = view.convert(view.bounds, to: film)
            return (square.piece, drawn.minX, drawn.width, view.picture.image)
        }
    }
    /// Internal for tests: where each square's PICTURE is laid inside it. ⚠️ THE
    /// DRAWN EVIDENCE OF THE CROP — a square the window cuts in half must hold a
    /// full-width picture hanging out of itself, not a squeezed one.
    var debugFilmCrop: [(width: CGFloat, picture: CGRect)] {
        squares.compactMap { square in
            tiles[square.place].map { ($0.bounds.width, $0.picture.frame) }
        }
    }
    /// Internal for tests: every piece's window, read off its layer — frames in
    /// film coordinates, in play order.
    var debugFilmWindows: [(
        piece: Int, frame: CGRect, radius: CGFloat, corners: CACornerMask,
        clips: Bool, curve: CALayerCornerCurve
    )] {
        windows.sorted { $0.key < $1.key }.map { piece, window in
            (
                piece, window.frame, window.layer.cornerRadius, window.layer.maskedCorners,
                window.clipsToBounds, window.layer.cornerCurve
            )
        }
    }
    /// Internal for tests: every square's view — where it is drawn in film
    /// coordinates, which window it stands in, and whether it carries a radius
    /// of its own (it must not).
    var debugTiles: [(
        place: MediaTimelining.Square.Place, frame: CGRect, windowPiece: Int?, cornerRadius: CGFloat
    )] {
        tiles.map { place, view in
            let window = windows.first { $0.value === view.superview }?.key
            return (place, view.convert(view.bounds, to: film), window, view.layer.cornerRadius)
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }
    /// Internal for tests: for each square on screen, where the sheet puts its
    /// picture and where the picture is actually drawn — both in film
    /// coordinates. Carving daylight must move neither.
    var debugPictureOnTheSheet: [(sheet: CGFloat, drawn: CGFloat)] {
        squares.compactMap { square in
            tiles[square.place].map { view in
                (square.filmFrom, view.convert(view.picture.frame, to: film).minX)
            }
        }
    }
    /// Internal for tests: the four inner-corner plates, in content coordinates.
    var debugFillets: [(
        frame: CGRect, isShowing: Bool, isBehindTheFilm: Bool, isWhite: Bool,
        hasCorners: Bool, hasShadow: Bool
    )] {
        let filmAt = content.subviews.firstIndex(of: film) ?? -1
        return innerCorners.map { plate in
            (
                plate.frame, !plate.isHidden,
                (content.subviews.firstIndex(of: plate) ?? .max) < filmAt,
                plate.backgroundColor == .white,
                plate.layer.cornerRadius > 0, plate.layer.shadowOpacity > 0
            )
        }
    }
    /// Internal for tests: whether ANY part of the selection's ink is showing.
    var debugSelectionInkShowing: Bool {
        ([topBar, bottomBar, startGrab, endGrab] + innerCorners).contains { !$0.isHidden }
    }
    /// Internal for tests: the caps' own shapes — their outer radius and which
    /// corners it rounds, and the shadow's extent in the cap's coordinates.
    var debugCapShapes: [(
        width: CGFloat, height: CGFloat, radius: CGFloat, corners: CACornerMask,
        shadowRadius: CGFloat, shadowPath: CGPath?
    )] {
        [startGrab, endGrab].map { cap in
            (
                cap.bounds.width, cap.bounds.height, cap.layer.cornerRadius, cap.layer.maskedCorners,
                cap.layer.shadowRadius, cap.layer.shadowPath
            )
        }
    }
    /// Internal for tests: the reach's source, to compare with the drawn caps.
    var debugHeldCaps: (start: ClosedRange<CGFloat>, end: ClosedRange<CGFloat>)? {
        heldCaps().map { ($0.start, $0.end) }
    }
    /// ⚠️ **Internal for tests: CHARTER T6, WALKED.** Every layer in the track
    /// wider or taller than the Metal limit at `scale` that is decorated in a
    /// way that needs a texture that size — rounded, masked, clipping
    /// sublayers, rasterised, shadowed, or holding contents.
    func debugLayersPastTheMetalLimit(scale: CGFloat) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer) {
            let longest = max(layer.bounds.width, layer.bounds.height) * scale
            if longest > 16384 {
                let decorated = layer.cornerRadius > 0 || layer.mask != nil
                    || (layer.masksToBounds && !(layer.sublayers ?? []).isEmpty)
                    || layer.shouldRasterize || layer.shadowOpacity > 0
                    || layer.contents != nil
                    || ((layer as? CAShapeLayer)?.path.map {
                        max($0.boundingBoxOfPath.width, $0.boundingBoxOfPath.height) * scale > 16384
                    } ?? false)
                if decorated {
                    let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? "CALayer"
                    found.append("\(owner) \(Int(layer.bounds.width))x\(Int(layer.bounds.height))")
                }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(layer)
        return found
    }
    static var debugSeamGap: CGFloat { Metrics.seamGap }
    static var debugFilmCorner: CGFloat { Metrics.filmCorner }
    static var debugCapCorner: CGFloat { Metrics.capCorner }
    static var debugCapShadowBlur: CGFloat { Metrics.capShadowBlur }
    static var debugFilletTuck: CGFloat { Metrics.filletTuck }
    static var debugBar: CGFloat { Metrics.bar }
    static var debugStampInset: CGFloat { Metrics.stampInset }
    static var debugStrip: CGFloat { Metrics.strip }
    /// Internal for tests: where the film row starts, in the track's coordinates.
    var debugStripY: CGFloat { stripY }
    /// Internal for tests: the rate stamps THEMSELVES, to ask where they stand in
    /// the z-order.
    var debugStampIsUnderTheFrame: Bool {
        guard let rail = content.subviews.firstIndex(of: topBar) else { return false }
        return rateStamps.allSatisfy { (content.subviews.firstIndex(of: $0) ?? .max) < rail }
    }
    /// Internal for tests: how many pictures are decoded and alive (charter T3).
    var debugDecodedCount: Int { decoded.count }
    /// Internal for tests: where the squares of film are DRAWN, in film
    /// coordinates, so a test can ask whether the last one stops at the end of
    /// the result.
    var debugTileFrames: [CGRect] { tiles.values.map { $0.convert($0.bounds, to: film) } }
    /// Internal for tests: which squares of film have a view on screen right
    /// now, in the order they are drawn.
    var debugTileIndices: [MediaTimelining.Square.Place] {
        squares.map(\.place).filter { tiles[$0] != nil }
    }
    /// Internal for tests: whether every tile on screen is showing something
    /// (charter F14).
    var debugEveryTileHasAPicture: Bool { tiles.values.allSatisfy { $0.picture.image != nil } }
    /// ⚠️ **THERE IS NOTHING LEFT TO DIM, AND THAT IS THE AXIS CHANGE.** The
    /// discarded head and tail used to be drawn greyed out beside the kept film,
    /// because the track was a picture of the FILE. It is a picture of the RESULT
    /// now: what is thrown away is simply not on it, and the way back is to drag
    /// a piece's edge out again. `debugPieceFrames` is what replaces this —
    /// where the kept pieces are, which is all there is.
    var debugContentWidth: CGFloat { scroller.contentSize.width }
    var debugCentringInset: CGFloat { scroller.contentInset.left }
    var debugContentOffset: CGFloat { scroller.contentOffset.x }
    /// Internal for tests: whether the track is holding a way of asking for
    /// pictures at all. Between two clips it must not be — the closure belongs to
    /// one file.
    var debugHasFramesProvider: Bool { framesProvider != nil }
    /// Internal for tests: whether the film is in the middle of an eased move.
    var debugIsEasing: Bool { isEasing }
    var debugFramesGeneration: Int { framesGeneration }
    /// ⚠️ **Internal for tests: whether an animation is ACTUALLY ON THE LAYER.**
    /// `contentOffset` is the model value and `UIView.animate` sets it at once —
    /// reading it back says where the film is GOING, never whether it is easing
    /// there. `uiview-animate-from-value-trap` records the same lesson about
    /// `alpha`. The layer's own animation keys are the only honest answer.
    var debugScrollIsAnimating: Bool {
        scroller.layer.animationKeys()?.isEmpty == false
    }
    var debugSecondsUnderNeedle: Double { sourceSecondsUnderNeedle }
    var debugKeptText: String? { keptLabel.isHidden ? nil : keptLabel.text }
    /// ⚠️ THE READOUT IS FIXED, NOT ON THE FILM — so it is inside the track's own
    /// bounds whatever the scroll offset is.
    var debugKeptIsOnScreen: Bool { bounds.contains(keptLabel.frame) && !keptLabel.isHidden }
    /// Internal for tests: whether the play button is showing the pause glyph.
    var debugShowsPause: Bool { playButton.accessibilityLabel == "Pause" }
    /// The play button's glyph as configured (the owner's ▶︎ / ❚❚, #2276).
    var debugPlayGlyph: UIImage? { playButton.configuration?.image }
    /// Internal for tests: the pieces of the selection's frame, in content
    /// coordinates, so a test can ask whether it actually closes.
    var debugTopRail: CGRect { topBar.frame }
    var debugBottomRail: CGRect { bottomBar.frame }
    var debugStartGrip: CGRect { startGrab.frame }
    var debugEndGrip: CGRect { endGrab.frame }
    var debugFilmFrame: CGRect { film.frame }
    /// Internal for tests: where the SELECTED piece is drawn, in content points
    /// — what its caps must stand outside of.
    var debugSelectedRangeX: ClosedRange<CGFloat>? {
        guard let index = selected else { return nil }
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        guard let chosen = placed.first(where: { $0.index == index }) else { return nil }
        return chosen.from...max(chosen.to, chosen.from)
    }
    /// Internal for tests: taps the film where a finger would, through the very
    /// routine the recogniser calls — a tap's location cannot be set.
    func debugTap(atContentX x: CGFloat) { takeOrPutDown(atContentX: x) }
    /// Internal for tests: carries a piece the way a long press and a drag do.
    func debugLift(atContentX x: CGFloat) { lift(atContentX: x) }
    func debugCarry(toTrackX x: CGFloat) { carry(toTrackX: x) }
    func debugDrop() { drop() }
    /// Internal for tests: whether a piece is being carried right now.
    var debugCarrying: Int? { reordering }
    /// Internal for tests: whether the film can still be pushed past the needle.
    var debugScrollIsEnabled: Bool { scroller.isScrollEnabled }
    /// Internal for tests: where the shot list's chips are LAID, in the track's
    /// own coordinates and in play order — the whole of what a carry shows.
    ///
    /// ⚠️ **THE PLACEMENT, NOT `frame` — A FRAME IS READ THROUGH THE TRANSFORM.**
    /// The chip in hand is scaled, so its `frame` is 6% wider than the place it
    /// was given and hangs a few points off the leading edge. Asked that way, "are
    /// the chips the same width" is a question about the lift as much as about
    /// the layout, and it answered no. The lift has its own hook below.
    ///
    /// ⚠️ **CONVERTED OUT OF THE LIST, WHICH SCROLLS** — a finger reports track
    /// coordinates, and a test aiming at a chip must be told where it is on the
    /// track.
    var debugShotFrames: [CGRect] { shots.map { shotList.convert($0.placement, to: self) } }
    /// Internal for tests: which chip is lifted, and how far back the others
    /// stand. ⚠️ ASKED OF THE CHIPS THEMSELVES, not of `reordering` — the state
    /// says a piece is held, and only the drawing says the author can SEE it.
    var debugShotInHand: Int? { shots.firstIndex { $0.isInHand } }
    /// Internal for tests: how opaque each chip is — ⚠️ ALL OF THEM, ALWAYS, since
    /// a see-through chip is what the author reported — and which ones are
    /// shaded behind the one in hand.
    var debugShotOpacity: [CGFloat] { shots.map(\.alpha) }
    var debugShotShaded: [Bool] { shots.map(\.debugIsShaded) }
    /// Internal for tests: where each chip is DRAWN, lift included — which is
    /// what the daylight between two of them has to be measured on.
    var debugShotDrawnFrames: [CGRect] { shots.map { shotList.convert($0.frame, to: self) } }
    /// Internal for tests: how far the shot list has scrolled, how far it runs,
    /// and whether a finger could scroll it.
    var debugShotListOffset: CGFloat { shotList.contentOffset.x }
    var debugShotListWidth: CGFloat { shotList.contentSize.width }
    var debugShotListScrolls: Bool {
        !shotList.isHidden && shotList.isScrollEnabled
            && shotList.contentSize.width > shotList.bounds.width + 0.5
    }
    /// Internal for tests: whether the list is scrolling by itself.
    var debugListIsScrollingByItself: Bool { edgeScroll.link != nil }
    /// Internal for tests: one step of the list scrolling by itself, through the
    /// routine the display link calls — a link's clock cannot be set.
    func debugScrollTheList(forSeconds elapsed: Double) { scrollTheList(forSeconds: elapsed) }
    /// Internal for tests: a second finger scrolling the list.
    func debugScrollTheList(toOffset x: CGFloat) { shotList.contentOffset.x = x }
    static var debugShotMinimum: CGFloat { Metrics.shotMinimum }
    static var debugEdgeZone: CGFloat { Metrics.edgeZone }
    /// Internal for tests: what is animating on each chip and inside it.
    var debugShotAnimations: [[String]] { shots.map(\.debugAnimations) }
    var debugShotPictureAnimations: [[String]] { shots.map(\.debugPictureAnimations) }
    var debugShotPictureFrames: [CGRect] { shots.map(\.debugPictureFrame) }
    /// Internal for tests: the picture each chip shows.
    var debugShotPictures: [UIImage?] { shots.map(\.debugPicture) }
    /// Internal for tests: what is animating on the film — every window and
    /// every square — and on the frame.
    var debugFilmAnimations: [String] {
        (Array(windows.values) as [UIView] + Array(tiles.values) as [UIView])
            .flatMap { $0.layer.animationKeys() ?? [] }
    }
    var debugFrameAnimations: [String] {
        ([topBar, bottomBar, startGrab, endGrab, startGlyph, endGlyph] + innerCorners)
            .flatMap { $0.layer.animationKeys() ?? [] }
    }
    /// Internal for tests: where the ruler's marks are DRAWN, in the track's own
    /// coordinates, and what they say.
    var debugRulerMarkCentres: [CGFloat] {
        ruler.debugMarkCentres.map { $0 + ruler.frame.minX }
    }
    /// Internal for tests: the chips THEMSELVES, in play order.
    ///
    /// ⚠️ **IDENTITY, BECAUSE AN INDEX ANSWERS ITS OWN QUESTION.** "Which index is
    /// in hand" is decided by the same number the assertion reads, so a chip that
    /// stayed behind while its piece moved still answers it correctly — and is
    /// showing the wrong piece's film. Proved by deliberate break: leaving the
    /// chips where they were turned nothing red until this hook existed.
    var debugShotIdentities: [ObjectIdentifier] { shots.map(ObjectIdentifier.init) }
    /// Internal for tests: whether a press here would carry anything — the very
    /// predicate the delegate answers with, so the scroll is not taken hostage by
    /// a press that has nothing to lift.
    func debugWouldLift(atContentX x: CGFloat) -> Bool { wouldLift(atContentX: x) }
    /// Internal for tests: every `+` on screen, in content points, in order.
    var debugSeamMarks: [(index: Int, centre: CGPoint, hit: CGRect, glyph: String?)] {
        seamButtons.sorted { $0.key < $1.key }.map { index, button in
            (index, button.center, button.frame, button.debugGlyph)
        }
    }
    /// Internal for tests: whether any `+` can be seen at all.
    var debugSeamMarksShowing: Bool { !seamButtons.isEmpty && scroller.alpha > 0 && !scroller.isHidden }
    /// Internal for tests: taps a `+` exactly as a finger would.
    func debugTapSeam(_ index: Int) { seamButtons[index]?.sendActions(for: .primaryActionTriggered) }
    static var debugSeamHitSize: CGFloat { SeamButton.hitSize }
    /// Internal for tests: where each `+` is DRAWN, transform included.
    var debugSeamMarkFrames: [CGRect] { seamButtons.sorted { $0.key < $1.key }.map(\.value.frame) }
    /// Internal for tests: what each cap shows, start then end — "hidden",
    /// "grip", or the symbol DRAWN in place of the grip.
    var debugCapMarks: [String] {
        [(startGrab, startGrip, startGlyph), (endGrab, endGrip, endGlyph)].map { grab, line, glyph in
            if grab.isHidden { return "hidden" }
            switch (line.isHidden, glyph.isHidden) {
            case (false, true): return "grip"
            case (true, false): return MediaTransitionCatalog.debugSymbol(drawnIn: glyph.image) ?? "unknown"
            case (false, false): return "both"
            case (true, true): return "none"
            }
        }
    }
    /// Internal for tests: each cap's glyph box in content points, and the
    /// image's own size; nil where the glyph is hidden.
    var debugCapGlyphs: [(frame: CGRect, image: CGSize)?] {
        [startGlyph, endGlyph].map { glyph in
            glyph.isHidden ? nil : (glyph.convert(glyph.bounds, to: content), glyph.image?.size ?? .zero)
        }
    }
    var debugCapGlyphImageAssignments: Int { capGlyphImageAssignments }
    var debugCapGlyphAnimations: [String] {
        [startGlyph, endGlyph].flatMap { $0.layer.animationKeys() ?? [] }
    }
    var debugGrip: MediaTimelining.Edge? { grip }
    /// Internal for tests: whether any `+` would answer a finger.
    var debugSeamTakesTouches: Bool { seamButtons.values.contains { $0.isUserInteractionEnabled } }
    /// Internal for tests: the collapsed film's line, in content points.
    var debugLineFrames: [CGRect] { lineSegments.map(\.frame) }
    /// Internal for tests: the lit stretch and the transition's mark, in
    /// content points, or nil where nothing is drawn.
    var debugRehearsalFrame: CGRect? { rehearsalBar.isHidden ? nil : rehearsalBar.frame }
    var debugWindowFrame: CGRect? { windowMark.isHidden ? nil : windowMark.frame }
    var debugWindowCorner: CGFloat { windowMark.layer.cornerRadius }
    var debugNeedleFrame: CGRect { needle.frame }
    /// Internal for tests: what is animating on the film VIEW itself — the
    /// collapse — as opposed to the pieces inside it.
    var debugFilmOwnAnimations: [String] { film.layer.animationKeys() ?? [] }
    var debugFilmAlpha: CGFloat { film.alpha }
    /// Internal for tests: what the line and the bars are animating.
    var debugLineAnimations: [String] {
        (lineSegments + [rehearsalBar, windowMark]).flatMap { $0.layer.animationKeys() ?? [] }
    }
    /// Internal for tests: whether a gesture of each kind would be allowed to
    /// begin — asked of the very delegate method a finger reaches.
    var debugGesturesThatWouldBegin: [String] {
        let asked: [(name: String, recogniser: UIGestureRecognizer)] = [
            ("pinch", pinch), ("lift", lift), ("handle", contentPan)
        ]
        return asked.filter { gestureRecognizerShouldBegin($0.recogniser) }.map(\.name)
    }
    /// Internal for tests: what a tap on the scroller would do, through the
    /// recogniser's own action.
    func debugTapped(atContentX x: CGFloat) { recognisedTap(reportedAtContentX: x) }
    /// Internal for tests: a recognised tap that LANDED at one place and was
    /// reported at another — the film moved under a resting finger.
    func debugTapped(landedAt landed: CGFloat, reportedAt reported: CGFloat) {
        tapLanding = landed
        recognisedTap(reportedAtContentX: reported)
    }
    /// Internal for tests: a press that landed at one place and is recognised
    /// at another, asked of the very routine the recogniser asks.
    func debugWouldLift(landedAt landed: CGFloat) -> Bool {
        liftLanding = landed
        defer { liftLanding = nil }
        return gestureRecognizerShouldBegin(lift)
    }
    /// Internal for tests: the tap that answers a cap's `+` and the handle pan
    /// share a view, and nothing lets them recognise together — so a drag is
    /// never also a tap.
    var debugTapYieldsToTheHandle: Bool {
        let delegate = self as UIGestureRecognizerDelegate
        return selectTap.view === contentPan.view && selectTap.delegate === self
            && !(delegate.gestureRecognizer?(selectTap, shouldRecognizeSimultaneouslyWith: contentPan) ?? false)
            && !(delegate.gestureRecognizer?(contentPan, shouldRecognizeSimultaneouslyWith: selectTap) ?? false)
    }
    /// Internal for tests: whether the track is put away — every part of it, not
    /// just one, since any part left showing is part of the mess that was
    /// reported.
    /// Internal for tests: whether the ruler is faded at its ends — which it must
    /// be at rest, where it passes behind the play button and the readout, and
    /// must NOT be while a piece is carried, where the fade would hide the first
    /// and last seams.
    var debugRulerIsFaded: Bool { rulerHost.layer.mask != nil }
    /// Internal for tests: the room kept at both ends of the shot list.
    static var debugShotInset: CGFloat { Metrics.shotInset }
    var debugTrackIsPutAway: Bool { partsOfTheTrack.allSatisfy { $0.alpha < 0.01 } }
    var debugTrackIsShowing: Bool { partsOfTheTrack.allSatisfy { $0.alpha > 0.99 } }
    /// ⚠️ **Internal for tests: whether the frame is DRAWN, which is not the same
    /// question as whether a piece is held.** A test that asked only `selected`
    /// could not see a layout that framed something anyway — proved by deliberate
    /// break: drawing the frame around piece 0 whatever was held left every
    /// selection test green.
    var debugSelectionIsDrawn: Bool {
        !topBar.isHidden && !bottomBar.isHidden && !startGrab.isHidden && !endGrab.isHidden
            && (innerCorners.allSatisfy { !$0.isHidden } || (anyFrame == nil && posterFrame == nil))
    }
    /// Internal for tests: which piece is held, and where every piece is drawn.
    var debugSelectedPiece: Int? { selected }
    var debugPieceFrames: [ClosedRange<CGFloat>] {
        MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        ).map { $0.from...max($0.to, $0.from) }
    }
    /// Internal for tests: presses play/pause the way a finger would.
    func debugTapPlayPause() { onPlayPause?() }
    var debugRulerMarks: [String] { ruler.debugMarks }
    /// Internal for tests: how many midpoint dots the ruler is drawing (F9).
    var debugRulerDotCount: Int { ruler.debugDotCount }
    var debugNeedleIsCentred: Bool { abs(needle.frame.midX - bounds.midX) < 0.5 }
    /// Internal for tests: how wide a second of film is drawn right now.
    var debugPointsPerSecond: CGFloat { pointsPerSecond }
    /// Internal for tests: pinches the way two fingers would, through the very
    /// routine the recogniser calls.
    func debugPinch(by scale: CGFloat) {
        beginZoom()
        zoom(to: MediaTimelining.zoomed(pointsPerSecond, by: scale))
        endZoom()
    }
    var debugHasGrip: Bool { grip != nil }

    /// Whether a touch at `x` in CONTENT coordinates would take a handle rather
    /// than scroll the film — the very predicate the delegate asks.
    func debugWouldTakeAHandle(at x: CGFloat) -> Bool { takesAHandle(at: x) }


    /// Internal for tests: where the caps are drawn, which is what the reach must
    /// be measured from.
    var debugHandleCentres: (start: CGFloat, end: CGFloat)? { handleCentres() }

    /// Internal for tests: whether the view the handle pan is attached to can
    /// actually be touched at this point of the film. A perfect predicate on a
    /// view the finger cannot reach is still a dead handle.
    func debugPanReceivesTouches(atContentX x: CGFloat) -> Bool {
        guard let host = contentPan.view else { return false }
        let point = content.convert(CGPoint(x: x, y: Metrics.strip / 2), to: host)
        return host.bounds.contains(point)
    }

    /// ⚠️ **THE WIRING THE PREDICATE ABOVE CANNOT SEE.** A perfect answer from a
    /// recogniser nobody asks is still a track that cannot be scrolled: the pan
    /// must be delegated here, and it must live INSIDE the scroller — on the
    /// track view it would be an outsider to `ChipScrollView`'s arbitration rule,
    /// and the two "you go first" requirements would form a cycle.
    var debugHandlePanIsDelegatedHere: Bool { contentPan.delegate === self }
    var debugHandlePanLivesInsideTheScroller: Bool {
        contentPan.view.map { $0.isDescendant(of: scroller) } ?? false
    }

    func debugTakeHold(at x: CGFloat) { takeHold(at: x) }

    func debugDrag(byPoints points: CGFloat) {
        track(byPoints: points)
        layoutIfNeeded()
    }

    func debugRelease() { finishDrag() }

    /// Scrolls the film the way a finger would.
    ///
    /// ⚠️ **ASSIGNMENT ALONE — CALLING THE DELEGATE TOO FIRES IT TWICE.** A
    /// `contentOffset` assignment invokes `scrollViewDidScroll` synchronously, so
    /// the explicit call this used to make produced a SECOND scrub for the same
    /// movement, at a distance of zero. Everything downstream that reads a
    /// distance — the seek's tolerance, chiefly — then saw a still finger after
    /// every move, and the adaptive-tolerance test failed for a reason that was
    /// entirely the harness's. Found by that test, which is what it is for.
    func debugScroll(toContentOffset x: CGFloat) {
        scroller.contentOffset.x = x
    }

    /// Internal for tests: the daylight between two pieces' drawn film, in
    /// content points — read off the WINDOWS, for each pair of neighbours that
    /// both have one and both round the ends that face each other. A negative
    /// width is an overlap, never daylight.
    var debugSeamGaps: [(from: CGFloat, to: CGFloat)] {
        let open = debugFilmWindows
        return zip(open, open.dropFirst()).compactMap { left, right in
            guard right.piece == left.piece + 1,
                  left.corners.contains(.layerMaxXMinYCorner),
                  right.corners.contains(.layerMinXMinYCorner)
            else { return nil }
            return (left.frame.maxX, right.frame.minX)
        }
    }
    /// Internal for tests: what the pieces that are not as shot are stamped with.
    var debugRateStamps: [String] {
        rateStamps.compactMap { stamp in
            guard !stamp.isHidden else { return nil }
            // The rate alone — a filter's symbol is read by `debugFilterStamps`.
            return stamp.attributedText.map {
                $0.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
            } ?? stamp.text
        }.filter { !$0.isEmpty }
    }
    /// Internal for tests: how many visible stamps DRAW the filter symbol —
    /// read off the attachment's image, not off the piece.
    var debugFilterStamps: Int {
        rateStamps.filter { stamp in
            guard !stamp.isHidden, let text = stamp.attributedText, text.length > 0 else { return false }
            let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
            return attachment?.image?.description.contains("system: \(Self.filterStampGlyph))") == true
        }.count
    }
    /// Internal for tests: where those stamps are, in content points — which is
    /// the half that says whether anyone can read them.
    var debugRateStampFrames: [CGRect] { rateStamps.filter { !$0.isHidden }.map(\.frame) }
    /// Internal for tests: the part of the film the track is showing.
    var debugVisibleContent: ClosedRange<CGFloat> {
        scroller.contentOffset.x...(scroller.contentOffset.x + bounds.width)
    }
    /// Internal for tests: whether the film's placeholder is standing in for it.
    var debugSkeletonIsShowing: Bool { !skeleton.isHidden }
    /// Internal for tests: where that placeholder is, which must be the FILM's
    /// rectangle and not the track's — at rest the leading half of the viewport
    /// holds no film at all.
    var debugSkeletonFrame: CGRect { skeleton.frame }
    /// Internal for tests: the picture of last resort, by identity — so a test
    /// can tell one clip's poster from another's.
    var debugPoster: UIImage? { posterFrame }
    #endif
}
