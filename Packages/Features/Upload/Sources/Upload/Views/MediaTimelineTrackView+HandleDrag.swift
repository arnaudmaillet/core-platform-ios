import DesignSystem
import MediaPlayback
import UIKit

// Dragging a handle: trimming a piece's edges (#2388, out of the track's file).
extension MediaTimelineTrackView {
    // MARK: - Dragging a handle

    /// ⚠️ **THE PAN EXISTS ONLY FOR THE HANDLES, AND SAYS SO AT TOUCH-DOWN.**
    /// Refusing here rather than in `.began` is what keeps an ordinary scroll
    /// free: `scroller.panGestureRecognizer` waits for this one to fail, and a
    /// recogniser that never begins fails at once.
    /// ⚠️ **AN `override`, AND `ChipScrollView`'S NEIGHBOURING RULE IS NOT — THE
    /// TWO LOOK ALIKE AND ARE NOT.** `UIView` declares
    /// `gestureRecognizerShouldBegin(_:)` itself, so this one takes the keyword;
    /// `gestureRecognizer(_:shouldBeRequiredToFailBy:)` is delegate-only and
    /// refuses it. The compiler says so plainly in both directions, which is the
    /// only reason this is cheap to get wrong rather than expensive.
    override func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        // ⚠️ **COLLAPSED, THE TRACK TAKES NO GESTURE AT ALL.** There is no film
        // to zoom, no piece to lift and no handle to drag — the line is a
        // reading of where the loop is.
        if isCompact, recogniser === pinch || recogniser === lift || recogniser === contentPan {
            return false
        }
        guard recogniser !== pinch else { return duration > 0 }
        guard recogniser !== lift else {
            return wouldLift(atContentX: liftLanding ?? lift.location(in: content).x)
        }
        guard recogniser === contentPan else { return true }
        return takesAHandle(at: touchDownX(of: contentPan))
    }

    /// Where the finger LANDED, not where it has got to.
    ///
    /// ⚠️ **A RECOGNISER IS NOT ASKED THE INSTANT THE FINGER TOUCHES DOWN.** It
    /// is asked when it first tries to leave `.possible`, which is after its own
    /// slop — and if several touch samples arrive in one turn of the run loop,
    /// that can be tens of points later. Measured in the simulator with an
    /// injected drag: the finger landed on a cap at content x = 5 and
    /// `shouldBegin` was asked at x = 53, which is outside the 44pt reach, so the
    /// handle refused a drag that started exactly on it and the film scrolled
    /// instead. A fast flick off a cap does the same thing to a real finger.
    ///
    /// The translation is the distance travelled since touch-down, so the
    /// difference is where it began.
    private func touchDownX(of pan: UIPanGestureRecognizer) -> CGFloat {
        Self.touchDown(
            location: pan.location(in: content).x, travelled: pan.translation(in: content).x
        )
    }

    /// Whether a press here has anything to carry.
    ///
    /// ⚠️ **A PRESS THAT CANNOT CARRY ANYTHING MUST NOT TAKE THE TOUCH.** A long
    /// press that recognises prevents the scroller's pan from ever beginning for
    /// that finger — so on a clip that has not been cut, where there is nothing
    /// to re-order, a third of a second of stillness froze the film for the rest
    /// of the gesture and the author had to lift and start again. This is the
    /// Bool `beginInteractiveMovementForItem(at:)` hands back, and the reason
    /// every account of that API says to gate the whole carry on it.
    func wouldLift(atContentX x: CGFloat) -> Bool {
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        // ⚠️ **A PRESS ON A `+` LIFTS NOTHING — A DISC'S OR A CAP'S.** A
        // recognised long press takes the finger for the whole gesture, and the
        // `+` would never hear its tap: *"quand on appuie sur le + de la pince ça
        // montre les transitions"*, however long the press. Within a cap's
        // target a press is a tap, and a press that travels is the handle's.
        return placed.count > 1 && shownSeam(atContentX: x) == nil
            && !heldCapMarks().contains { $0.reach.contains(x) }
            && pieceAimedAt(x, in: placed) != nil
    }

    /// Which piece a gesture at `x` is aimed at.
    ///
    /// ⚠️ **THE CAPS BELONG TO THE PIECE THAT IS HELD, AND THEY ARE DRAWN ON THE
    /// NEIGHBOUR'S FILM.** A cap stands twelve points outside its own piece, so
    /// at an interior cut a finger on the held piece's closing cap is, by
    /// position alone, inside the NEXT piece — and a press there lifted that next
    /// piece into a carry, taking the selection with it. A control belongs to the
    /// thing it controls: inside the held piece's caps the answer is the held
    /// piece, and everywhere else it is whichever piece the film belongs to.
    private func pieceAimedAt(_ x: CGFloat, in placed: [MediaTimelining.Placement]) -> Int? {
        if let held = selected, let caps = heldCaps(), caps.claims(x) {
            return held
        }
        return MediaTimelining.piece(atPoints: x, in: placed)
    }

    /// ⚠️ **NAMED AND STATIC SO A TEST CAN ASK THE ARITHMETIC** — what it cannot
    /// ask is that the delegate uses it, because a recogniser's location cannot
    /// be set from a test. That half was found in the simulator and is checked
    /// there.
    static func touchDown(location: CGFloat, travelled: CGFloat) -> CGFloat {
        location - travelled
    }

    /// ⚠️ **NAMED, SO A TEST CAN ASK THE DECISION RATHER THAN A COPY OF IT.** A
    /// recogniser's location cannot be set from a test, so the delegate method
    /// above is unreachable there; a test asserting `edge(at:) != nil` instead
    /// would be asserting its own restatement of this line, and the gate could be
    /// deleted with the test still green. One expression, two doors.
    func takesAHandle(at x: CGFloat) -> Bool { edge(at: x) != nil }

    func edge(at x: CGFloat) -> MediaTimelining.Edge? {
        guard let centres = handleCentres() else { return nil }
        return MediaTimelining.edge(at: x, startX: centres.start, endX: centres.end)
    }

    /// Where the two caps are DRAWN, in content points — which is not where the
    /// cut is.
    ///
    /// ⚠️ **THE REACH FOLLOWS THE CONTROL, AND FOR ONE BUILD IT DID NOT.** The
    /// caps moved outside the kept film so the first and last frames stopped
    /// being covered; the hit test kept measuring from the CUT, so the finger's
    /// forty-four points sat half a cap away from the thing the eye aims at —
    /// generous enough that the handles still worked, and harder to hit on one
    /// side than the other.
    ///
    /// ⚠️ **AND THE LEADING CAP WAS BEING PLACED AT THE DEFAULT SCALE.** This
    /// read `x(atSourceSeconds: first.start)` with no `pointsPerSecond` while the
    /// trailing one passed the instance's — so the two handles agreed only until
    /// the first pinch, after which the start handle's hit area sat somewhere the
    /// start handle was not. Found by the compiler, when both were finally made
    /// to come from one place.
    ///
    /// ⚠️ **AND THERE ARE NONE UNTIL A PIECE IS HELD.** With nothing selected the
    /// track has no handles at all, so every touch on it is a scroll — which is
    /// what makes "tap to select" possible in the first place: a tap that had to
    /// fight a handle for its own touch would select the wrong thing half the
    /// time.
    func handleCentres() -> (start: CGFloat, end: CGFloat)? {
        heldCaps()?.centres
    }

    /// Carries a piece to another place in the composition.
    ///
    /// ⚠️ **THE LIST RE-FLOWS AS THE PIECES ARE CROSSED; THE CHIP IN HAND IS THE
    /// ONE THAT RISES.** Nothing is dragged across the film itself — the strip is
    /// one row of tiles laid across the whole track, and a carried copy of it
    /// would double the decoding for the length of a gesture. What the author
    /// holds is a chip of the shot list, standing over a track that has stood
    /// back; the others make room around it as it passes, which is how a home
    /// screen re-arranges icons.
    @objc func carried(_ press: UILongPressGestureRecognizer) {
        // ⚠️ **TWO SPACES, AND ONE OF THEM IS NOT THE FILM'S.** The press LANDS on
        // the track, so which piece it took is a question about content
        // coordinates; from the instant it is carrying something the thing under
        // the finger is the SHOT LIST, which is laid in the view's own bounds and
        // does not scroll. Reading the whole gesture in one space would put the
        // drop wherever the film happened to be scrolled to.
        switch press.state {
        case .began:
            lift(
                atContentX: liftLanding ?? press.location(in: content).x,
                underTrackX: press.location(in: self).x
            )
        case .changed: carry(toTrackX: press.location(in: self).x)
        case .ended, .cancelled, .failed:
            liftLanding = nil
            drop()
        default: break
        }
    }

    // ⚠️ **THE THREE ROUTINES THE PRESS USES, NAMED — SO THE TESTS GO THROUGH
    // THEM RATHER THAN ALONGSIDE.** A long press's state cannot be set from a
    // test, and `debugPinch` records what re-entering by a copy of the logic
    // costs: it skipped `beginZoom` entirely and the test written to prove that a
    // zoom retires its frames passed on a path that does not.
    func lift(atContentX x: CGFloat, underTrackX finger: CGFloat? = nil) {
        let placed = MediaTimelining.placements(
            timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
        )
        guard wouldLift(atContentX: x), let index = pieceAimedAt(x, in: placed)
        else { return }
        isPuttingDown = false
        carryX = nil
        reordering = index
        liftedFrom = index
        select(index)
        stopTheFilmMovingUnderTheFinger()
        raiseTheShots(placed, stripY: stripY)
        let list = standing
        shotList.contentOffset.x = MediaTimelining.shotListOffset(
            centring: list.first { $0.index == index },
            underTrackX: finger ?? x - scroller.contentOffset.x,
            listWidth: listWidth(of: list), trackWidth: bounds.width
        )
        // The piece lifts (`grab`, #1887); the crossings that follow tick,
        // warmed now so the engine is not woken under them.
        Haptics.play(.grab)
        Haptics.prepare(.tick)
        onScrubbing?(true)
        // ⚠️ **THE TRACK FADES OUT AS THE LIST FADES AND GROWS IN, EACH CHIP FROM
        // ITS OWN CENTRE.**
        //
        // ⚠️ **A SPRING, AND NO `.beginFromCurrentState` — THE CHIPS WERE STAGED IN
        // THIS SAME TURN.** That option reads the starting value from the
        // PRESENTATION layer, which a view added a moment ago does not have yet;
        // the repository has measured it animating end to end, invisibly, in
        // exactly this situation. A spring animation is immune, and without the
        // option the start is the value the chip was just given.
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.34, delay: 0,
            usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) { [self] in
            layoutIfNeeded()
            for shot in shots { shot.alpha = 1 }
            standTheTrackAside(true)
        }
    }

    /// ⚠️ **APPLE'S OWN RECIPE, AND IT IS NOT `isScrollEnabled`.** WWDC 2014's
    /// "Advanced Scrollviews and Touch Handling Techniques" answers exactly this
    /// question — picking something up inside a scroll view — with: *"at the
    /// moment when I'm grabbing the dot, I just need to disable and then
    /// re-enable the ScrollView's pan gesture"*. Disabling makes the pan "stop
    /// looking at any touches it was currently considering, and reset itself", so
    /// the finger that is now carrying a piece is dropped by the scroller even if
    /// it had already begun to move the film; turning it straight back on leaves
    /// that touch dropped while new ones still work. `isScrollEnabled = false` is
    /// the blunt version — documented as refusing touches altogether and silent
    /// about the ones already in flight — and it is kept only for what comes
    /// AFTER: while the shot list is up the whole composition is on screen, so
    /// there is nothing left to scroll to.
    private func stopTheFilmMovingUnderTheFinger() {
        scroller.panGestureRecognizer.isEnabled = false
        scroller.panGestureRecognizer.isEnabled = true
        scroller.isScrollEnabled = false
    }

    func carry(toTrackX x: CGFloat) {
        guard reordering != nil else { return }
        carryX = x
        keepTheListScrolling()
        moveTheCarry(toTrackX: x)
    }

    /// Puts the piece in hand in the slot the finger is over now.
    private func moveTheCarry(toTrackX x: CGFloat) {
        guard let from = reordering else { return }
        // ⚠️ **THE FINGER IS ON THE TRACK, AND THE LIST MAY HAVE SCROLLED UNDER
        // IT.** Read without the offset, a finger resting at the edge while the
        // list slides would keep asking for the same slot, and the piece would
        // stay behind while the list it is meant to travel along moved on.
        let to = MediaTimelining.dropIndex(
            forPoints: x + shotList.contentOffset.x, in: standing, moving: from
        )
        guard to != from else { return }
        timeline = MediaTimelining.reordered(
            timeline, move: from, to: to, withinSource: duration
        )
        // ⚠️ **THE CHIP TRAVELS WITH ITS PIECE.** The list is one chip per piece
        // in play order, so the same move is made in both or a chip showing one
        // piece's film ends up standing for another's.
        // ⚠️ **AND THE INDEX IS CHECKED, THOUGH A LIFT ALWAYS RAISES THE LIST.**
        // `remove(at:)` past the end is a crash, and a crash in the middle of a
        // gesture is the one failure the author cannot recover from — found by
        // breaking the lift on purpose, which took the whole suite down with it
        // and hid what the break was supposed to prove.
        if shots.indices.contains(from) {
            let carried = shots.remove(at: from)
            shots.insert(carried, at: min(to, shots.count))
            shotList.bringSubviewToFront(carried)
        }
        reordering = to
        // The frame stays around the piece being carried; the screen hears about
        // the new order once, on release, through `onChange`.
        selected = to
        Haptics.play(.tick)
        // ⚠️ **THE RE-FLOW IS THE FEEDBACK, SO IT HAS TO BE SEEN HAPPENING.** An
        // instant swap reads as the list glitching rather than as two pieces
        // changing places. A fifth of a second is enough to follow and too short
        // to be in the way of the next crossing.
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.18, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.layoutIfNeeded()
        }
    }

    func drop() {
        guard let landedAt = reordering else { return }
        // Landed in a new place: `drop`; back where it was: nothing (#1887).
        if landedAt != liftedFrom { Haptics.play(.drop) }
        liftedFrom = nil
        reordering = nil
        carryX = nil
        stopTheListScrolling()
        // ⚠️ **THE LIST FADES OUT WHERE IT STANDS WHILE THE TRACK FADES BACK IN —
        // THE SAME GESTURE AS ITS ARRIVAL, BACKWARDS.** Until the fade lands,
        // `isPuttingDown` is what stops the layout removing the chips mid-flight.
        isPuttingDown = true
        scroller.isScrollEnabled = true
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.22, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [self] in
            layoutIfNeeded()
            for shot in shots {
                shot.alpha = 0
                shot.transform = CGAffineTransform(
                    scaleX: Metrics.arriving, y: Metrics.arriving
                )
            }
            standTheTrackAside(false)
        } completion: { [weak self] _ in
            guard let self, reordering == nil else { return }
            isPuttingDown = false
            putTheShotsAway()
        }
        // ⚠️ **THE NEEDLE KEEPS ITS PLACE, AND THE PREVIEW IS TOLD WHAT IS UNDER
        // IT NOW.** The screen knows which piece is playing by its INDEX, and a
        // carry has just renumbered them: left alone, "piece 0 at two seconds"
        // named a different piece after the drop, and the follow scrolled the
        // whole track to wherever that one happened to sit — measured on the
        // device as the needle leaping from 0:02 to 0:00 the instant the finger
        // came up. A new order does not change how long the result runs, so the
        // track has not moved; the moment under the needle, in the new order, is
        // what the player has to be sent to.
        // ⚠️ **AND A PIECE PUT DOWN AT THE END LOSES ITS TRANSITION** — there is
        // no cut after the film. Cleared here, once, rather than at every
        // crossing: a carry that comes back where it started must be the
        // timeline that was lifted.
        timeline = MediaTimelining.settled(timeline)
        setNeedsLayout()
        if let moment = momentUnderNeedle { onScrub?(moment) }
        onScrubbing?(false)
        onChange?(timeline)
    }

    /// The shot list moved — by itself at an edge, or under a second finger.
    ///
    /// ⚠️ **IT MOVED UNDER A FINGER THAT DID NOT**, so what that finger is over
    /// has changed: the carry is asked again, and the ruler that counts the list
    /// goes with it.
    func listScrolled() {
        guard reordering != nil else { return }
        ruler.frame.origin.x = -shotList.contentOffset.x
        if let carryX { moveTheCarry(toTrackX: carryX) }
    }

    /// How fast the list should be scrolling by itself right now — zero when the
    /// finger is away from both ends, or when there is no further to go.
    private var edgeScrollSpeed: CGFloat {
        guard reordering != nil, let carryX else { return 0 }
        let speed = MediaTimelining.edgeScrollSpeed(
            atTrackX: carryX, trackWidth: bounds.width,
            zone: Metrics.edgeZone, fastest: Metrics.edgeSpeed
        )
        let furthest = max(shotList.contentSize.width - shotList.bounds.width, 0)
        if speed < 0, shotList.contentOffset.x <= 0 { return 0 }
        if speed > 0, shotList.contentOffset.x >= furthest { return 0 }
        return speed
    }

    /// Starts the list scrolling by itself when the finger is at an end, and
    /// stops it when it is not.
    ///
    /// ⚠️ **A DISPLAY LINK, BECAUSE A FINGER HELD STILL SENDS NOTHING.** The long
    /// press reports movement; a thumb pressed against the bezel does not move,
    /// and the list must go on sliding under it all the same.
    private func keepTheListScrolling() {
        guard edgeScrollSpeed != 0 else { return stopTheListScrolling() }
        guard edgeScroll.link == nil else { return }
        let link = CADisplayLink(target: edgeScroll, selector: #selector(EdgeScrollProxy.tick(_:)))
        edgeScroll.owner = self
        edgeScroll.link = link
        edgeScrollBeat = 0
        link.add(to: .main, forMode: .common)
    }

    func stopTheListScrolling() {
        edgeScroll.link?.invalidate()
        edgeScroll.link = nil
    }

    func edgeScrollTicked(_ link: CADisplayLink) {
        let elapsed = edgeScrollBeat == 0 ? link.duration : link.timestamp - edgeScrollBeat
        edgeScrollBeat = link.timestamp
        // A beat that arrives late must not throw the list a screen.
        scrollTheList(forSeconds: min(max(elapsed, 0), 1.0 / 20))
    }

    /// One step of the list scrolling by itself. The move is heard back through
    /// `listScrolled`, which is what carries the piece along.
    func scrollTheList(forSeconds elapsed: Double) {
        let speed = edgeScrollSpeed
        guard speed != 0 else { return stopTheListScrolling() }
        let furthest = max(shotList.contentSize.width - shotList.bounds.width, 0)
        shotList.contentOffset.x = min(
            max(shotList.contentOffset.x + speed * CGFloat(elapsed), 0), furthest
        )
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopTheListScrolling() }
    }

    @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginZoom()
        case .changed:
            let next = MediaTimelining.zoomed(pointsPerSecond, by: gesture.scale)
            gesture.scale = 1
            zoom(to: next)
        case .ended, .cancelled, .failed:
            endZoom()
        default:
            break
        }
    }

    // ⚠️ **THE THREE ROUTINES A PINCH USES, NAMED — SO THE DEBUG HOOK GOES
    // THROUGH THEM RATHER THAN ALONGSIDE.** `debugPinch` was a shortcut that set
    // the scale and moved the film, and skipped `beginZoom` entirely: it never
    // retired the frames in flight, so the test written to prove that a zoom
    // retires them passed on a path that does not. The crop surface states the
    // same rule — a test re-entering by a copy of the logic is a test of the copy.
    func beginZoom() {
        zoomAnchorSeconds = playedSecondsUnderNeedle
        isZooming = true
            // ⚠️ **THE PICTURES ARE DROPPED ONCE, AT THE START.** A tile's index
            // means a different moment at every scale, so what is cached is
            // wrong the instant the scale moves. Dropping them per sample would
            // re-request sixty times a second; dropping them once and asking
            // again on release costs one refill, and in between every tile shows
            // the nearest frame it has, which is charter F14 doing its job.
            // Through `forgetFrames`, so the generation is bumped: a tile index
            // means a different moment at every scale, and a batch in flight has
            // already captured its indices.
        forgetFrames()
        onScrubbing?(true)
    }

    func zoom(to scale: CGFloat) {
        guard abs(scale - pointsPerSecond) > 0.01 else { return }
        pointsPerSecond = scale
        setNeedsLayout()
        layoutIfNeeded()
        keepTheNeedleOnTheAnchor()
    }

    func endZoom() {
        isZooming = false
        onScrubbing?(false)
        setNeedsLayout()
    }

    /// Holds the moment the pinch began on under the needle, so the film grows
    /// around what the author is looking at rather than around its own start.
    private func keepTheNeedleOnTheAnchor() {
        isFollowingPlayback = true
        scroller.contentOffset.x = offset(forPlayedSeconds: zoomAnchorSeconds)
        isFollowingPlayback = false
    }

    @objc func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // ⚠️ THE SAME QUESTION THE DELEGATE ANSWERED, ASKED THE SAME WAY —
            // see `touchDownX`. Reading the current location here would take a
            // different handle from the one the gesture was allowed to begin for.
            takeHold(at: touchDownX(of: pan))
        case .changed:
            // ⚠️ **ZEROED EVERY SAMPLE, SO THE ARITHMETIC IS INCREMENTAL.** It is
            // what lets a handle dragged past the end of the clip come straight
            // back rather than first undoing its overshoot — the crop surface and
            // the straighten dial both do this.
            let moved = pan.translation(in: content).x
            pan.setTranslation(.zero, in: content)
            track(byPoints: moved)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    // ⚠️ **THE THREE ROUTINES A FINGER USES, NAMED — SO THE DEBUG HOOKS CAN GO
    // THROUGH THEM RATHER THAN ALONGSIDE.** The crop surface states the rule: a
    // test re-entering by a copy of the logic is a test of the copy.
    func takeHold(at x: CGFloat) {
        stopEasing()
        grip = edge(at: x)
        exactDragOffset = nil
        guard grip != nil else { return }
        onScrubbing?(true)
    }

    /// ⚠️ **THE DRAG IS WORTH DIFFERENT AMOUNTS OF FILM IN DIFFERENT PIECES.**
    /// The track is drawn in played seconds, so a piece at 2× is half as wide as
    /// the film it covers and one point of finger is worth two frames rather than
    /// one. Converting a drag straight to source seconds — which is what the
    /// single-clock version did — moves a fast piece's edge twice as far as the
    /// finger went.
    ///
    /// ⚠️ **AND WHAT THE FINGER MOVES IS THE CAP, NOT A LENGTH OF FILM.** Where
    /// the held piece is the shorter side of a transition, trimming it shortens
    /// the overlap too (`MediaTimelining.Laid`): its film starts elsewhere and
    /// the cut before or after it moves with it. Converting the travel straight
    /// into film left the cap at half the finger's speed and slid the cap that
    /// should stand still — found by review. So the edge moves until the drawn
    /// width has changed by the finger's travel (`moved(changingDrawnWidthBy:)`),
    /// and the track scrolls by however far the OTHER cap moved on the clock.
    func track(byPoints points: CGFloat) {
        guard let grip, let index = selected else { return }
        let before = MediaTimelining.laid(timeline, withinSource: duration)
        guard before.indices.contains(index) else { return }
        timeline = MediaTimelining.moved(
            timeline, piece: index, edge: grip,
            // The SIGNED converter. `playedSeconds(atX:)` floors at zero and
            // would turn every leftward sample into no movement at all. An end
            // dragged right widens the piece; a start dragged right narrows it.
            changingDrawnWidthBy: MediaTimelining.playedSeconds(
                ofPoints: grip == .end ? points : -points, pointsPerSecond: pointsPerSecond
            ),
            withinSource: duration
        )
        let after = MediaTimelining.laid(timeline, withinSource: duration)
        guard after.indices.contains(index) else { return }
        // ⚠️ **THE RIGHT PINCE HOLDS ITS START CAP STILL.** Where the piece
        // limits the overlap before it, its drawn start moves with the trim;
        // the track follows it, so the cap and the cut before it stand where
        // the eye left them.
        if grip == .end {
            let shift = CGFloat(after[index].drawnFrom - before[index].drawnFrom) * pointsPerSecond
            if abs(shift) > 0.01 {
                isFollowingPlayback = true
                scroller.contentOffset.x = exactOffset(movedBy: shift)
                isFollowingPlayback = false
            }
        }
        // ⚠️ **THE LEFT PINCE IS THE MIRROR OF THE RIGHT ONE, AND THE TRACK IS
        // WHAT MOVES TO MAKE IT SO.** Asked for in those words: *"si on tire la
        // pince gauche vers la gauche… dévoiler la partie avant et pousser la
        // section précédente — en gros ce qu'on a fait pour la pince de droite, il
        // faut faire la même chose pour la pince de gauche."* The right pince
        // holds everything BEFORE it still and pushes what follows; the left one
        // must hold everything AFTER it still and push what precedes.
        //
        // A piece begins where the pieces before it end, and that number does not
        // change when its own start is dragged — so in the composition's own
        // coordinates a head that opens pushes ITSELF and everything after it to
        // the right, which is the opposite of what the eye is promised. Scrolling
        // the track by exactly how far its closing edge moved on the clock
        // cancels that: the piece's closing edge and every section after it
        // stand perfectly still, the sections BEFORE it slide aside, and the cap
        // follows the finger. Measured on the device by pixel correlation, both
        // directions. (By the change in the drawn END, not the width: where the
        // piece limits the overlap before it, its start moves on the clock too.)
        //
        // ⚠️ **AND THE LEADING INSET IS WHAT LETS THE FIRST PIECE DO IT.** A
        // scroll view will not go past its own leading inset, and for the first
        // piece it is already sitting on it; the inset grows for the length of
        // the gesture and settles back on release.
        if grip == .start {
            let lost = -CGFloat(after[index].drawnTo - before[index].drawnTo) * pointsPerSecond
            if abs(lost) > 0.01 {
                leadingSlack = max(leadingSlack + lost, 0)
                // Suppressed, because this is not the author scrubbing: the drag
                // reports the edge's own moment below, and a second announcement
                // carrying the needle's would seek the preview away from it.
                isFollowingPlayback = true
                scroller.contentInset.left =
                    MediaTimelining.centringInset(forTrackWidth: bounds.width) + leadingSlack
                scroller.contentOffset.x = exactOffset(movedBy: -lost)
                isFollowingPlayback = false
            }
        }
        setNeedsLayout()
        // The canvas shows the frame the handle is standing on, which is how a
        // trim is aimed. Continuous, and stores nothing.
        let moved = MediaTimelining.resolved(timeline, withinSource: duration)
        guard moved.indices.contains(index) else { return }
        switch grip {
        case .start:
            onScrub?(MediaTimelining.Moment(piece: index, sourceSeconds: moved[index].start))
        case .end:
            onScrub?(MediaTimelining.Moment(piece: index, sourceSeconds: moved[index].end))
        }
    }

    /// The drag's unrounded offset moved by `delta` (`exactDragOffset`). One
    /// that no longer matches the scroller — something else scrolled it, or
    /// the inset clamped it — starts again from where the scroller is.
    private func exactOffset(movedBy delta: CGFloat) -> CGFloat {
        let pixel = 1 / max(traitCollection.displayScale, 1)
        var exact = exactDragOffset ?? scroller.contentOffset.x
        if abs(exact - scroller.contentOffset.x) > pixel { exact = scroller.contentOffset.x }
        exact += delta
        exactDragOffset = exact
        return exact
    }

    func finishDrag() {
        let hadGrip = grip != nil
        grip = nil
        exactDragOffset = nil
        // The slack was the gesture's; the track settles back onto the composition.
        if leadingSlack != 0 {
            leadingSlack = 0
            setNeedsLayout()
        }
        guard hadGrip else { return }
        // ⚠️ **THE PREVIEW COMES BACK TO THE NEEDLE; THE TRACK DOES NOT GO TO THE
        // PREVIEW.** While a handle is held the canvas shows the frame the EDGE is
        // standing on — that is how a trim is aimed — so at the end of the gesture
        // the player is parked on that frame. Left there, the next beat of
        // playback had the track FOLLOW it: the whole film slid under the needle
        // the moment the finger came up, which reads as every section moving at
        // once and is the thing the author has asked three times to be rid of.
        // Sending the needle's own moment back puts the canvas where the playhead
        // is and leaves the film exactly where the eye left it.
        if let moment = momentUnderNeedle { onScrub?(moment) }
        onScrubbing?(false)
        onChange?(timeline)
    }
}
