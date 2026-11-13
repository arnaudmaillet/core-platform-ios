import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// The bar's items (#2388, out of the editor's file)
extension MediaEditorViewController {
    // MARK: - The bar's items

    /// ⚠️ **NEW ITEMS EVERY HAND-OVER, AND THE SAME IDENTIFIER ON EACH — BOTH
    /// HALVES OF THAT ARE THE FIX FOR THE `•••`.**
    ///
    /// Without an identifier, every hand-over was — to UIKit — a new set of
    /// items replacing an old one, animated as a cross-fade: for the length of
    /// it the bar held BOTH sets. `UIBarButtonItem.identifier` (iOS 26) is
    /// UIKit's own answer, in its own words: "set the same value on two
    /// different bar button items … to indicate that they should be treated as
    /// the same item during transitions." The song pill and the timeline's
    /// actions share one because they ARE one slot, so UIKit morphs one into
    /// the other instead of fading two past each other.
    ///
    /// ⚠️ **AND "TWO DIFFERENT ITEMS" IS MEANT LITERALLY.** Keeping ONE item per
    /// view and re-handing it was tried first, and it is worse: UIKit keeps the
    /// wrapper it built around the custom view, and that wrapper does not follow
    /// the view's width. Measured on the sequence the author recorded — a clip,
    /// Crop, Trim, Crop, Trim — the strip's constraint said 177, 186, 177, 186
    /// while its wrapper said 177, 186, 186, 195: nine points gained on every
    /// round trip, nine being the song pill's width less the actions'. The two
    /// strips overran the bar by exactly that and it swept one into a `•••`. A
    /// fresh item gets a fresh wrapper, measured at the hand-over from the width
    /// this screen has just written.
    ///
    /// ⚠️ **THE STRIP IS NAMED BY WHAT IT OFFERS.** A photograph's strip and a
    /// clip's are two items to UIKit, never one item whose content changed —
    /// see `photoStrip`.
    enum ItemID {
        static let leading = "upload.editor.toolbar.leading"
        /// "Next", and "Done"/"Discard" in its place while typing.
        static let primary = "upload.editor.primary"
        static let undo = "upload.editor.undo"
        static let redo = "upload.editor.redo"
        /// Shared with the new post's, so the push from here carries it.
        static let saveDraft = "upload.save-draft"

        static func categories(_ list: [Category]) -> String {
            "upload.editor.toolbar.categories." + list.map(\.title).joined(separator: ",")
        }
    }

    static func barItem(_ view: UIView, as identifier: String) -> UIBarButtonItem {
        BarItems.container(id: identifier, view: view)
    }




    /// The pill names the page's song once it has one, and offers to add one
    /// otherwise — `MediaEditorSoundtrackMode.pillTitle` decides which.
    func refreshSoundPill() {
        soundPill.setTitle(soundtrackMode.pillTitle)
    }

    /// Holds the two strips to the share `EditorSelectorLayout` gives them.
    ///
    /// ⚠️ **MEASURED FROM THE TOOLBAR, WHICH THIS SCREEN DOES NOT OWN.** The rule
    /// is pure precisely because `toolbarItems` are laid out by a `UIToolbar`
    /// inside the navigation controller, after a pass that needs a window — so it
    /// cannot be stated as constraints between the two views. It is read here,
    /// applied as two widths, and re-applied on every layout.
    ///
    /// ⚠️ **AND ONLY BETWEEN THE TWO STRIPS.** With the sound pill in the leading
    /// slot the arrangement that ships today already works — the pill states a
    /// width floor and the strip is told it may give — so the constraints come
    /// off rather than being applied to a control the rule was not written for.
    @discardableResult
    func shareTheBarBetweenTheTwoStrips() -> (leading: CGFloat, trailing: CGFloat)? {
        measureTheBar()
        guard let toolbar = navigationController?.toolbar, toolbar.bounds.width > 0 else {
            actionBarWidth.isActive = false
            photoStripWidth.isActive = false
            videoStripWidth.isActive = false
            return nil
        }
        // ⚠️ **WHAT THE BAR CHARGES AROUND THE TWO GROUPS, NOT A SPACING** —
        // see `ToolbarGeometry`. Charged as one 8pt gap inside 8pt margins, the
        // two strips overran an iPhone SE's bar and iOS swept the selector into
        // a `•••`.
        let available = barGeometry.available(in: toolbar.bounds.width)
        let leading: UIView = isTimelineShowing ? actionBar : soundPill
        let held = EditorSelectorLayout.widths(
            leadingWants: wantedWidthOfTheLeadingStrip(leading),
            available: available,
            trailingFloor: categoryBar.intrinsicContentSize.height
        )
        // ⚠️ **THE ACTIONS ARE HELD, THE PILL IS ONLY CAPPED.** The strip states
        // an intrinsic width and is pinned to it; the pill has none — it is laid
        // out by its label and its disc — so a width constraint would be the
        // screen deciding what the component already knows. What the screen owes
        // it is a ceiling, and the ceiling is inert until a song title is long
        // enough to leave the selector less than a bubble.
        actionBarWidth.isActive = isTimelineShowing
        actionBarWidth.constant = held.leading
        // ⚠️ **THE PILL IS CAPPED ONLY WHILE IT IS THE ONE IN THE BAR.** The
        // ceiling used to be written on every pass whatever the leading view
        // was, so opening the timeline capped the pill — which is not even in
        // the bar then — at the action bar's 112pt, and it stayed there when
        // the band closed. The author photographed the result: "Add a s...".
        if !isTimelineShowing { soundPillCap.constant = held.leading }
        // ⚠️ THE ROOM IS A CEILING, NOT A WIDTH. The strip takes its own
        // width when that fits, and only gives way — and scrolls — when the
        // song pill leaves it less.
        categoryBarWidth.constant = min(held.trailing, categoryBar.intrinsicContentSize.width)
        categoryBarWidth.isActive = true
        // A bar item's view keeps its autoresizing mask, so the size UIKit
        // reads at the hand-over is the frame's.
        leading.frame.size.width = held.leading
        categoryBar.frame.size.width = held.trailing
        return held
    }

    /// What the leading strip would take on its own.
    ///
    /// ⚠️ **MEASURED WITH ITS OWN CEILING OFF, OR THE CEILING IS A RATCHET.**
    /// `systemLayoutSizeFitting` solves the constraints the view is carrying,
    /// and `soundPillCap` is one of them — so the answer came back clamped by
    /// the LAST pass's ceiling, which was then written back as the next one.
    /// Every pass could lower it and none could raise it: a pill that had once
    /// been squeezed stayed squeezed, and the words stayed truncated, for the
    /// life of the screen.
    private func wantedWidthOfTheLeadingStrip(_ leading: UIView) -> CGFloat {
        guard leading === soundPill else { return Self.wantedWidth(of: leading) }
        let wasActive = soundPillCap.isActive
        soundPillCap.isActive = false
        let wants = Self.wantedWidth(of: leading)
        soundPillCap.isActive = wasActive
        return wants
    }


    #if DEBUG
    /// Internal for tests: the rule as it stands right now, so a test can ask
    /// whether the bar is actually shared the way the screen promises.
    var debugBarShare: (leading: CGFloat, trailing: CGFloat, available: CGFloat, leadingWants: CGFloat)? {
        guard let toolbar = navigationController?.toolbar, toolbar.bounds.width > 0 else { return nil }
        let leading: UIView = isTimelineShowing ? actionBar : soundPill
        return (
            leading.frame.width,
            categoryBar.frame.width,
            barGeometry.available(in: toolbar.bounds.width),
            wantedWidthOfTheLeadingStrip(leading)
        )
    }
    /// Internal for tests: the geometry the bar was last measured at, and what
    /// the strip's own width constraint says — to tell a stale measurement from
    /// a stale write.
    var debugCategoryWidthConstant: CGFloat { categoryBarWidth.constant }
    /// Internal for tests: the ceiling the pill is carrying.
    var debugSoundPillCap: CGFloat { soundPillCap.constant }
    var debugSoundPillWidth: CGFloat { soundPill.frame.width }
    #endif

    /// Reads `barGeometry` off whichever two items the bar is hosting.
    ///
    /// ⚠️ **ONLY WHILE BOTH ARE ON SCREEN.** A collapsed item has no platter,
    /// and a geometry read from one would be the collapse measuring itself.
    private func measureTheBar() {
        let leading: UIView = isTimelineShowing ? actionBar : soundPill
        // The flexible space between the two groups holds the slack the
        // selector no longer fills; the bar's own gap is the 20pt it charges
        // at rest — the same read the capture screen makes.
        guard let measured = BottomBarShare.measure(
            leading: leading, trailing: categoryBar, flush: false, keepingGap: ToolbarGeometry.fallback.gap
        ) else { return }
        barGeometry = measured
    }



    /// The width a strip would take on its own — `BottomBarShare`, shared with
    /// the camera's bar.
    static func wantedWidth(of view: UIView) -> CGFloat {
        BottomBarShare.wantedWidth(of: view)
    }


    /// The width constraint of the strip in the bar. The other one keeps the
    /// width it left with.
    var categoryBarWidth: NSLayoutConstraint {
        wearsTheVideoStrip ? videoStripWidth : photoStripWidth
    }

    /// Moves the pill onto the category that was tapped — see the note in
    /// `configureCategoryStrip` for why a tap does not do this by itself.
    /// ⚠️ **NOTHING TO DRIVE BY HAND ANY MORE.** This used to animate
    /// `setProgress` onto the bar's own `selectedIndex`, because `PagedTabBar`
    /// places its pill only from that call and expected a pager to make it. The
    /// selector moves its own pill, so what is left here is the screen's actual
    /// job: show what the chosen mode offers.
    func categoryChanged() {
        showAccessory(for: selectedCategory)
    }

    /// ⚠️ **READ ON `.valueChanged`, NEVER POLLED.** `PagedTabBar` rewrites
    /// `selectedIndex` half-way through a scrub (`applyProgress`), and its own
    /// note warns the index flips at the mid-point — so asking it at any other
    /// moment would open this band in the middle of a drag. The action fires only
    /// from `select(_:)`, which is the moment a choice is actually made.
    ///
    /// ⚠️ AND THE TITLE IS DERIVED, NOT A HARD-CODED POSITION. This strip has
    /// already been reordered once; `categories[3]` would break in silence.
    var selectedCategory: String? {
        guard let index = categoryBar.selection, categories.indices.contains(index) else { return nil }
        return categories[index].title
    }

    /// ⚠️ **LEAVING CROP IS AN ACT, NOT AN ABSENCE.** Choosing another mode has
    /// to put the canvas, the sheet and the stack back before the new band opens
    /// — the surface holds three suspensions and none of them unwinds itself.
    ///
    /// ⚠️ **EVERY CATEGORY BUT TRIM AND CROP IS A MODE OBJECT, AND THIS SWITCH
    /// ONLY DELEGATES TO IT.** What a mode shows — its tools, a notice, nothing
    /// — is the mode's to decide, in its own file.
    func showAccessory(for category: String?) {
        // ⚠️ **THE BAND IS NOT EMPTIED ON THE WAY PAST.** Every branch below
        // puts something in it (or deliberately nothing), so letting `exitCrop`
        // empty it first was a hand-over with nothing to show for itself — and
        // the second hand-over of the same turn, landing on the first, is the
        // sequence the author recorded collapsing the strip into a `•••`.
        if isCropping, category != "Crop" { exitCrop(emptyingTheBand: false) }
        switch category {
        case "Effects":
            open(effectsMode)
        case "Text":
            overlayMode.kind = .text
            open(overlayMode)
        case "Stickers":
            overlayMode.kind = .stickers
            open(overlayMode)
        case "Filters":
            open(filtersMode)
        case "Trim":
            // ⚠️ **A PHOTOGRAPH CANNOT REACH THIS AT ALL ANY MORE** — the strip
            // does not offer Trim for one (`categories(for:)`), so the notice
            // that used to stand here has no way of being seen. What is left is
            // the guard itself: a settle onto a photograph re-runs this while
            // the strip is being re-dressed, and it closes the band rather than
            // keeping a track for a picture with no film.
            guard let id = currentItemID, case .video(let seconds)? = itemsByID[id]?.kind else {
                setEditingAccessory(nil, animated: true)
                return
            }
            setEditingAccessory(timelineTools, animated: true)
            refreshTimelineTrack(id: id, duration: seconds)
        case "Crop":
            enterCrop()
        default:
            setEditingAccessory(nil, animated: true)
        }
    }

    /// Hands the track the clip it is cutting, then its pictures.
    ///
    /// ⚠️ **THE HANDLES ARE LAID OUT BEFORE THE FRAMES ARRIVE.** Reading a file
    /// and decoding a dozen exact times takes a moment — longer for an iCloud
    /// clip — and a track that waited for them would open empty and jump. The
    /// duration and the stored timeline are known at once, so the selection is
    /// drawn straight away over a blank strip and the pictures fill in behind it.
    ///
    /// ⚠️ **AND THE STRIP IS NOT BLANK WHILE THAT HAPPENS, WHICH IS WHAT THE
    /// POSTER IS FOR.** Reported from the device as "the timeline does not appear
    /// when it loads": two asynchronous steps — `PHImageManager` vending the
    /// file, then the first batch of exact-time decodes — stand between the tap
    /// and the first picture, and until both land the film is a row of
    /// transparent boxes. This screen is already holding the answer:
    /// `lastSource` is the canvas-sized picture of the clip the author is looking
    /// at, which for a video IS its poster frame. Handed over here it fills every
    /// visible tile in the same turn the mode opens, and each tile replaces it
    /// with its own frame as that arrives.
    ///
    /// ⚠️ **RE-ASKED AFTER THE AWAIT, TWICE.** The author may have swiped to
    /// another page or left the mode entirely while the frames were being
    /// decoded, and `band.content` is the only thing that says the track is still
    /// the tenant.
    private func refreshTimelineTrack(id: String, duration: Double) {
        // The row belongs to the clip it was opened on.
        closeTransitions(animated: false)
        trackSeconds = duration
        trackNeedsPlacement = true
        // ⚠️ **A HANDOVER ARMED WHILE THE TRACK WAS SHUT IS NOBODY'S.** The
        // follower does not run while another mode holds the band, so the one
        // the editor's first load armed was never settled: it would hold the
        // film at the load's landing for half a second after the track opened
        // over a clip that had long since moved on. A load still on its way
        // arms its own when it lands.
        if !previewPending { handover = .settled }
        timelineTrack.configure(duration: duration, timeline: edits(for: id).timeline)
        timelineTrack.forgetFrames()
        // ⚠️ **AND THE PROVIDER GOES WITH THEM — FOUND BY
        // `settlingOnAnotherClipRetargetsTheTrack`, WHICH TURNED RED.** The
        // replacement is installed below, after two awaits; until then the track
        // is still holding a closure over the PREVIOUS clip's file, and anything
        // that lays it out in between — a toolbar pass, a poster landing, any
        // run-loop turn at all — asks that closure for this clip's tiles. The
        // answer arrives under the CURRENT generation, so the token cannot reject
        // it: the strip fills with the wrong film, `decoded` is full, and the
        // right provider is then never asked for anything. Nil is the honest
        // state for the gap, and `askForMissingTiles` already refuses to ask
        // through one.
        timelineTrack.framesProvider = nil
        // ⚠️ **RESTATED EVERY TIME, `nil` INCLUDED.** A poster left over from the
        // previous page is a picture of the wrong film, and `forgetFrames` keeps
        // the poster on purpose — it is a fact about the clip, not about the
        // scale a pinch left behind.
        timelineTrack.showPoster(lastSource?.id == id ? lastSource?.image : nil)
        timelineTrack.select(nil, notify: false)
        refreshTrackActions()
        Task { [weak self] in
            guard let self else { return }
            guard let file = await library.videoFile(for: id) else { return }
            guard currentItemID == id, isTimelineShowing else { return }
            // ⚠️ **THE FILE'S OWN LENGTH, NOT THE ITEM'S DECLARED ONE.** The
            // declared duration is what the grid stamps on a tile and is only as
            // good as whatever vended it — under `-rich-media` a fixture whose
            // download failed falls back to a synthetic clip, so an item can
            // truthfully say 52 seconds while the file on disk runs two and a
            // half. Handles laid out against the declaration would then resolve a
            // cut that is not inside the clip, and the export would come back
            // empty. Asked of the asset, this cannot drift.
            let length = await realLength(of: file, id: id, declared: duration)
            guard currentItemID == id, isTimelineShowing else { return }
            // Decided on the FILE's length, not the declaration — the whole
            // reason the real duration is loaded above.
            guard length > MediaTimelining.shortestSourceSeconds else {
                setEditingAccessory(trimTooShort, animated: true)
                return
            }
            trackSeconds = length
            // ⚠️ **THE PROVIDER IS SET BEFORE THE DURATION, AND THE ORDER MATTERS.**
            // `configure` lays the track out, and laying out is what asks for the
            // first tiles. Set afterwards, the opening screenful would be
            // requested against a nil provider and the strip would stay blank
            // until something else moved.
            timelineTrack.framesProvider = { [weak self] seconds, height, spacing in
                guard let self, currentItemID == id else { return [:] }
                return await preview.frames(
                    of: file, atSourceSeconds: seconds, height: height, spacing: spacing
                )
            }
            timelineTrack.configure(duration: length, timeline: edits(for: id).timeline)
            #if DEBUG
            seedDebugCuts(id: id, length: length)
            #endif
            // A page that has just settled is playing, unless the author stopped
            // it — the glyph says which.
            timelineTrack.showPaused(
                playingSurface.flatMap { preview.isPaused(in: $0) } ?? pausedByAuthor
            )
            view.layoutIfNeeded()
            // The real length is only known here, and this is an answer about
            // it: what a split would do from where the needle stands.
            refreshTrackActions()
        }
    }





    /// ⚠️ **RESOLVED ONCE, NOT SIXTY TIMES A SECOND.** `arguments.contains` walks
    /// the launch arguments and compares strings; asking it per frame would put a
    /// scan in the one routine this whole change exists to keep cheap. The flag
    /// cannot change while the process runs, which is what makes caching it
    /// correct rather than merely faster — `VideoRenderFlags` states the same
    /// rule for the same reason.
    private static let probesFollow = ProcessInfo.processInfo.arguments.contains("-timeline-probe")

    private func probeFollowBeat() {
        guard Self.probesFollow else { return }
        let now = CACurrentMediaTime()
        if probeLastBeat > 0 { probeWorstGap = max(probeWorstGap, now - probeLastBeat) }
        probeLastBeat = now
        probeBeats += 1
        if probeWindowStart == 0 { probeWindowStart = now }
        guard now - probeWindowStart >= 1 else { return }
        print(String(
            format: "[timeline] follow beats=%d/s worstGap=%.1fms filmStep=%.1fpt",
            probeBeats, probeWorstGap * 1000,
            probeWorstGap * Double(MediaTimelining.pointsPerSecond)
        ))
        probeBeats = 0
        probeWorstGap = 0
        probeWindowStart = now
    }

    func followPlayhead() {
        probeFollowBeat()
        guard isTimelineShowing, let surface = playingSurface else { return }
        // ⚠️ **THE GLYPH IS BOUND TO THE PLAYER, NOT SET AT THE MOMENTS WE
        // HAPPEN TO KNOW ABOUT.** It was updated on a tap, on a scrub and on a
        // settle — which leaves it stale for everything else that stops a clip:
        // reaching the end, an interruption, a stall. A button showing "pause"
        // over a stopped clip is a control that lies about the thing it controls.
        // One bool a beat, and the setter below is a no-op when nothing moved.
        timelineTrack.showPaused(preview.isPaused(in: surface) ?? true)
        // ⚠️ **THE ITEM'S SECONDS ARE THE TRACK'S SECONDS — WHEN, AND ONLY WHEN,
        // THE ITEM IS RUNNING THE ARRANGEMENT THE TRACK IS SHOWING.** Not while a
        // new one is on its way, not while a handle has the file on screen, and
        // not in the instant between a gesture ending and the screen hearing
        // about it: in each of those the player's clock describes something the
        // track is not drawing.
        guard !previewPending, let subject = previewSubject, !subject.aiming,
              subject.timeline == timelineTrack.arrangement,
              let seconds = preview.playheadSeconds(in: surface)
        else { return }
        // ⚠️ **THE TRACK KEEPS THE TIME UNTIL THE PLAYER CATCHES UP.** A seek is
        // not instant, so the first tick after a finger lifts reads a player
        // that has not moved yet — and copying that back over the author's
        // position is the "it jumps back to where I started" they reported. The
        // rule and its give-up are in `MediaTimelining.handover`, which is where
        // they can be tested.
        let (mayFollow, next) = MediaTimelining.handover(handover, playerSeconds: seconds)
        handover = next
        guard mayFollow else { return }
        // ⚠️ **THE FIRST BEAT AFTER THE TRACK OPENS PLACES THE FILM; IT DOES NOT
        // EASE IT.** The clip has been playing on the canvas since the editor
        // opened, so the track appears seconds behind it — and an ease across
        // that gap is a slide the author never asked for.
        if trackNeedsPlacement {
            if timelineTrack.place(atPlayedSeconds: seconds) {
                trackNeedsPlacement = false
                theNeedleMoved(to: seconds)
            }
            return
        }
        // ⚠️ **NO BOUNDARY IS HANDLED HERE ANY MORE.** This routine used to SEEK
        // the file to the next piece's start whenever the playhead reached the
        // end of the one playing — after a re-order a jump across the file on
        // every boundary, reported as a pause between the pieces. The item plays
        // the arrangement itself; the loop back to the start is the player's.
        timelineTrack.follow(playedSeconds: seconds, advancing: preview.advancingRate(in: surface))
        theNeedleMoved(to: seconds)
    }


    /// What the preview item is running.
    ///
    /// ⚠️ **THE SCREEN HAS TO KNOW, BECAUSE THE PLAYER'S CLOCK MEANS WHATEVER THE
    /// ITEM IS.** Played seconds of THIS arrangement, or — while a handle is held
    /// — seconds of the file as shot. Everything that reads the player or seeks
    /// it asks this first.
    struct PreviewSubject {
        let id: String
        let file: URL
        /// The file's real length, which the arrangement was resolved against.
        let fileSeconds: Double
        /// The arrangement the item plays. Replaced without a new item when the
        /// film it plays does not change — a split.
        var timeline: MediaTimeline
        /// Whether the item is the FILE as shot, shown while a handle is held.
        var aiming: Bool
        /// The stretch of played seconds the item loops, or nil for all of it.
        var loop: ClosedRange<Double>?
        /// The crop the item was built with — a new crop is a new render size,
        /// and so a new item.
        let crop: MediaCrop
        /// The song the item was built with — a new song is a new audio track,
        /// and so a new item.
        let soundtrack: VideoSoundtrack?
    }


    /// Stops the clip while a sheet stands over it.
    func pauseUnderACover() {
        guard let surface = playingSurface else { return }
        preview.setPaused(true, in: surface)
        timelineTrack.showPaused(true)
    }

    /// Lets it run again once the sheet has gone — at whatever the AUTHOR last
    /// asked for, which may well be "stopped".
    ///
    /// ⚠️ **THE NEWS ARRIVES BEFORE UIKIT HAS FINISHED, SO IT IS ASKED AGAIN.**
    /// A picker says it is going from its own `viewDidDisappear`, which runs
    /// while the dismissal is still in flight: `presentedViewController` is
    /// still answering, the guard below refuses, and the clip would stay
    /// stopped for good. Measured in the test that found it. A couple of turns
    /// of the runloop is all it takes, and the guard is what stops a resume
    /// landing under a SECOND sheet opened straight after the first.
    ///
    /// ⚠️ **A DISMISSAL STILL IN FLIGHT IS WAITED FOR, NOT COUNTED IN TURNS.**
    /// The video picker calls `dismiss(animated: true)` and answers "cancelled"
    /// in the same breath, so the news arrives at the START of a ~0.35 s
    /// slide-down — and two run-loop turns are microseconds. The retries ran out
    /// under the sheet and the clip stayed stopped for good. A sheet that is
    /// leaving hands the resume to its own transition's completion, which asks
    /// again (the second-sheet guard still holds).
    func resumeAfterACover(retries: Int = 0) {
        guard !isCovered else {
            if let leaving = presentedViewController, leaving.isBeingDismissed,
               let coordinator = leaving.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    guard !context.isCancelled else { return }
                    self?.resumeAfterACover(retries: 2)
                }
                return
            }
            guard retries > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.resumeAfterACover(retries: retries - 1) }
            return
        }
        guard let surface = playingSurface else { return }
        let paused = fingerOnTrack || pausedByAuthor
        preview.setPaused(paused, in: surface)
        timelineTrack.showPaused(paused)
    }


    /// ⚠️ **THE FILE'S OWN LENGTH, NOT THE ITEM'S DECLARED ONE.** The declared
    /// duration is what the grid stamps on a tile and is only as good as
    /// whatever vended it — under `-rich-media` a fixture whose download failed
    /// falls back to a synthetic clip, so an item can truthfully say 52 seconds
    /// while the file on disk runs two and a half. Asked of the asset, it cannot
    /// drift; asked once per clip, it costs one header read.
    private func realLength(of file: URL, id: String, declared: Double) async -> Double {
        if let known = fileLengths[id] { return known }
        let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? declared
        let length = real.isFinite && real > 0 ? real : declared
        fileLengths[id] = length
        return length
    }

    /// Loads the settled page's edit, as it stands now, into the preview.
    ///
    /// ⚠️ **ONE WAY IN, FOR THE FIRST LOAD AND FOR EVERY EDIT.** A load that is
    /// overtaken — by a newer edit, a swipe, a handle taken hold of — abandons
    /// itself when it lands; the newest always wins, and one that fails clears
    /// the pending state so the track does not stop following for good.
    ///
    /// ⚠️ **THE LANDING IS ASKED WHEN THE ITEM GOES IN, OF THE TIMELINE THE PLAN
    /// WAS BUILT FROM.** Where to begin and what to loop are both played seconds
    /// of that arrangement; asked of anything newer, they would describe film the
    /// item does not play.
    func loadPreview(
        landing: @escaping @MainActor (_ timeline: MediaTimeline, _ fileSeconds: Double) -> VideoLoadLanding
    ) {
        guard let id = playingID, let surface = playingSurface else { return }
        previewLoads += 1
        let load = previewLoads
        previewPending = true
        let declared: Double
        if case .video(let seconds) = itemsByID[id]?.kind { declared = seconds } else { declared = 0 }
        Task { [weak self] in
            guard let self else { return }
            guard let file = await library.videoFile(for: id) else {
                if previewLoads == load { previewPending = false }
                return
            }
            let fileSeconds = await realLength(of: file, id: id, declared: declared)
            guard playingID == id, previewLoads == load else { return }
            let edited = edits(for: id)
            let timeline = edited.timeline
            var landed: VideoLoadLanding?
            // ⚠️ **THE SAME MAPPING THE POST IS EXPORTED WITH**, minus what the
            // canvas draws as views: overlays, and so the art for their stickers.
            await preview.load(
                edited.exportPlan(
                    sourceURL: file, fileSeconds: fileSeconds, artwork: nil, includingOverlays: false,
                    includingCrop: !isCropping
                ),
                in: surface
            ) { [weak self] in
                guard let self, playingID == id, previewLoads == load else { return nil }
                var wanted = landing(timeline, fileSeconds)
                // ⚠️ **WHILE A CUT'S TRANSITION OR A PIECE'S FILTER IS BEING
                // CHOSEN, EVERY LOAD LOOPS IT** — asked HERE, as the item goes in,
                // not when the load was asked for: a row closed in the meantime
                // loops nothing.
                if let loop = activeLoop(in: timeline, fileSeconds: fileSeconds) {
                    wanted = VideoLoadLanding(seconds: loop.lowerBound, loop: loop)
                }
                previewSubject = PreviewSubject(
                    id: id, file: file, fileSeconds: fileSeconds, timeline: timeline, aiming: false,
                    loop: wanted.loop, crop: edited.crop, soundtrack: edited.soundtrack
                )
                landed = wanted
                return wanted
            }
            guard previewLoads == load else { return }
            previewPending = false
            guard let landed, playingID == id else { return }
            // ⚠️ **THE LANDING DECIDES WHETHER THE CLIP RUNS.** A release that was
            // owed a new item left the player stopped rather than let it run on
            // the old one for a few frames; the pause is the author's, or the
            // finger's if one has come down since.
            let paused = fingerOnTrack || pausedByAuthor || isCovered
            preview.setPaused(paused, in: surface)
            timelineTrack.showPaused(paused)
            if !fingerOnTrack { handover = MediaTimelining.Handover(target: landed.seconds) }
        }
    }

    /// What the playing item loops for the row that is open: the stretch around
    /// a cut whose transition is being chosen, or the piece whose filter is.
    /// Nil when neither row is open on this clip.
    func activeLoop(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
        rehearsal(in: timeline, fileSeconds: fileSeconds)?.range
            ?? segmentFilterMode.rehearsal(in: timeline, fileSeconds: fileSeconds)
    }

    /// Brings the preview to the edit as it now stands — with a new item only
    /// when the film it plays would differ. Returns whether a load was asked for.
    ///
    /// ⚠️ **THE WHOLE LOOK IS NOT IN THE PREDICATE, ON PURPOSE.** It reaches a
    /// playing item live (`setLiveLook`); the crop and the song cannot, because
    /// one changes the render size and the other the item's tracks. A song's
    /// LEVELS are left out for the look's reason — they reach the item live
    /// (`setMixLevels`) — so only its file and its start count.
    ///
    /// ⚠️ **AWAY FROM THE TIMELINE, THE NEW ITEM LANDS WHERE THE OLD ONE WAS.**
    /// Nothing outside the track changes the film's clock — a new excerpt, a
    /// crop — so the author keeps the moment they were on rather than the film
    /// starting over under the control they just let go of.
    ///
    /// ⚠️ **`force` IS FOR A LOOK THE BACKING WOULD NOT TAKE.** It is not in the
    /// predicate above precisely because it normally reaches the item live; a
    /// backing that refuses it (`-avplayer-render`) has no other way in.
    @discardableResult
    func refreshPreview(force: Bool = false) -> Bool {
        guard let id = playingID, id == currentItemID else { return false }
        let edited = edits(for: id)
        let wanted = edited.timeline
        if !force, let subject = previewSubject, subject.id == id, !subject.aiming, !previewPending,
           subject.crop == edited.crop,
           VideoSoundtrack.laysTheSameAudio(subject.soundtrack, edited.soundtrack),
           MediaTimelining.playsTheSame(subject.timeline, wanted, withinSource: subject.fileSeconds) {
            // Same film, same clock: only the screen's record of it changes.
            previewSubject?.timeline = wanted
            return false
        }
        loadPreview { [weak self] _, _ in
            guard let self else { return VideoLoadLanding(seconds: 0) }
            guard isTimelineShowing else {
                let playhead = playingSurface.flatMap { preview.playheadSeconds(in: $0) }
                return VideoLoadLanding(seconds: playhead ?? 0)
            }
            return VideoLoadLanding(seconds: timelineTrack.playedSecondsUnderNeedle)
        }
        return true
    }

    /// Whether the release that is happening now is owed a new item before the
    /// clip may run again.
    private var aLoadIsOwed: Bool {
        guard let subject = previewSubject else { return previewPending }
        return subject.aiming || previewPending
            || !MediaTimelining.playsTheSame(
                subject.timeline, timelineTrack.arrangement, withinSource: subject.fileSeconds
            )
    }

    /// ⚠️ **THE ANSWERS THAT DEPEND ON WHERE THE NEEDLE IS, REFRESHED WITHOUT
    /// ASKING THEM SIXTY TIMES A SECOND.** Both of them — whether a split would
    /// do anything, and what rate the piece under the needle carries — resolve
    /// the timeline, which allocates; charter T8 asks the follow path not to. A
    /// tenth of a second of film is six frames at 60fps and 6pt at the resting
    /// scale, which is finer than either answer can change.
    private func theNeedleMoved(to seconds: Double) {
        guard abs(seconds - lastAnsweredNeedle) > 0.1 else { return }
        lastAnsweredNeedle = seconds
        refreshTrackActions()
    }




    /// The surface the settled page is playing in, if it is playing at all.
    /// ⚠️ **REMEMBERED, NOT RE-DERIVED.** It used to be looked up through the
    /// canvas's cell for the playing page, which answers nil whenever the cell
    /// is not reachable — while a sheet covers the screen, for one, so the
    /// clip could not be told anything until the cell came back. It is also the
    /// only way the CROP surface can hold the clip: the film plays there while
    /// its box is aimed, and that surface belongs to no cell.
    var playingSurface: VideoRenderView? { boundSurface }


    /// The film moved under the needle, or a handle moved: put that moment on
    /// the canvas.
    ///
    /// ⚠️ **A SEEK, NOT A STORE.** Scrubbing changes what is on screen and
    /// nothing else; `onChange` is the channel that writes to `edits`, and it
    /// fires on release only.
    func scrubbed(to moment: MediaTimelining.Moment) {
        guard rowFocus.transition == nil, let surface = playingSurface, let subject = previewSubject,
              subject.id == currentItemID
        else { return }
        if timelineTrack.isHoldingAnEdge {
            return aim(atSourceSeconds: moment.sourceSeconds, subject: subject, surface: surface)
        }
        // ⚠️ **ONLY WHILE THE ITEM IS RUNNING WHAT THE TRACK SHOWS.** A carry or a
        // handle release reports the needle in the NEW arrangement before the
        // screen has been told about it; the load that follows lands there.
        guard !subject.aiming, !previewPending, subject.timeline == timelineTrack.arrangement
        else { return }
        let played = timelineTrack.playedSecondsUnderNeedle
        // ⚠️ **HOW FAR THIS SAMPLE MOVED IS HOW FAST THE FINGER IS GOING**, and
        // that is what the seek's tolerance is worth — charter T7, measured in
        // FILM, which on a fast piece is more than the played distance.
        let moved = lastScrubbedSeconds.map { played - $0 } ?? 0
        lastScrubbedSeconds = played
        preview.seek(
            toSeconds: played, in: surface,
            toleranceSeconds: MediaTimelining.seekTolerance(
                movedPlayedSeconds: moved,
                atSpeed: MediaTimelining.rate(
                    atPiece: moment.piece, in: subject.timeline, withinSource: subject.fileSeconds
                )
            )
        )
    }

    /// A held handle wants the canvas to show its edge.
    ///
    /// ⚠️ **THE FILE AS SHOT, SHOWN AT ONCE, BECAUSE THE EDGE MAY BE ON FILM THE
    /// ARRANGEMENT DOES NOT CONTAIN.** Opening a piece reveals film that was cut
    /// away, and no seek inside the loaded arrangement can reach it. The swap is
    /// synchronous — an asynchronous one could land after the release that
    /// replaces it and leave raw film on the canvas for good — and it happens
    /// once per gesture; the release loads the new arrangement.
    private func aim(atSourceSeconds seconds: Double, subject: PreviewSubject, surface: VideoRenderView) {
        guard subject.aiming else {
            preview.showAsShot(subject.file, in: surface, atSourceSeconds: seconds)
            previewSubject?.aiming = true
            // An arrangement still on its way would land in the middle of the
            // drag and put the wrong film back.
            previewLoads += 1
            previewPending = false
            lastAimedSeconds = seconds
            return
        }
        let moved = lastAimedSeconds.map { seconds - $0 } ?? 0
        lastAimedSeconds = seconds
        preview.seek(
            toSeconds: seconds, in: surface,
            toleranceSeconds: MediaTimelining.seekTolerance(movedSeconds: moved)
        )
    }

    /// ⚠️ **PLAYBACK STOPS WHILE A FINGER IS ON THE TRACK, AND IT HAS TO.** A
    /// clip that keeps running fights every seek the scroll asks for: the player
    /// advances between samples, the track seeks it back, and the picture lands
    /// somewhere neither the author nor the player chose. The pause is what makes
    /// scrubbing feel like moving the film rather than arguing with it.
    func scrubbing(_ scrubbing: Bool) {
        fingerOnTrack = scrubbing
        if scrubbing {
            // A gesture that moves nothing must not arm a handover: the track
            // would then wait for an arrival at a position nobody asked for.
            lastScrubbedSeconds = nil
            lastAimedSeconds = nil
            handover = .settled
        }
        follower.isPaused = scrubbing || !isTimelineShowing
        guard let surface = playingSurface else { return }
        guard !scrubbing else {
            preview.setPaused(true, in: surface)
            timelineTrack.showPaused(true)
            return
        }
        // ⚠️ **A RELEASE THAT IS OWED A NEW ITEM LEAVES THE CLIP STOPPED.** Run
        // now, it would play the OLD item — the file a handle had on screen, or
        // the order before a carry — for the moment the new one takes to build;
        // the landing resumes it instead.
        guard !aLoadIsOwed else { return }
        handover = MediaTimelining.Handover(target: lastScrubbedSeconds)
        // Afterwards it goes back to whatever the AUTHOR last asked for, which
        // is not necessarily "playing".
        preview.setPaused(pausedByAuthor, in: surface)
        timelineTrack.showPaused(pausedByAuthor)
    }

    /// ⚠️ **THE TRIM TENANT HAS TO BE RE-DECIDED ON EVERY SETTLE, AND NOT
    /// DECIDING IT WAS A HIGH-SEVERITY DEFECT.** `refreshTimelineTrack` was
    /// reachable only from the category bar's `.valueChanged`, so paging with
    /// Trim open left the strip holding the PREVIOUS clip's frames, duration and
    /// handles — while `onChange` read `currentItemID` live. Measured: open Trim
    /// on a 52-second clip, swipe to a four-second one, drag 60pt and release,
    /// and a cut of 8s to 52s is stored against the four-second clip
    /// (60/390 × 52 = 8.0 exactly). It then publishes its last second, and the
    /// clip actually being trimmed publishes whole. Swiping onto a PHOTOGRAPH
    /// was worse: it gained a `trim` it never earned, moving its
    /// `MediaEdits.signature` and therefore its thumbnail cache key.
    ///
    /// `croppingID` carries the mirror of this warning — "a crop landing on a
    /// different item than the one the author is looking at is not a visual
    /// glitch, it is a rectangle stored against somebody else's photograph". The
    /// same sentence is true of a cut.
    ///
    /// Re-running `showAccessory` rather than only re-targeting the strip, so
    /// the strip/notice choice is re-made too: a photograph settled onto after a
    /// video must lose the strip, and a video settled onto after a photograph
    /// must lose the notice.
    func refreshTimelineTrackIfShowing() {
        guard isTimelineShowing || band.content === trimTooShort else { return }
        showAccessory(for: "Trim")
    }

    /// ⚠️ **A CATEGORY THE SCREEN RESTS ON WITHOUT HAVING ENTERED IT IS
    /// UNREACHABLE BY TAP, AND ONLY A SETTLE CAN CLEAR THAT.** Choosing "Crop"
    /// used to leave a video standing on a notice, with the canvas still paging;
    /// swiping on to a photograph changed nothing, because tapping the icon the
    /// strip already rests on announces no selection. The notice is gone — a clip
    /// is cropped like a photograph — but `enterCrop` still returns without
    /// entering when it cannot find the page's item, so the settle that brings a
    /// page it can find has to try again.
    func reopenCropIfWaiting() {
        guard !isCropping, selectedCategory == "Crop" else { return }
        showAccessory(for: "Crop")
    }

    /// Re-renders one page for everything the author has chosen for it.
    ///
    /// ⚠️ **A SECOND RENDER, AT CANVAS SIZE.** The thumbnail a look was chosen
    /// from is 56pt and the crop surface works at its own; pushing either onto the
    /// page would show a blurred picture. The canvas asks the library for its own
    /// size and renders that.
    ///
    /// ⚠️ **AND THE PAGE IS FOUND BY IDENTITY, NOT BY THE CURRENT INDEX.** This
    /// used to read `currentIndex` at the moment the picture came back, which is
    /// a different page if the author swiped while the library was answering —
    /// the render would land on whichever picture happened to be in front.
    ///
    /// ⚠️ NOTHING IS CAPTURED BEFORE THE AWAIT, on purpose — see the note inside.
    func redraw(_ id: String) {
        // ⚠️ **NO LIBRARY ROUND TRIP WHEN THE PICTURE IS ALREADY IN HAND.** Asking
        // for it again put the result a `PHImageManager` request away, and the
        // canvas showed the OLD framing until it answered.
        if let held = lastSource, held.id == id {
            render(held.image, as: edits(for: id), for: id)
            return
        }
        let size = canvasSize
        Task { [weak self] in
            guard let self else { return }
            let source = await self.library.thumbnail(for: id, size: size)
            self.remember(source, for: id)
            guard let source else { return }
            self.render(source, as: self.edits(for: id), for: id)
        }
    }

    /// Hands a rendered picture to the page that carries `id`.
    ///
    /// ⚠️ **FOUND BY IDENTITY, NOT BY THE CURRENT INDEX** — see `redraw`'s note.
    func show(_ image: UIImage?, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
        (page as? MediaEditorPageCell)?.show(image, for: id)
    }
}
