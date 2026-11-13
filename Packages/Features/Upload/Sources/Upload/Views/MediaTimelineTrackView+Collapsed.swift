import DesignSystem
import MediaPlayback
import UIKit

// Collapsed, for choosing a transition (#2388, out of the track's file).
extension MediaTimelineTrackView {
    // MARK: - Collapsed, for choosing a transition

    /// How tall the needle stands: the whole track, or down to the line.
    var needleHeight: CGFloat { isCompact ? Metrics.compactHeight : bounds.height }

    /// The film scaled into the line, its top edge where the film's was.
    private static var collapse: CGAffineTransform {
        let scale = Metrics.line / Metrics.strip
        return CGAffineTransform(translationX: 0, y: -(Metrics.strip - Metrics.line) / 2)
            .scaledBy(x: 1, y: scale)
    }

    /// How much film either side of a transition the preview loops.
    ///
    /// ⚠️ **AS MUCH AS STAYS ON SCREEN.** The needle is nailed to the centre and
    /// walks the stretch as it plays, so from its start the whole stretch has
    /// to fit in the half of the track to the needle's right — at the resting
    /// scale that is about a second and a quarter either side, *"quelques
    /// secondes avant jusqu'à quelques secondes après"*. Never less than half a
    /// second, however far the author has zoomed in; never more than two.
    var rehearsalLead: Double {
        guard bounds.width > 0, pointsPerSecond > 0 else { return Metrics.shortestLead }
        let reach = Double((bounds.width / 2 - Metrics.rehearsalMargin) / pointsPerSecond)
        let lead = (reach - VideoTransitionKind.standardSeconds) / 2
        return min(max(lead, Metrics.shortestLead), Metrics.longestLead)
    }

    /// Collapses the film upwards into a line under the ruler — or opens it
    /// again — leaving the track its height: the room below the line is the
    /// transitions row's (charter F28).
    ///
    /// ⚠️ **REFUSED WHILE A HANDLE OR A PIECE IS HELD**, and the answer says so.
    /// A collapse under a finger would take the thing it is moving away.
    ///
    /// ⚠️ **STAGED, THEN ANIMATED IN ONE SPRING — AND WITHOUT
    /// `.beginFromCurrentState`.** The line and the bars are laid out at alpha
    /// zero first; with that option the fade would read its from-value off a
    /// presentation layer that has never drawn them, and run from one to one
    /// (`uiview-animate-from-value-trap`).
    @discardableResult
    func setCompact(
        _ compact: Bool, bringingUnderTheNeedle seconds: Double? = nil, animated: Bool
    ) -> Bool {
        guard compact != isCompact else { return true }
        if compact {
            guard grip == nil, reordering == nil else { return false }
            select(nil, notify: true)
        }
        stopEasing()
        compactTurns += 1
        let turn = compactTurns
        isCompact = compact
        scroller.isScrollEnabled = !compact
        accessibilityTraits = compact ? [] : .adjustable
        accessibilityLabel = compact ? "Transition timeline" : Self.trimLabel
        for button in seamButtons.values { button.isUserInteractionEnabled = !compact }
        if compact {
            for mark in [rehearsalBar, windowMark] {
                mark.alpha = 0
                mark.isHidden = false
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        let target = seconds.map { offset(forPlayedSeconds: $0) }
        if target != nil {
            isEasing = true
            isFollowingPlayback = true
        }
        let changes = { [self] in
            film.transform = compact ? Self.collapse : .identity
            film.alpha = compact ? 0 : 1
            for stamp in rateStamps { stamp.alpha = compact ? 0 : 1 }
            for button in seamButtons.values {
                button.alpha = compact ? 0 : 1
                button.transform = compact ? Self.seamAway : .identity
            }
            for segment in lineSegments { segment.alpha = compact ? 1 : 0 }
            rehearsalBar.alpha = compact ? 1 : 0
            windowMark.alpha = compact ? 1 : 0
            needle.frame.size.height = needleHeight
            skeleton.alpha = compact ? 0 : 1
            if let target { scroller.contentOffset.x = target }
        }
        let landed = { [weak self] in
            guard let self, turn == compactTurns else { return }
            if target != nil {
                isEasing = false
                isFollowingPlayback = false
            }
            guard !isCompact else { return }
            for segment in lineSegments { segment.removeFromSuperview() }
            lineSegments.removeAll()
            rehearsalBar.isHidden = true
            windowMark.isHidden = true
            rehearsalRange = nil
            rehearsalWindow = nil
            // The film asked for nothing while it was a line.
            refreshTiles()
        }
        guard animated, window != nil else {
            changes()
            landed()
            return true
        }
        UIView.animate(
            withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            options: [.allowUserInteraction], animations: changes
        ) { _ in landed() }
        return true
    }

    /// Lights the stretch the preview loops, and the transition inside it — in
    /// PLAYED seconds, the axis the line is drawn on.
    func showRehearsal(
        _ range: ClosedRange<Double>?, window: ClosedRange<Double>?, animated: Bool
    ) {
        rehearsalRange = range
        rehearsalWindow = window
        guard isCompact else { return }
        guard animated, self.window != nil else { return layOutTheLine() }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) { [self] in
            layOutTheLine()
        }
    }

    /// The line, the lit stretch and the transition's mark.
    ///
    /// ⚠️ **CLIPPED TO THE SCREEN AND ITS MARGIN — CHARTER T6.** A piece of
    /// line as long as a four-minute piece is 43200px at 3x; a rounded layer
    /// that wide is what Metal asserts on.
    func layOutTheLine() {
        let offset = scroller.contentOffset.x
        let low = offset - MediaTimelining.filmMargin
        let high = offset + bounds.width + MediaTimelining.filmMargin
        var used = 0
        for span in drawnSpans where span.to > low && span.from < high {
            let from = max(span.from, low)
            let to = min(span.to, high)
            let segment: UIView
            if used < lineSegments.count {
                segment = lineSegments[used]
            } else {
                segment = UIView()
                segment.backgroundColor = UIColor.white.withAlphaComponent(0.35)
                segment.isUserInteractionEnabled = false
                segment.layer.cornerCurve = .continuous
                // ⚠️ **AS VISIBLE AS THE BAR ABOVE IT.** Staged for the collapse,
                // that is nothing yet; once collapsed, a piece of line scrolled
                // into view simply shows.
                segment.alpha = rehearsalBar.alpha
                content.insertSubview(segment, belowSubview: rehearsalBar)
                lineSegments.append(segment)
            }
            let width = max(to - from, 0)
            UIView.performWithoutAnimation {
                segment.frame = CGRect(x: from, y: stripY, width: width, height: Metrics.line)
                segment.layer.cornerRadius = min(Metrics.line / 2, width / 2)
                segment.layer.maskedCorners = Self.corners(
                    leading: from == span.from, trailing: to == span.to
                )
            }
            used += 1
        }
        while lineSegments.count > used { lineSegments.removeLast().removeFromSuperview() }

        let middle = stripY + Metrics.line / 2
        if let range = rehearsalRange {
            let from = max(MediaTimelining.x(atPlayedSeconds: range.lowerBound, pointsPerSecond: pointsPerSecond), low)
            let to = min(MediaTimelining.x(atPlayedSeconds: range.upperBound, pointsPerSecond: pointsPerSecond), high)
            let width = max(to - from, 0)
            rehearsalBar.frame = CGRect(
                x: from, y: middle - Metrics.rehearsal / 2, width: width, height: Metrics.rehearsal
            )
            rehearsalBar.layer.cornerRadius = min(Metrics.rehearsal / 2, width / 2)
        }
        rehearsalBar.isHidden = rehearsalRange == nil
        if let window = rehearsalWindow {
            let from = MediaTimelining.x(atPlayedSeconds: window.lowerBound, pointsPerSecond: pointsPerSecond)
            let to = MediaTimelining.x(atPlayedSeconds: window.upperBound, pointsPerSecond: pointsPerSecond)
            let width = max(to - from, Metrics.windowMinimum)
            let centre = min(max((from + to) / 2, low), high)
            windowMark.frame = CGRect(
                x: centre - width / 2, y: middle - Metrics.window / 2,
                width: width, height: Metrics.window
            )
            windowMark.layer.cornerRadius = min(Metrics.windowCorner, width / 2)
        }
        windowMark.isHidden = rehearsalWindow == nil
    }

    /// The bone under the part of the film that is on screen.
    ///
    /// ⚠️ **THE FILM'S RECTANGLE, NOT THE TRACK'S.** At rest the content carries
    /// half a track of lead-in (charter F2), so the clip starts under the needle
    /// and the leading half of the viewport holds no film at all. A bone spanning
    /// the whole width would promise pictures where there will never be any.
    func layOutTheSkeleton(filmWidth: CGFloat, stripY: CGFloat) {
        let offset = scroller.contentOffset.x
        let from = max(0, -offset)
        let to = min(bounds.width, filmWidth - offset)
        skeleton.frame = CGRect(x: from, y: stripY, width: max(to - from, 0), height: Metrics.strip)
        // Gone the moment there is anything at all to draw — a poster counts,
        // which is the whole point of handing one over.
        skeleton.isHidden = duration <= 0 || to <= from
            || anyFrame != nil || posterFrame != nil
    }

    /// States the play button's glyph without announcing it — the screen owns the
    /// player and tells the track which way round it is.
    func showPaused(_ paused: Bool) {
        guard paused != showingPaused else { return }
        let swapsInSight = showingPaused != nil && window != nil
        showingPaused = paused
        let image = (paused ? AppSymbol.play : AppSymbol.pause).image(Self.playGlyphConfiguration)
        PlayPauseGlyph.swap(playButton, site: .mediaTimeline, animated: swapsInSight) {
            playButton.configuration?.image = image
        }
        playButton.accessibilityLabel = paused ? "Play" : "Pause"
    }

    /// Where the needle is in the RESULT — the axis the track is drawn on.
    var playedSecondsUnderNeedle: Double {
        MediaTimelining.playedSeconds(
            atContentOffset: scroller.contentOffset.x,
            trackWidth: bounds.width,
            pointsPerSecond: pointsPerSecond,
            of: timeline, withinSource: duration
        )
    }

    /// Which piece is under the needle and where in the FILE it has got to —
    /// what a split cuts at, what a rate is applied to, and what the preview is
    /// asked to show.
    var momentUnderNeedle: MediaTimelining.Moment? {
        MediaTimelining.moment(
            atPlayedSeconds: playedSecondsUnderNeedle, in: timeline, withinSource: duration
        )
    }

    /// The moment of the FILE under the needle, for callers that only need that.
    var sourceSecondsUnderNeedle: Double { momentUnderNeedle?.sourceSeconds ?? 0 }
}
