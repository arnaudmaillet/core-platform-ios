#if DEBUG
import DesignSystem
import MediaPlayback
import UIKit

// MARK: - QA hooks
//
// The launch-argument hooks that drive the screen (`-upload-post`,
// `-upload-category`, `-upload-seed-cuts`) and the `debug*` accessors that read
// no private state live here. The production methods they reach with side
// effects (`goNext`, `categoryChanged`, `openTransitions`) stay `private`
// behind thin `debug*` wrappers in `MediaEditorViewController.swift`, and the
// accessors that read private state (the crop surface, the bar's constraints,
// the preview's bookkeeping…) stay there too.

extension MediaEditorViewController {
    /// The value after a flag, `-upload-category 3` style.
    ///
    /// ⚠️ **THE PICKER'S `debugArgument` IS PRIVATE TO IT**, so this is stated
    /// here rather than reached for. Two small readers beat widening a seam for
    /// a DEBUG convenience.
    static func debugValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Where the canvas actually IS, behind `-upload-log-sheet`.
    ///
    /// ⚠️ **TWO CAUSES LOOK IDENTICAL IN A SCREENSHOT AND NEED OPPOSITE FIXES:**
    /// a canvas laid out BETWEEN the bars, or a canvas running the full sheet
    /// under bars that paint over it. Both show a picture that stops at the
    /// chrome. Two rounds were spent guessing between them — transparent bar
    /// appearances, then `extendedLayoutIncludesOpaqueBars` — and neither moved
    /// a pixel. These are the numbers that tell them apart: if the CELL spans
    /// the sheet, the bars are painting; if it stops short, the layout is.
    func logCanvas(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") else { return }
        let bar = navigationController?.navigationBar
        let foot = navigationController?.toolbar
        let cell = canvas.cellForItem(at: IndexPath(item: 0, section: 0))
        print("""
        [editor \(moment)] \
        window=\(view.window?.bounds.size.debugDescription ?? "nil") \
        view=\(view.frame) safeArea=\(view.safeAreaInsets) \
        canvas=\(canvas.frame) inset=\(canvas.contentInset) adjusted=\(canvas.adjustedContentInset) \
        cell=\(cell?.frame.debugDescription ?? "nil") \
        navBar=\(bar?.frame.debugDescription ?? "nil") barTranslucent=\(bar?.isTranslucent.description ?? "nil") \
        toolbar=\(foot?.frame.debugDescription ?? "nil") footTranslucent=\(foot?.isTranslucent.description ?? "nil") \
        extendedOpaque=\(extendedLayoutIncludesOpaqueBars) edges=\(edgesForExtendedLayout.rawValue)
        """)
    }

    /// The launch-argument hooks `viewDidAppear` runs, once each.
    func runDebugAppearanceHooks() {
        // ⚠️ **THE FINALISATION SCREEN HAD NO SCRIPTED WAY IN.** `-upload-edit`
        // stops at this screen and `debugTapNext()` is internal-to-tests, so the
        // keyboard and the caption — both reported as broken there — could not be
        // reached in a running app at all. One flag carries the flow the last
        // step, after a beat so the push does not race this appearance.
        if ProcessInfo.processInfo.arguments.contains("-upload-post"), !hasAutoAdvanced {
            hasAutoAdvanced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.debugTapNext()
            }
        }
        // ⚠️ **"Filters" IS THE ONE CATEGORY A TAP CANNOT REACH.** It is fourth in
        // a strip this toolbar over-subscribes — the sound pill floors at 240pt,
        // so the strip scrolls its overflow and the fourth pill sits off the
        // trailing edge. A coordinate tap therefore cannot open the band, and this
        // repository has already concluded once that a tap is not an instrument.
        // `-upload-category <i>` is the picker's `-upload-album <i>` idiom, here.
        //
        // ⚠️ GUARDED LIKE `-upload-post`, AND FOR THE SAME REASON: `viewDidAppear`
        // runs again on every pop back from the finalisation screen.
        if !hasSelectedDebugCategory,
           let raw = Self.debugValue(after: "-upload-category"),
           let index = Int(raw), debugCategoryTitles.indices.contains(index) {
            hasSelectedDebugCategory = true
            debugCategoryBar.select(index)
            // ⚠️ `select(_:)` ANNOUNCES ONLY ON A CHANGE — picking the index the
            // strip already rests on sends nothing, and the band would never open.
            debugCategoryChanged()
        }
    }

    /// `-upload-seed-cuts N` cuts the first clip the track opens on into N equal
    /// pieces, `-upload-seed-reverse` plays them back to front,
    /// `-upload-seed-transition <raw value>` puts that transition on every cut,
    /// and `-open-transitions <i>` opens the row on cut `i` — once, through the
    /// very edit path a person's taps take.
    ///
    /// ⚠️ **A SIMULATOR CANNOT SPLIT AT A CHOSEN SECOND BY HAND** — a drag loses
    /// ten points of slop before the film moves — and a transition is only worth
    /// checking on cuts that sit where the test says they do.
    func seedDebugCuts(id: String, length: Double) {
        guard !hasSeededDebugCuts,
              let raw = Self.debugValue(after: "-upload-seed-cuts"),
              let count = Int(raw), count > 1, length > 0
        else { return }
        hasSeededDebugCuts = true
        let each = length / Double(count)
        let kind = Self.debugValue(after: "-upload-seed-transition")
            .flatMap(VideoTransitionKind.init(rawValue:))
        var pieces = (0..<count).map {
            MediaSegment(start: Double($0) * each, end: Double($0 + 1) * each)
        }
        if ProcessInfo.processInfo.arguments.contains("-upload-seed-reverse") {
            pieces.reverse()
        }
        for index in pieces.indices.dropLast() { pieces[index].transitionOut = kind }
        let timeline = MediaTimeline(segments: pieces)
        change(id) { $0.timeline = timeline }
        timelineTools.track.configure(duration: length, timeline: timeline)
        refreshHistoryItems()
        refreshPreview()
        VideoPlaybackTrace.emit("seeded \(count) cuts, transition=\(kind?.rawValue ?? "none")")
        if let raw = Self.debugValue(after: "-open-transitions"), let seam = Int(raw) {
            debugOpenTransitions(atSeam: seam)
        }
    }
}

// MARK: - Accessors for tests

extension MediaEditorViewController {
    /// Internal for tests: the items the bar is holding, by identity.
    var debugToolbarItems: [UIBarButtonItem] { toolbarItems ?? [] }
    /// Internal for tests: the canvas's own bounds, to compare a page against.
    var debugCanvasBounds: CGRect { canvas.bounds }
    /// Internal for tests: the fit chosen for an item, defaulting as the screen does.
    func debugFit(for id: String) -> ContentFit { edits(for: id).fit }
    /// Internal for tests: the band itself, to measure where it put things.
    var debugBand: MediaEditorBandView { band }
    /// Internal for tests: whether the picture runs under the bars.
    var debugCanvasIgnoresInsets: Bool { canvas.contentInsetAdjustmentBehavior == .never }
    /// Internal for tests: the momentary bar the timeline mode puts opposite it.
    var debugActionBar: IconActionBar { actionBar }
    /// Internal for tests: the trailing item, through ITS OWN action.
    ///
    /// ⚠️ **DISPATCHED, NOT COPIED.** Calling `goNext()` or `finishComposing()`
    /// from here would test this line and not the bar — and WHICH routine the
    /// trailing item is carrying is the whole subject. `performWithSender`
    /// runs the `UIAction` the item was built with, which is what a finger on
    /// it runs.
    func debugTapTheTrailingItem() {
        navigationItem.rightBarButtonItems?.first?.primaryAction?.performWithSender(nil, target: nil)
    }
    /// Internal for tests: whether the screen is holding the current page's
    /// picture — which is the poster the track borrows.
    var debugHasSourcePicture: Bool { lastSource != nil }
    /// Internal for tests: the band seam a mode would use, so a test can put
    /// something in the band that is not one of this screen's own tenants.
    func debugShowInBand(_ accessory: UIView?) { showInBand(accessory) }
    /// Internal for tests: the crop stored for an item, defaulting as the screen does.
    func debugCrop(for id: String) -> MediaCrop { edits(for: id).crop }
    /// Internal for tests: paging the canvas the way a swipe does, settle
    /// included — the canvas cannot be dragged without a finger.
    func debugScrollToPage(_ index: Int) {
        canvas.setContentOffset(
            CGPoint(x: canvas.bounds.width * CGFloat(index), y: 0), animated: false
        )
        // ⚠️ **THE CELL MUST EXIST BEFORE THE SETTLE IS ANNOUNCED.** A real
        // scroll lays pages out as it goes, so by the time UIKit calls
        // `scrollViewDidEndDecelerating` the settled page is on screen. Setting
        // an offset outright skips that, and anything the settle does through
        // `cellForItem(at:)` — starting the page's video, for one — silently
        // found nothing and did nothing. The tests read as a dead feature.
        canvas.layoutIfNeeded()
        scrollViewDidEndDecelerating(canvas)
    }

    /// Internal for tests: whether the picture of `id` is travelling to a new
    /// place rather than standing in it — a curve is on its layer.
    func debugPictureIsMoving(for id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaEditorPageCell
        else { return false }
        return page.debugPictureIsMoving
    }

    /// Internal for tests: where the picture sits on screen, in the editor's own
    /// coordinates — the only thing that can say whether a fitted picture is
    /// centred between the chrome or hanging behind it.
    func debugPictureFrame(for id: String) -> CGRect {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaEditorPageCell
        else { return .zero }
        return page.convert(page.debugPictureFrame, to: view)
    }

    /// Internal for tests: the size of the picture currently on a page.
    func debugPageImageSize(for id: String) -> CGSize {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return .zero }
        let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
        return (page as? MediaEditorPageCell)?.debugPictureSize ?? .zero
    }
    /// Internal for tests: the order the trailing side spells, edge inwards.
    var debugTrailingBarItems: [UIBarButtonItem] { navigationItem.rightBarButtonItems ?? [] }
    /// Internal for tests: the order the leading side spells, after the chevron.
    var debugLeadingBarItems: [UIBarButtonItem] { navigationItem.leftBarButtonItems ?? [] }
    /// Internal for tests: whether the canvas is the thing being looked at.
    var debugCanvasIsShowing: Bool { !canvas.isHidden }
    /// Internal for tests: how visible the canvas is, which `isHidden` cannot say.
    var debugCanvasAlpha: CGFloat { canvas.alpha }
    /// Internal for tests: whether the canvas can still be paged.
    var debugCanvasScrolls: Bool { canvas.isScrollEnabled }
    /// Internal for tests: whether the sheet has been told it cannot be dismissed.
    var debugSheetIsPinned: Bool { navigationController?.isModalInPresentation ?? false }
}
#endif
