import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// Choosing a cut's transition and a piece's filter (#2388, out of the editor's file)
extension MediaEditorViewController {
    // MARK: - Choosing a cut's transition


    /// The stretch to loop and the transition inside it, for the focused cut of
    /// `timeline` — nil when no row is open on this clip.
    ///
    /// ⚠️ **READ LIVE, EVERY TIME.** A load that lands after the row closed must
    /// loop nothing, and one that lands on the next cut must loop that one.
    func rehearsal(
        in timeline: MediaTimeline, fileSeconds: Double
    ) -> (range: ClosedRange<Double>, window: ClosedRange<Double>)? {
        guard let seam = rowFocus.rehearsedSeam(current: currentItemID, playing: playingID) else {
            return nil
        }
        return MediaTimelining.rehearsal(
            atSeam: seam, in: timeline, withinSource: fileSeconds,
            lead: timelineTrack.rehearsalLead
        )
    }

    /// The `+` on a cut was tapped: collapse the film, open the row, and loop
    /// the few seconds around the cut.
    ///
    /// ⚠️ **ASKED FOR IN THOSE WORDS**: *"lorsque l'utilisateur sélectionne le
    /// plus, la timeline se réduit en hauteur (vers le haut) sous forme de trait
    /// et l'espace libre en dessous est utilisé pour afficher la scrollview des
    /// transitions"*.
    ///
    /// ⚠️ **NOT BEFORE THE FILE'S REAL LENGTH IS KNOWN.** The stretch is worked
    /// out against it, and the declared one can be wrong (`realLength`).
    func openTransitions(atSeam seam: Int) {
        // ⚠️ NEVER OVER A PIECE'S FILTER ROW — the two share the line.
        guard rowFocus.piece == nil, isTimelineShowing, let id = currentItemID, trackSeconds > 0,
              fileLengths[id] == trackSeconds, !timelineTrack.isHoldingAnEdge
        else { return }
        let timeline = edits(for: id).timeline
        let pieces = MediaTimelining.resolved(timeline, withinSource: trackSeconds)
        guard seam >= 0, seam < pieces.count - 1 else { return }
        let rehearsal = MediaTimelining.rehearsal(
            atSeam: seam, in: timeline, withinSource: trackSeconds, lead: timelineTrack.rehearsalLead
        )
        if rowFocus.transition != nil {
            // Already open: only the cut changes.
            rowFocus.transition?.seam = seam
            timelineTools.openTransitions(
                atSeam: seam, chosen: pieces[seam].transitionOut,
                seconds: MediaTimelining.transitionSeconds(atSeam: seam, in: timeline, withinSource: trackSeconds),
                longest: MediaTimelining.longestTransition(atSeam: seam, in: timeline, withinSource: trackSeconds),
                rehearsal: rehearsal?.range, window: rehearsal?.window, animated: true
            )
            landOnTheFocus()
            return
        }
        if timelineTools.isOfferingSpeeds { toggleTheRateChips() }
        actionBar.setActive(nil)
        guard timelineTools.openTransitions(
            atSeam: seam, chosen: pieces[seam].transitionOut,
            seconds: MediaTimelining.transitionSeconds(atSeam: seam, in: timeline, withinSource: trackSeconds),
            longest: MediaTimelining.longestTransition(atSeam: seam, in: timeline, withinSource: trackSeconds),
            rehearsal: rehearsal?.range, window: rehearsal?.window, animated: true
        ) else { return }
        rowFocus.transition = MediaTimelineRowFocus.Transition(id: id, seam: seam)
        rowFocus.borrowThePause()
        // A load on its way picks the stretch up as it lands.
        if !previewPending { landOnTheFocus() }
        refreshTrackActions()
        refreshHistoryItems()
    }

    /// A transition was chosen for the focused cut — `nil` takes it away.
    ///
    /// ⚠️ **STORED, SHOWN ON THE TRACK, AND REPLAYED.** A new kind is new film,
    /// so the preview gets a new item that lands on the stretch; choosing what
    /// the cut already carries changes nothing and simply plays it again.
    func chooseTransition(_ kind: VideoTransitionKind?) {
        guard let focus = rowFocus.transition, focus.id == currentItemID, trackSeconds > 0 else { return }
        let before = edits(for: focus.id).timeline
        let after = MediaTimelining.settingTransition(
            kind, atSeam: focus.seam, in: before, withinSource: trackSeconds
        )
        if after != before { change(focus.id) { $0.timeline = after } }
        // ⚠️ **THE TRACK SHOWS WHAT THE PLAYER PLAYS.** The follower only moves
        // the film while the item plays the track's own arrangement.
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        assert(timelineTrack.arrangement == after, "the collapsed track refused the choice")
        showTheFocusedTransition(in: after)
        rowFocus.rehearse()
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// A length was chosen for the focused cut's transition.
    ///
    /// ⚠️ **CLAMPED TO WHAT THE TWO PIECES CAN GIVE, AND STORED THROUGH
    /// `change`** — a length is an edit of the film like the kind it belongs
    /// to, so it is a step the arrows can take back, and a new item the preview
    /// lands on the stretch (charter F29b).
    func chooseTransitionDuration(_ seconds: Double) {
        guard let focus = rowFocus.transition, focus.id == currentItemID, trackSeconds > 0 else { return }
        let before = edits(for: focus.id).timeline
        let after = MediaTimelining.settingTransitionDuration(
            seconds, atSeam: focus.seam, in: before, withinSource: trackSeconds
        )
        if after != before { change(focus.id) { $0.timeline = after } }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        showTheFocusedTransition(in: after)
        rowFocus.rehearse()
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// States what the focused cut carries in `timeline` — its kind, its
    /// length and the longest it could have — and the stretch that shows it.
    private func showTheFocusedTransition(in timeline: MediaTimeline) {
        guard let focus = rowFocus.transition else { return }
        let rehearsal = MediaTimelining.rehearsal(
            atSeam: focus.seam, in: timeline, withinSource: trackSeconds, lead: timelineTrack.rehearsalLead
        )
        timelineTools.showTransition(
            MediaTimelining.transition(atSeam: focus.seam, in: timeline, withinSource: trackSeconds),
            seconds: MediaTimelining.transitionSeconds(atSeam: focus.seam, in: timeline, withinSource: trackSeconds),
            longest: MediaTimelining.longestTransition(atSeam: focus.seam, in: timeline, withinSource: trackSeconds),
            rehearsal: rehearsal?.range, window: rehearsal?.window
        )
    }

    /// Loops the focused stretch on the item that is playing, from its start.
    private func landOnTheFocus() {
        guard let focusID = rowFocus.focusedID, focusID == currentItemID,
              let surface = playingSurface, let subject = previewSubject,
              subject.id == focusID, !subject.aiming, !previewPending,
              let range = activeLoop(in: subject.timeline, fileSeconds: subject.fileSeconds)
        else { return }
        preview.setLoopRange(range, in: surface)
        previewSubject?.loop = range
        handover = MediaTimelining.Handover(target: range.lowerBound)
        preview.setPaused(false, in: surface)
        timelineTrack.showPaused(false)
    }

    /// Puts the row away: the film opens again, the loop stops, and the pause
    /// the author had comes back.
    ///
    /// ⚠️ **IT NEVER SEEKS.** The clip plays on from wherever the loop had got
    /// to, which is the moment the author was just looking at.
    ///
    /// ⚠️ **AND IT CLOSES THE PIECE'S FILTER ROW TOO.** Every way off the clip
    /// calls this; the two rows are one surface as far as leaving is concerned.
    func closeTransitions(animated: Bool) {
        closeSegmentFilters(animated: animated)
        guard rowFocus.transition != nil || timelineTools.editingSeam != nil else { return }
        rowFocus.transition = nil
        if previewSubject?.loop != nil {
            previewSubject?.loop = nil
            if let surface = playingSurface { preview.setLoopRange(nil, in: surface) }
        }
        timelineTools.closeTransitions(animated: animated)
        let paused = rowFocus.giveBackThePause()
        if let surface = playingSurface { preview.setPaused(paused, in: surface) }
        timelineTrack.showPaused(paused)
        refreshTrackActions()
        refreshHistoryItems()
    }

    // MARK: - Choosing a piece's filter


    /// ⚠️ **ONLY WHILE A PIECE IS HELD** — asked for in those words: *"qui sera
    /// active que lorsqu'un segment sera sélectionné dans la timeline"*. While
    /// the row is open the action stays live, lit, and closes it.
    var segmentFilterActionEnabled: Bool {
        guard isTimelineShowing, let id = currentItemID, trackSeconds > 0,
              fileLengths[id] == trackSeconds, !timelineTrack.isHoldingAnEdge
        else { return false }
        return rowFocus.piece != nil || timelineTrack.selectedPiece != nil
    }

    /// What the preview loops while the filter row is open on this clip.
    func segmentFilterRehearsal(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
        guard let piece = rowFocus.rehearsedPiece(current: currentItemID, playing: playingID) else { return nil }
        return MediaTimelining.rehearsal(ofPiece: piece, in: timeline, withinSource: fileSeconds)
    }

    /// The filter action was tapped: open the row on the held piece — or, when
    /// it is already open, put it away.
    func toggleSegmentFilters() {
        guard rowFocus.piece == nil else { return closeSegmentFilters(animated: true) }
        guard rowFocus.transition == nil, segmentFilterActionEnabled, let id = currentItemID,
              let piece = timelineTrack.selectedPiece
        else { return }
        let timeline = edits(for: id).timeline
        let pieces = MediaTimelining.resolved(timeline, withinSource: trackSeconds)
        guard pieces.indices.contains(piece) else { return }
        if timelineTools.isOfferingSpeeds { toggleTheRateChips() }
        let range = MediaTimelining.rehearsal(ofPiece: piece, in: timeline, withinSource: trackSeconds)
        rowFocus.piece = MediaTimelineRowFocus.Piece(id: id, piece: piece)
        guard timelineTools.openSegmentFilters(
            forPiece: piece, chosen: pieces[piece].filter, rehearsal: range, animated: true
        ) else {
            rowFocus.piece = nil
            return
        }
        actionBar.setActive(TrackAction.filter.rawValue)
        rowFocus.borrowThePause()
        dressSegmentFilterCards(id: id, piece: pieces[piece])
        if !previewPending { landOnTheFocus() }
        refreshTrackActions()
        refreshHistoryItems()
    }

    /// A look was chosen for the focused piece — `nil` takes it away.
    func chooseSegmentFilter(_ filter: MediaFilter?) {
        guard let focus = rowFocus.piece, focus.id == currentItemID, trackSeconds > 0 else { return }
        let before = edits(for: focus.id).timeline
        let after = MediaTimelining.settingFilter(
            filter, atPiece: focus.piece, in: before, withinSource: trackSeconds
        )
        if after != before { change(focus.id) { $0.timeline = after } }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        timelineTools.showSegmentFilter(filter)
        rowFocus.rehearse()
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// Puts the filter row away, as `closeTransitions` puts its own.
    func closeSegmentFilters(animated: Bool) {
        guard rowFocus.piece != nil || timelineTools.editingPiece != nil else { return }
        rowFocus.piece = nil
        pictureRequests += 1
        if previewSubject?.loop != nil {
            previewSubject?.loop = nil
            if let surface = playingSurface { preview.setLoopRange(nil, in: surface) }
        }
        timelineTools.closeSegmentFilters(animated: animated)
        actionBar.setActive(nil)
        let paused = rowFocus.giveBackThePause()
        if let surface = playingSurface { preview.setPaused(paused, in: surface) }
        timelineTrack.showPaused(paused)
        refreshTrackActions()
        refreshHistoryItems()
    }


    /// Dresses every card in that card's look — then the whole media's look over
    /// it, which is the order the compositor draws.
    ///
    /// ⚠️ **ONE PICTURE, NINE LOOKS, OFF THE MAIN THREAD** — the filter row's rule.
    ///
    /// ⚠️ **AND THE PICTURE IS THE REFERENCE PHOTOGRAPH, NOT THE PIECE'S OWN
    /// FRAME** — reported from a screenshot of nine identical BLACK cards. F31
    /// said "that piece's own frame" and it was written before F38; the two
    /// disagreed and F38 is the one that survives, for the reason it gives: a
    /// clip's frame is routinely black, blurred or one flat colour, and nine
    /// looks drawn on it say nothing about any of them. The piece is still what
    /// is REHEARSED — the loop under the row is the piece itself (F32), which is
    /// where the author sees the look on their own film.
    ///
    /// ⚠️ **THE FALLBACK IS STILL THE PIECE'S FRAME**, for the case the bundle
    /// has no such resource: a row of blank cards would be a worse answer than
    /// a row of dark ones.
    private func dressSegmentFilterCards(id: String, piece: MediaSegment) {
        pictureRequests += 1
        let request = pictureRequests
        let whole = edits(for: id).look
        let row = timelineTools.segmentFilters
        let middle = (piece.start + piece.end) / 2
        let reference = MediaLookReference.standsIn(for: item(id)) ? MediaLookReference.picture : nil
        Task { [weak self] in
            guard let self else { return }
            var source = reference
            if source == nil {
                guard let file = await library.videoFile(for: id) else { return }
                source = await preview.frames(
                    of: file, atSourceSeconds: [middle], height: MediaTransitionRowView.height * 2, spacing: 0
                ).values.first
            }
            guard let frame = source, pictureRequests == request else { return }
            let choices = MediaSegmentFilterRowView.filterChoices
            let pictures = await Task.detached(priority: .userInitiated) {
                choices.map { choice -> UIImage? in
                    guard let source = CIImage(image: frame) else { return nil }
                    var image = FrameLookRenderer.apply(FrameLook(preset: choice ?? .original), to: source, time: 0)
                    image = FrameLookRenderer.apply(whole, to: image, time: 0)
                    guard let cg = EditingRenderContext.shared.createCGImage(image, from: source.extent)
                    else { return nil }
                    return UIImage(cgImage: cg, scale: frame.scale, orientation: frame.imageOrientation)
                }
            }.value
            guard pictureRequests == request, rowFocus.piece?.id == id else { return }
            for (choice, picture) in zip(choices, pictures) {
                row.setPicture(picture, for: choice)
            }
        }
    }
}
