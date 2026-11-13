import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// Cutting the clip up, and setting a piece's rate (#2388, out of the editor's file)
extension MediaEditorViewController {
    // MARK: - Cutting the clip up, and setting a piece's rate

    /// Cuts the piece under the needle in two.
    ///
    /// ⚠️ **AT THE NEEDLE, WHICH IS WHERE THE AUTHOR IS LOOKING.** Every
    /// reference cuts at the playhead and this track's playhead is nailed to the
    /// centre of the screen, so "where" needs no aiming beyond the scroll that
    /// has already happened.
    ///
    /// ⚠️ **AND IT CANNOT SILENTLY DO NOTHING.** `MediaTimelining.split` refuses
    /// a cut that would leave either half under the floor and returns the
    /// timeline it was given; the button is disabled for exactly those moments,
    /// so this guard is the belt to `refreshTrackActions`' braces rather than the
    /// only thing standing between a tap and a no-op.
    func splitAtTheNeedle() {
        guard let id = currentItemID, trackSeconds > 0,
              let moment = timelineTrack.momentUnderNeedle
        else { return }
        let before = edits(for: id).timeline
        let after = MediaTimelining.split(
            before, atPiece: moment.piece, atSourceSeconds: moment.sourceSeconds,
            withinSource: trackSeconds
        )
        guard after != before else { return }
        change(id) { $0.timeline = after }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        // ⚠️ **THE FRAME UNDER THE NEEDLE STAYS THERE — AND A CUT CAN MOVE THE
        // CLOCK.** A transition overlaps its pieces by at most half of each, so
        // the half a cut leaves next to one can shorten that overlap, and every
        // piece from there on starts later: a 1.5s dissolve into a piece cut
        // 1.5s in overlaps by 0.75s, and the needle, left where it was, stood
        // 0.75s of film back from the cut, with the new cut drawn 45pt away and
        // the canvas jumping back to it. Found by review. The moment read before
        // the cut is put back under the needle, as a rate does (`chooseRate`):
        // the left half keeps the piece's index, and the moment is its end.
        timelineTrack.bringUnderTheNeedle(moment)
        refreshPreview()
        // ⚠️ **THE CUT HANDS BACK THE LEFT HALF, HELD — AND LEAVING NOTHING HELD
        // WAS THE DEFECT.** The handles exist only around the piece that is held
        // (charter F7b), so a track with nothing held has no handles anywhere:
        // the author cuts, reaches straight for the new seam, and the finger
        // finds no control at all — the film just scrolls under it. Reported as
        // the sections not being editable and as the whole track moving instead
        // of one clip. A split is not an arrival; it is an edit the author has
        // just made to ONE piece, and the half the needle has just left is the
        // one they were watching. `split` keeps that half at the index it had.
        timelineTrack.select(moment.piece, notify: false)
        refreshHistoryItems()
        refreshTrackActions()
    }

    func toggleTheRateChips() {
        let opening = !timelineTools.isOfferingSpeeds
        timelineTools.isOfferingSpeeds = opening
        actionBar.setActive(opening ? TrackAction.speed.rawValue : nil)
        if opening { timelineTools.speeds.show(rate: rateOfTheTargetPiece) }
        // ⚠️ THE BAND JUST CHANGED HEIGHT, AND THE BAND IS THE FOOT OF A FITTED
        // PICTURE'S WINDOW — what `setEditingAccessory` ends with, and for the
        // same reason.
        followTheBand(animated: true)
    }

    /// The piece a rate is set on: the one the author is holding, and ONLY that.
    ///
    /// ⚠️ **A RATE BELONGS TO A SELECTED PIECE, EXACTLY AS A PIECE'S FILTER
    /// DOES** — asked for in those words: the speed option is "specific to a
    /// selection in the timeline, like the filter option beside it; its icon
    /// disabled when no segment is selected". It used to fall back to the piece
    /// under the needle when nothing was held, which made the two icons side by
    /// side obey two different rules — one needing a selection, the other
    /// quietly inventing one — and a rate could land on a piece the author had
    /// never pointed at.
    private var targetPiece: Int? {
        guard currentItemID != nil, trackSeconds > 0 else { return nil }
        return timelineTrack.selectedPiece
    }

    private var rateOfTheTargetPiece: Double {
        guard let id = currentItemID, trackSeconds > 0, let index = targetPiece else { return 1 }
        return MediaTimelining.rate(
            atPiece: index, in: edits(for: id).timeline, withinSource: trackSeconds
        )
    }

    /// ⚠️ **THE PIECE UNDER THE NEEDLE, NOT THE WHOLE CLIP.** A rate that applied
    /// to everything would make the split pointless: cutting a clip in two exists
    /// so that one half can run at a different speed from the other.
    func chooseRate(_ rate: Double) {
        guard let id = currentItemID, trackSeconds > 0, let index = targetPiece else { return }
        // ⚠️ **THE FRAME THE AUTHOR IS LOOKING AT STAYS UNDER THE NEEDLE.** The
        // track is drawn in played seconds, so re-rating a piece changes the
        // width of everything at or after it — and the needle, nailed to the
        // centre, would end up on a different moment of film than the one on the
        // canvas. Read before, restored after.
        let watching = timelineTrack.momentUnderNeedle
        let after = MediaTimelining.setRate(
            rate, atPiece: index, in: edits(for: id).timeline, withinSource: trackSeconds
        )
        change(id) { $0.timeline = after }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        if let watching { timelineTrack.bringUnderTheNeedle(watching) }
        timelineTools.speeds.show(rate: rate)
        refreshHistoryItems()
        refreshTrackActions()
        // ⚠️ **THE RATE IS BUILT INTO THE ITEM, SO A NEW RATE IS A NEW ITEM** —
        // landing on the needle, which `bringUnderTheNeedle` has just put back on
        // the frame the author was looking at.
        refreshPreview()
    }

    /// What the actions can do from where the needle now stands.
    func refreshTrackActions() {
        guard isTimelineShowing, let id = currentItemID, trackSeconds > 0 else { return }
        // ⚠️ **A CUT OR A RATE WHILE A ROW IS OPEN WOULD MOVE THE CUT, OR THE
        // PIECE, IT IS OPEN ON.** Both wait for it to close — the transitions
        // row and the piece's filter row alike.
        let focused = rowFocus.transition != nil || segmentFilterMode.isOpen
        // ⚠️ **THE PIECE FILTER'S OWN RULE IS ITS MODE'S** (a piece held, the
        // file's real length known); the transitions row still shuts it.
        actionBar.setEnabled(
            rowFocus.transition == nil && segmentFilterMode.actionEnabled, at: TrackAction.filter.rawValue
        )
        // ⚠️ **THE SAME RULE AS THE FILTER BESIDE IT: A PIECE MUST BE HELD** —
        // see `targetPiece`. And the chips close with the selection they spoke
        // for, or they would sit open over a clip with no piece chosen, their
        // highlighted rate describing nothing.
        let holdsAPiece = timelineTrack.selectedPiece != nil
        actionBar.setEnabled(!focused && holdsAPiece, at: TrackAction.speed.rawValue)
        if timelineTools.isOfferingSpeeds, !holdsAPiece { toggleTheRateChips() }
        actionBar.setEnabled(
            !focused && timelineTrack.momentUnderNeedle.map {
                MediaTimelining.canSplit(
                    edits(for: id).timeline, atPiece: $0.piece,
                    atSourceSeconds: $0.sourceSeconds, withinSource: trackSeconds
                )
            } ?? false,
            at: TrackAction.split.rawValue
        )
        if timelineTools.isOfferingSpeeds {
            timelineTools.speeds.show(rate: rateOfTheTargetPiece)
        }
    }

    /// Whether the author stopped the clip — see
    /// `MediaTimelineRowFocus.pausedByAuthor`.
    var pausedByAuthor: Bool { rowFocus.pausedByAuthor }

    /// ⚠️ **A TAP ON THE PICTURE IS THE PLAY BUTTON EVERY VIDEO SURFACE HAS.**
    /// The ruler's glyph is the explicit control; this is the one nobody has to
    /// find.
    ///
    /// ⚠️ **AND IT CARRIES NO `!isCropping` GUARD, WHICH IT DID FOR ONE BUILD.**
    /// The reasoning was sound — the crop surface owns the canvas, so a tap there
    /// is aimed at the box rather than at the film — and the guard has never had
    /// anything to do. It used to be `enterCrop` REFUSING videos that made it
    /// dead; a clip is cropped like a photograph now, and what makes it dead
    /// instead is the `stopPreview()` `enterCrop` runs on its way in. Nothing is
    /// bound while the surface is up, so `togglePreviewPlayback` finds no surface
    /// to toggle. That `stopPreview()` was itself once deleted from `enterCrop`
    /// as unreachable, for the same reason this guard was: it is back, and it is
    /// doing the work.
    @objc func mediaTapped() {
        togglePreviewPlayback()
        flashThePlaybackState()
    }

    /// ⚠️ **ONLY FOR THE TAP ON THE PICTURE.** The timeline's own glyph changes
    /// itself under the finger that pressed it; a second answer in the middle
    /// of the picture would pull the eye away from where the finger is. The
    /// picture is the control nobody can see, so it is the one that needs one.
    private func flashThePlaybackState() {
        guard let surface = playingSurface, surface.window != nil,
              let paused = preview.isPaused(in: surface)
        else { return }
        if playbackFlash.superview == nil { view.addSubview(playbackFlash) }
        let middle = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: view)
        playbackFlash.flash(paused: paused, at: middle)
    }



    func togglePreviewPlayback() {
        guard let surface = playingSurface else { return }
        let paused = preview.isPaused(in: surface) ?? true
        // ⚠️ **A TOGGLE DURING THE ROW WINS** — see `authorChose(paused:)`.
        rowFocus.authorChose(paused: !paused)
        preview.setPaused(!paused, in: surface)
        timelineTrack.showPaused(!paused)
    }






    func enterCrop() {
        guard let id = currentItemID, itemsByID[id] != nil else { return }
        guard !isCropping else { return }
        isCropping = true
        // ⚠️ **THE CLIP KEEPS PLAYING, ON THE CROP SURFACE.** It used to stop
        // and the author aimed at a poster frame — still, and often the least
        // representative frame there is. The binding moves to the surface at
        // the end of this routine, once the box and the still are in place.
        lockCanvas(by: .crop)

        cropSurface.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ ABOVE THE CANVAS AND BELOW THE DISSOLVE: the chrome keeps its lift
        // over the editing surface exactly as it has over the picture.
        view.insertSubview(cropSurface, aboveSubview: canvas)
        NSLayoutConstraint.activate([
            cropSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cropSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cropSurface.topAnchor.constraint(equalTo: view.topAnchor),
            cropSurface.bottomAnchor.constraint(equalTo: band.topAnchor)
        ])
        // ⚠️ ABOVE THE SURFACE AND BELOW THE DISSOLVE, so the ramp still runs over
        // it — see `cropChrome`.
        view.insertSubview(cropChrome, aboveSubview: cropSurface)
        NSLayoutConstraint.activate([
            cropChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cropChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cropChrome.topAnchor.constraint(equalTo: band.topAnchor),
            cropChrome.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // The dots count pages nobody can turn while this is open.
        pageDots.isHidden = true
        croppingID = id
        showCropBarItems(true, animated: true)
        setEditingAccessory(cropTools, animated: true)
        showCropPicture(for: id)
        settleIntoCrop()
        playInsideTheCropBox(for: id)
    }

    /// The picture shrinking into the frame it is about to be cut in.
    ///
    /// ⚠️ **A CROSSFADE, NOT A SWAP — AND THE CANVAS STAYS UP FOR IT.** The
    /// surface is inset to the safe area and the canvas is full-bleed, so hiding
    /// one and showing the other is the same photograph jumping to a smaller
    /// frame in a single frame. Holding the canvas until the fade completes gives
    /// the eye something to follow, and the surface starting a little larger is
    /// what makes the move read as settling in rather than appearing.
    ///
    /// ⚠️ **LAID OUT BEFORE THE ANIMATION BEGINS.** The surface was added to the
    /// hierarchy two statements ago and has no frame yet; animating a transform on
    /// a zero-sized view animates nothing, and the first layout pass would then
    /// snap it into place — the exact from-value trap this repository has paid for
    /// before.
    private func settleIntoCrop() {
        view.layoutIfNeeded()
        cropSurface.alpha = 0
        cropChrome.alpha = 0
        cropSurface.transform = CGAffineTransform(scaleX: Metrics.cropEntryScale, y: Metrics.cropEntryScale)
        // ⚠️ **ONE THING FADES, AND NOTHING IS HIDDEN — MEASURED TWICE BEFORE IT
        // WAS WRITTEN THIS WAY.** The first cut crossfaded the canvas against the
        // surface and put a BLACK FRAME on screen (frame 450 of 677 on a
        // recording: the canvas reached zero before the surface had left it). The
        // second kept the canvas at full strength and hid it in the animation's
        // COMPLETION — and the completion fires immediately, which a unit test
        // catches and a screenshot never would (`theCanvasIsStillThereWhileTheSurfaceFadesIn`).
        // So nothing is hidden at all: the surface is opaque and spans the whole
        // view, and a thing that is covered needs no hiding. One extra composited
        // layer is the entire cost.
        UIView.animate(withDuration: Metrics.cropTransition, delay: 0, options: [.curveEaseOut]) {
            self.cropSurface.alpha = 1
            self.cropChrome.alpha = 1
            self.cropSurface.transform = .identity
        }
    }

    ///
    /// `resuming` plays the settled page's clip again — with the crop just
    /// made, since the item is built anew — unless the screen is on its way out.
    func exitCrop(resuming: Bool = true, emptyingTheBand: Bool = true) {
        guard isCropping else { return }
        isCropping = false
        croppingID = nil
        // ⚠️ **THE TOOLS LEAVE WITH THE SURFACE, AND THIS WAS A REAL DEFECT.**
        // Choosing another mode replaces the band's tenant on its way past, but
        // `viewWillDisappear` does not — so pressing "Next" from inside a crop and
        // stepping back left the dial standing in the band with no surface behind
        // it. Turning it then wrote crops computed from a detached view's stale
        // bounds, onto whichever picture happened to be in front. Invisible while
        // it happened, and in the post afterwards.
        if emptyingTheBand, band.content === cropTools { setEditingAccessory(nil, animated: true) }
        unlockCanvas(by: .crop)
        showCropBarItems(false, animated: true)
        // ⚠️ BACK TO ITS OWN RULE, NOT TO `false`: the indicator hides itself
        // under two pictures, and a single-medium screen has no dots to show.
        pageDots.isHidden = items.count < 2
        // ⚠️ **RE-RENDERED BEFORE THE FADE, NOT AFTER.** The canvas is about to
        // be faded back in, and it must already be showing the result — fading in
        // the OLD framing and correcting it a beat later is the delay this whole
        // path exists to remove. `redraw` answers in the same turn when the
        // picture is already held, which it is: the surface has been showing it.
        if let id = croppingID ?? currentItemID { redraw(id) }
        leaveCropGracefully()
        // ⚠️ **THE BOX'S FILM IS UNCUT, SO IT CANNOT SIMPLY CARRY ON.** The clip
        // was bound to the crop surface and playing the WHOLE film; the canvas
        // must now play the cut one. Unbinding first is what makes the reload
        // happen at all — `playSettledPage` returns early for a page that is
        // already the playing one.
        // ⚠️ **THE BOX'S CLOCK, READ BEFORE THE STOP THAT FORGETS IT** — so the
        // canvas takes the film back at the moment the author left it, not at
        // its first frame. See `continuing`.
        let carried = playheadOfTheFilmPlayingNow()
        stopPreview()
        // ⚠️ **NOT LEFT TO A SETTLE THAT MAY NEVER COME.** Nothing scrolls on
        // the way out, so nothing else would start it.
        if resuming { playSettledPage(from: carried) }
    }

    /// The reverse of `settleIntoCrop`: the frame lets go and the picture opens
    /// back out to the canvas.
    private func leaveCropGracefully() {
        // ⚠️ **ONLY THE SURFACE ANIMATES, AND WHAT IT UNCOVERS IS ALREADY
        // CORRECT.** The canvas has been there the whole time, redrawn a statement
        // ago with the cut applied; the fade merely stops covering it.
        UIView.animate(withDuration: Metrics.cropTransition, delay: 0, options: [.curveEaseOut]) {
            self.cropSurface.alpha = 0
            self.cropChrome.alpha = 0
            self.cropSurface.transform = CGAffineTransform(
                scaleX: Metrics.cropEntryScale, y: Metrics.cropEntryScale
            )
        } completion: { _ in
            // ⚠️ REMOVED ONLY AT THE END, and put back as it was found: a surface
            // left wearing a transform and no alpha would open its next crop
            // invisible and enlarged.
            self.cropSurface.removeFromSuperview()
            self.cropChrome.removeFromSuperview()
            self.cropSurface.transform = .identity
            self.cropSurface.alpha = 1
            self.cropChrome.alpha = 1
        }
    }


    func showCropPicture(for id: String) {
        let chosen = edits(for: id)
        let ratio = cropRatios[id] ?? .free
        let size = canvasSize
        cropTools.adopt(angle: MediaCropGeometry.split(chosen.crop.angle).fine, ratio: ratio)
        refreshHistoryItems()
        // ⚠️ THE SAME SHORTCUT AS `redraw`: the picture the canvas is showing is
        // the picture the surface wants, so opening the mode need not wait for the
        // library to answer a question it has already answered.
        if let held = lastSource, held.id == id {
            dress(held.image, in: chosen, crop: edits(for: id).crop, ratio: ratio)
            return
        }
        cropSurface.isUserInteractionEnabled = false
        cropTools.isUserInteractionEnabled = false
        if cropLoader.superview !== cropSurface {
            cropSurface.addSubview(cropLoader)
            NSLayoutConstraint.activate([
                cropLoader.centerXAnchor.constraint(equalTo: cropSurface.centerXAnchor),
                cropLoader.centerYAnchor.constraint(equalTo: cropSurface.centerYAnchor),
            ])
        }
        cropLoaderGate.begin { [weak self] in self?.isCropping == true && self?.croppingID == id }
        Task { [weak self] in
            guard let self else { return }
            let source = await library.thumbnail(for: id, size: size)
            remember(source, for: id)
            cropLoaderGate.end()
            guard isCropping, croppingID == id else { return }
            // ⚠️ RE-READ, NOT THE VALUES CAPTURED BEFORE THE AWAIT. Nothing can
            // have changed them while the controls were dead, but reading them
            // again is what makes that true by construction rather than by
            // argument.
            let now = edits(for: id)
            dress(source, in: now, crop: now.crop, ratio: cropRatios[id] ?? .free)
        }
    }

    /// Puts a picture on the surface wearing its look, and wakes the controls.
    private func dress(_ source: UIImage?, in chosen: MediaEdits, crop: MediaCrop, ratio: CropRatio) {
        // ⚠️ **DRESSED BUT NOT CUT.** The look is shown so the author crops the
        // photograph they will actually publish; the CUT is the surface's own job,
        // live under the finger. Applying the crop here too would cut a picture
        // that is already cut.
        let dressed = source.flatMap { MediaFilterRenderer.apply(chosen.filter, to: $0) } ?? source
        cropSurface.show(dressed, crop: crop, ratio: ratio)
        cropSurface.isUserInteractionEnabled = true
        cropTools.isUserInteractionEnabled = true
    }


    func cropChanged(_ crop: MediaCrop) {
        guard let id = croppingID else { return }
        change(id, settling: !isTurningTheDial) { $0.crop = crop }
        // ⚠️ ONLY THE UNDO BUTTON, NEVER THE DIAL — see `setCanReset`. Re-stating
        // the dial's angle from here would fight the finger that is turning it.
        refreshHistoryItems()
    }
}
