import DesignSystem
import MediaPlayback
import UIKit

// Scrolling is seeking (#2388, out of the track's file).
extension MediaTimelineTrackView {
    // MARK: - Scrolling is seeking

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // ⚠️ **TWO SCROLLERS, ONE DELEGATE.** The shot list's movements are not
        // the film's, and must not be read as a scrub.
        guard scrollView === scroller else { return listScrolled() }
        // ⚠️ EVERY SCROLL, INCLUDING THE FOLLOWER'S. The window of film worth
        // decoding moves with the offset whoever moved it — a clip playing past
        // the end of what has been decoded needs new tiles just as much as a
        // finger does.
        refreshTiles()
        refreshReadout()
        // ⚠️ **THE RULER IS MOVED BY HAND, BECAUSE IT NO LONGER SCROLLS.** It
        // hangs in a host outside the scroll view so that a gradient mask can be
        // framed in coordinates that stand still — see `rulerHost`. The price is
        // this one line, and it is cheaper than the mask sliding off the viewport
        // on the first drag, which is what happened when it was inside.
        // While a piece is carried the ruler counts the list, which does not
        // scroll.
        if reordering == nil { ruler.frame.origin.x = -scroller.contentOffset.x }
        layOutTheSkeleton(
            filmWidth: MediaTimelining.contentWidth(
                of: timeline, withinSource: duration, pointsPerSecond: pointsPerSecond
            ),
            stripY: stripY
        )
        // The stamps are clamped into the viewport, so they move with it.
        if !rateStamps.isEmpty {
            layOutTheRateStamps(drawnSpans, stripY: stripY)
        }
        if !seamMarks.isEmpty {
            layOutTheSeams(reckoning: false)
        }
        if isCompact { layOutTheLine() }
        // ⚠️ **COLLAPSED, THE FILM IS NEVER SCRUBBED.** Only the follower moves
        // it — the preview is looping a stretch the author did not aim.
        guard !isFollowingPlayback, !isCompact, hasOpened, let moment = momentUnderNeedle else { return }
        onScrub?(moment)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // ⚠️ **A FINGER OUTRANKS AN EASE.** `allowUserInteraction` lets a drag
        // start mid-animation, but the animation would go on driving the offset
        // underneath it — the film would fight the finger. Ending it here leaves
        // the offset wherever the ease had got to, which is where the film
        // visibly is.
        stopEasing()
        onScrubbing?(true)
    }

    func stopEasing() {
        guard isEasing else { return }
        // ⚠️ **THE MODEL VALUE IS ALREADY AT THE TARGET, SO REMOVING THE
        // ANIMATION SNAPS THERE.** `UIView.animate { contentOffset = target }`
        // sets the model at once and animates only the presentation;
        // `removeAllAnimations` drops the presentation and the film jumps the
        // rest of the way — the opposite of leaving it where it visibly is, which
        // is what this used to claim. Reading the presentation layer first and
        // assigning THAT is what makes the finger pick the film up where it sees
        // it. `uiview-animate-from-value-trap` is the same lesson about `alpha`.
        let visible = scroller.layer.presentation()?.bounds.origin.x
        if let animator = followAnimator {
            followAnimator = nil
            animator.stopAnimation(true)
        }
        scroller.layer.removeAllAnimations()
        if let visible { scroller.contentOffset.x = visible }
        isEasing = false
        isFollowingPlayback = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // ⚠️ THE FLICK IS STILL THE AUTHOR'S GESTURE. Saying the scrub ended here
        // would let playback resume while the film was still sliding, and every
        // remaining deceleration sample would seek away from it.
        guard !decelerate else { return }
        onScrubbing?(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onScrubbing?(false)
    }

    /// The left half of the readout changes on every scroll; the right half only
    /// when a handle moves. Both are cheap, and one label is one assignment.
    /// ⚠️ **BOTH HALVES IN PLAYED SECONDS — CHARTER F10, AND THE SOURCE CLOCK
    /// WAS ON THE LEFT FOR ONE BUILD.** "Where the playhead is" and "how long the
    /// result will run" are one question asked twice, and the answer has to be in
    /// the units a viewer will experience. With a rate on the piece the two
    /// clocks part company: measured on the device, a seven-second clip at 2×
    /// read "0:04 / 0:04" with the needle half way along it.
    func refreshReadout() {
        keptLabel.text = MediaTimelining.stamp(playedSecondsUnderNeedle)
            + " / "
            + MediaTimelining.stamp(
                MediaTimelining.playedSeconds(of: timeline, withinSource: duration)
            )
    }

    /// Clear under the play button, solid across the middle, clear again under
    /// the readout.
    ///
    /// ⚠️ **THE STOPS ARE COMPUTED, NOT GUESSED — AND THE RESTING PLACE IS PAST
    /// THE RAMP.** `MediaCropToolsView` states the same rule for its row of
    /// shapes: a label that comes to rest inside the ramp sits permanently half
    /// dissolved, which reads as a rendering fault rather than as a fade.
    ///
    /// ⚠️ **AND THE FRAME IS SET WITH ACTIONS OFF.** A layer that is not a view's
    /// backing layer animates its own `frame` implicitly over a quarter second,
    /// so the mask would lag a rotation of the device behind what it masks.
    func layOutTheRulerFade() {
        let width = rulerHost.bounds.width
        guard width > 0 else { return }
        let afterPlay = playButton.frame.maxX
        let solidFrom = afterPlay + Metrics.fade
        let clearFrom = keptLabel.frame.minX
        let solidUntil = max(clearFrom - Metrics.fade, solidFrom)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rulerFade.frame = rulerHost.bounds
        rulerFade.locations = [
            0,
            NSNumber(value: Double(afterPlay / width)),
            NSNumber(value: Double(solidFrom / width)),
            NSNumber(value: Double(solidUntil / width)),
            NSNumber(value: Double(clearFrom / width)),
            1
        ]
        CATransaction.commit()
    }

    /// The rate a piece carries, kept where it can be read.
    ///
    /// ⚠️ **CLAMPED INTO THE VIEWPORT, NOT PINNED TO THE PIECE'S START.** A stamp
    /// nailed to the leading edge of its piece is off screen for every piece
    /// longer than a screenful — measured on the device: a seven-second clip at
    /// the resting scale is 420pt of film against a 390pt track, and the stamp
    /// for the only piece there is had already scrolled away by the time the
    /// author chose the rate. It slides along the piece instead, the way the
    /// fixed readout does, and stops at both of its ends so it never speaks for a
    /// piece it is not over.
    ///
    /// ⚠️ **ON ITS OWN FILM AND UNDER THE FRAME.** Clamped to where the piece's
    /// film is DRAWN, so it never sits in the daylight; past the held piece's
    /// closing cap when that piece is the one before; and inserted under the
    /// selection's ink, which is always the thing on top.
    func layOutTheRateStamps(_ drawn: [MediaTimelining.Span], stripY: CGFloat) {
        // ⚠️ **A FILTERED PIECE IS STAMPED TOO** — the filter's symbol before its
        // rate, if it has one: nothing else on the film says it wears a look.
        let stamped = drawn.filter {
            abs($0.placement.piece.speed - 1) > 0.001 || $0.placement.piece.filter != nil
        }
        while rateStamps.count > stamped.count {
            rateStamps.removeLast().removeFromSuperview()
            rateStampWords.removeLast()
        }
        while rateStamps.count < stamped.count {
            let stamp = UILabel()
            stamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            stamp.textColor = .white
            stamp.isUserInteractionEnabled = false
            stamp.layer.shadowColor = UIColor.black.cgColor
            stamp.layer.shadowOpacity = 0.4
            stamp.layer.shadowRadius = 2
            stamp.layer.shadowOffset = .zero
            content.insertSubview(stamp, belowSubview: topBar)
            rateStamps.append(stamp)
            rateStampWords.append("")
        }
        let caps = heldCaps()
        for (index, (stamp, span)) in zip(rateStamps, stamped).enumerated() {
            let piece = span.placement.piece
            let rate = abs(piece.speed - 1) > 0.001 ? MediaTimelining.rateLabel(piece.speed) : nil
            // ⚠️ SET ONLY WHEN THE WORDS CHANGE (charter T8): this runs on every
            // scroll, and an attributed string is an allocation.
            let words = (piece.filter == nil ? "" : "filter|") + (rate ?? "")
            if rateStampWords[index] != words {
                rateStampWords[index] = words
                if piece.filter != nil {
                    stamp.attributedText = Self.filterStamp(rate: rate)
                } else {
                    stamp.attributedText = nil
                    stamp.text = rate
                }
                stamp.sizeToFit()
            }
            var from = span.from
            var to = span.to
            if let caps, selected == span.index - 1 {
                from = max(from, caps.end.upperBound)
            }
            if let caps, selected == span.index + 1 {
                to = min(to, caps.start.lowerBound)
            }
            // Pinned to the piece's leading edge and never wider than the piece:
            // a stamp that overran its own segment would sit on its neighbour and
            // say the wrong thing about it.
            let width = min(stamp.bounds.width, max(to - from - Metrics.stampInset * 2, 0))
            let leading = from + Metrics.stampInset
            let trailing = max(to - width - Metrics.stampInset, leading)
            let visible = scroller.contentOffset.x + Metrics.stampInset
            stamp.frame = CGRect(
                x: min(max(visible, leading), trailing),
                y: stripY + Metrics.strip - stamp.bounds.height - Metrics.stampInset,
                width: width, height: stamp.bounds.height
            )
            stamp.isHidden = width < 8
        }
    }

    /// The `+` on every cut in view.
    ///
    /// ⚠️ **WORKED OUT ON A LAYOUT, ONLY PLACED ON A SCROLL — CHARTER T8.** Which
    /// cuts carry a mark depends on the arrangement, the scale and the held
    /// piece, and none of them changes while the film merely moves; a scroll
    /// only decides which of those marks are near enough the screen to exist,
    /// and a beat that changes nothing allocates nothing.
    ///
    /// ⚠️ **NONE WHILE A PIECE IS CARRIED.** The track is put away for the
    /// length of a carry, and a cut there is about to move anyway.
    func layOutTheSeams(reckoning: Bool) {
        if reckoning {
            let wanted: [MediaTimelining.SeamMark]
            if onSeam == nil || reordering != nil || duration <= 0 {
                wanted = []
            } else {
                let caps = heldCaps()
                wanted = MediaTimelining.seamMarks(
                    laidPlacements, minimumSpacing: Metrics.seamSpacing,
                    hiding: caps.map { $0.start.lowerBound...$0.end.upperBound },
                    disc: SeamButton.discSize, widest: SeamButton.hitSize
                )
            }
            seamMarks = wanted
            // ⚠️ **EVERY CUT IS SPOKEN, DRAWN OR NOT** — a disc thinned away or
            // hidden beside a held cap is still a cut a VoiceOver user must
            // reach. Spoken again only when a cut or what it carries changes,
            // not on every sample of a trim.
            let spoken: [MediaTimelining.SpokenSeam] = onSeam == nil || reordering != nil || duration <= 0
                ? []
                : laidPlacements.dropLast().map { .init(index: $0.index, kind: $0.piece.transitionOut) }
            if spoken != spokenSeams {
                spokenSeams = spoken
                speakTheSeams()
            }
        }
        let offset = scroller.contentOffset.x
        let low = offset - MediaTimelining.filmMargin
        let high = offset + bounds.width + MediaTimelining.filmMargin
        for (index, button) in seamButtons {
            let kept = seamMarks.contains { $0.index == index && $0.x >= low && $0.x <= high }
            guard !kept else { continue }
            button.removeFromSuperview()
            seamButtons[index] = nil
            if spareSeamButtons.count < 4 { spareSeamButtons.append(button) }
        }
        let scale = max(traitCollection.displayScale, 1)
        for mark in seamMarks where mark.x >= low && mark.x <= high {
            let known = seamButtons[mark.index]
            guard known == nil || reckoning else { continue }
            let fresh = known == nil
            let button = known ?? takeASeamButton()
            seamButtons[mark.index] = button
            // ⚠️ **PLACED, NEVER ANIMATED.** A layout can run inside the drop's
            // fade, and a button from the pool would slide in from wherever it
            // last stood.
            UIView.performWithoutAnimation {
                button.seam = mark.index
                button.bounds.size = CGSize(width: mark.hitWidth, height: SeamButton.hitSize)
                button.center = CGPoint(
                    x: (mark.x * scale).rounded() / scale,
                    y: ((stripY + Metrics.strip / 2) * scale).rounded() / scale
                )
                if fresh || button.showing != mark.kind { button.show(mark.kind) }
                if fresh {
                    button.alpha = isCompact ? 0 : 1
                    button.transform = isCompact ? Self.seamAway : .identity
                }
                button.isUserInteractionEnabled = !isCompact
                button.layoutIfNeeded()
            }
        }
    }

    private func takeASeamButton() -> SeamButton {
        let button = spareSeamButtons.popLast() ?? {
            let made = SeamButton()
            made.addAction(
                UIAction { [weak self, weak made] _ in
                    guard let self, let made else { return }
                    onSeam?(made.seam)
                },
                for: .primaryActionTriggered
            )
            return made
        }()
        content.insertSubview(button, belowSubview: topBar)
        return button
    }

    /// Where a `+` goes as the film collapses under it: smaller, and up into
    /// the line with the film.
    static let seamAway = CGAffineTransform(
        translationX: 0, y: -(Metrics.strip - Metrics.line) / 2
    ).scaledBy(x: 0.6, y: 0.6)

    /// The `+` a touch at `x` belongs to, if one is on screen there.
    func shownSeam(atContentX x: CGFloat) -> Int? {
        guard !isCompact else { return nil }
        return seamButtons.first { abs($0.value.center.x - x) <= $0.value.bounds.width / 2 }?.key
    }

    /// ⚠️ **THE TRACK IS ONE ACCESSIBILITY ELEMENT, SO ITS BUTTONS ARE NOT.** A
    /// VoiceOver user reaches each cut through the track's own actions — every
    /// cut, in view or not.
    private func speakTheSeams() {
        accessibilityCustomActions = spokenSeams.map { mark in
            UIAccessibilityCustomAction(
                name: "Transition after clip \(mark.index + 1): \(mark.kind?.spokenLabel ?? "none")"
            ) { [weak self] _ in
                guard let self, let onSeam else { return false }
                onSeam(mark.index)
                return true
            }
        }
    }
}
