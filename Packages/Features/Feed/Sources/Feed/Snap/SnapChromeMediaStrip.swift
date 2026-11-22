import DesignSystem
import LaunchArguments
import MediaCore
import UIKit

/// What the media strip's overlays ask of the chrome (#2521): the strip they
/// stand on, the views a scrub fades, and the view they are drawn in.
@MainActor
protocol SnapChromeMediaStripHost: UIView {
    var mediaPageBar: SnapMediaPageBarView { get }
    var scrubFadedViews: [UIView] { get }
}

/// The page strip's instruments, out of `SnapChromeView` (#2521): the scrub
/// card over a clip's bar, the filmstrip a finger browses a carousel with
/// (#1734), the page's talk fading under either, and the strip's setters
/// and callbacks. The strip itself is the chrome's, laid out with the
/// caption; this collaborator is built in the chrome's `init` with it.
@MainActor
final class SnapChromeMediaStrip {
    private unowned let host: any SnapChromeMediaStripHost

    /// The card a thumb dragging a clip's bar points with — the frame it would
    /// land on and the time it would land at. Frame-managed and out of the
    /// layout entirely: it exists only during a gesture, it follows the thumb,
    /// and nothing else on this screen may move because it appeared.
    let scrubPreview = SnapScrubPreviewView()
    /// The pages' previews while a finger browses the strip (#1734).
    let browseStrip = SnapBrowseStripView()

    /// The clip's length, kept because the card's readout is a time and the
    /// strip speaks in fractions.
    private var clipSeconds: Double = 0

    init(host: any SnapChromeMediaStripHost) {
        self.host = host
    }

    /// The card and the filmstrip over the strip, and the strip's gestures
    /// wired to them — the chrome's `buildLayout`, in its turn.
    func installOverlays() {
        scrubPreview.translatesAutoresizingMaskIntoConstraints = true
        scrubPreview.frame = CGRect(origin: .zero, size: scrubPreview.totalSize)
        scrubPreview.onShapeChange = { [weak self] in
            guard let self, let last = lastScrubPreview else { return }
            placeScrubPreview(at: last.x)
        }
        host.addSubview(scrubPreview)
        host.mediaPageBar.onScrubPreview = { [weak self] preview in
            self?.showScrubPreview(preview)
        }
        host.addSubview(browseStrip)
        host.mediaPageBar.onBrowseBegan = { [weak self] page in self?.beginBrowse(at: page) }
        host.mediaPageBar.onBrowse = { [weak self] page in self?.browse(to: page) }
        host.mediaPageBar.onBrowseEnded = { [weak self] page in self?.endBrowse(at: page) }
    }

    /// How many media pages the post has, and which one is showing. A count
    /// below two hides the indicator — a readout for a single photograph is
    /// furniture answering a question nobody asked.
    func setMediaPageCount(_ count: Int, current: Int, clipPages: Set<Int> = []) {
        mediaPosition = CGFloat(current)
        // Nothing else moves for it (#2252): the strip reserves no height,
        // so a count arriving re-seats nothing.
        host.mediaPageBar.configure(count: count, current: current, clipPages: clipPages)
        #if DEBUG
        runBrowseQAIfAsked(count: count)
        #endif
    }

    #if DEBUG
    /// QA (#1734): `-strip-browse <fraction>` holds a finger on the first
    /// carousel's strip at that fraction of its width, to film the browse
    /// (`-strip-browse-release` lets go after 4 s).
    private static var ranBrowseQA = false
    private func runBrowseQAIfAsked(count: Int) {
        let arguments = ProcessInfo.processInfo.arguments
        guard count >= 2, !Self.ranBrowseQA, let share = LaunchArgument.stripBrowse.doubleValue(in: arguments) else { return }
        Self.ranBrowseQA = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let bar = host.mediaPageBar
            bar.debugScrub(.began, atX: 2)
            bar.debugScrub(.changed, atX: 2 + SnapMediaPageBarView.debugTravelThreshold + 1)
            bar.debugScrub(.changed, atX: bar.bounds.width * CGFloat(share))
            // `-strip-browse-release`: and lets go 4 s later.
            guard LaunchArgument.stripBrowseRelease.isPassed(in: arguments) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                bar.debugScrub(.ended, atX: bar.bounds.width * CGFloat(share))
            }
        }
    }
    #endif

    #if DEBUG
    var debugScrubPreview: SnapScrubPreviewView { scrubPreview }
    func debugScrubPreviewFrame() -> CGRect { scrubPreview.frame }
    #endif

    /// Moves the mark as the viewer pages. Separate from the count because this
    /// runs on every scroll callback of a carousel under a finger.
    func setMediaPage(_ page: Int) {
        host.mediaPageBar.setCurrent(page)
    }

    /// The carousel's position in fractional pages, straight through to the
    /// strip: width and ink are read off it, so the strip reflows for the whole
    /// gesture rather than at the crossing. See `SnapMediaPageBarView`.
    func setMediaScrollPosition(_ position: CGFloat) {
        mediaPosition = position
        host.mediaPageBar.setPosition(position)
    }

    /// The watched clip is loading or not (#1537): the bar's pulse.
    func setMediaLoading(_ loading: Bool) {
        host.mediaPageBar.setLoading(loading)
    }

    /// How far through the clip the page is showing, when there is one whose
    /// length is known — the strip draws it inside the segment it has grown
    /// into a bar.
    func setMediaPlayhead(_ fraction: Double?, seconds: Double = 0) {
        clipSeconds = seconds
        host.mediaPageBar.setPlayhead(fraction)
    }

    /// A frame the scrub card is pointing at. There is no "nothing new" here:
    /// a decode that failed leaves the last frame standing — see
    /// `SnapScrubPreviewView.setPicture`.
    func setScrubPreviewPicture(_ image: CGImage) {
        scrubPreview.setPicture(image)
    }

    /// Whether a frame is on its way, so the card can stand in for one it has
    /// not got.
    func setScrubPreviewLoading(_ loading: Bool) {
        scrubPreview.setLoading(loading)
    }

    /// Asked for a frame at a moment in the clip, or told the gesture is over.
    /// The CELL owns playback, so the request travels out.
    var onScrubPreviewRequested: ((Double?) -> Void)?

    /// Puts the card over the thumb and tells the host what to fetch.
    ///
    /// ⚠️ CLAMPED TO THE STRIP'S ENDS, not to the screen: the card is a label
    /// on the strip, and one that ran past them would point at nothing. The
    /// strip ends 12 pt in on both sides (#2291), so the card stays on screen.
    private func showScrubPreview(_ preview: (fraction: Double, x: CGFloat)?) {
        guard let preview else {
            scrubPreview.hide()
            setScrubFocus(false)
            onScrubPreviewRequested?(nil)
            return
        }
        setScrubFocus(true)
        lastScrubPreview = preview
        // The clip's own shape (#1724): the page the viewer is on.
        let page = Int(mediaPosition.rounded())
        if pageAspects.indices.contains(page) { scrubPreview.aspect = pageAspects[page] }
        placeScrubPreview(at: preview.x)
        // ⚠️ ABOVE EVERYTHING, and re-stated on every show. The card is built
        // with the strip, and the surfaces added after it — the shortcut wheel,
        // the boost anchor, the subtitle zone, the comment empty state — are
        // its own siblings, so a card added once sits UNDER the comment
        // surfaces it is meant to point over. Reported exactly that way.
        host.bringSubviewToFront(scrubPreview)
        scrubPreview.show(fraction: preview.fraction, seconds: clipSeconds)
        onScrubPreviewRequested?(preview.fraction)
    }

    /// The last point the card was asked over, for a re-place after a reshape.
    private var lastScrubPreview: (fraction: Double, x: CGFloat)?
    /// Each page's declared shape, width / height (#1724) — `configure`'s.
    var pageAspects: [CGFloat] = []
    /// The carousel's position in pages — which page's shape the card takes.
    private var mediaPosition: CGFloat = 0

    /// Sizes the card to its shape and puts it over `x` along the strip.
    private func placeScrubPreview(at x: CGFloat) {
        let size = scrubPreview.totalSize
        let alongTheStrip = host.mediaPageBar.frame.minX + x
        let leftMost = host.mediaPageBar.frame.minX + size.width / 2
        let rightMost = host.mediaPageBar.frame.maxX - size.width / 2
        scrubPreview.frame = CGRect(
            x: min(max(alongTheStrip, leftMost), rightMost) - size.width / 2,
            y: host.mediaPageBar.frame.minY - size.height - Spacing.sm,
            width: size.width, height: size.height
        )
    }

    // MARK: - Browsing the pages (#1734)

    /// The carousel's previews: each page's thumbnail, and which are clips.
    func setMediaPreviews(thumbnails: [URL?], videoPages: Set<Int>, pipeline: ImagePipeline?) {
        browseStrip.configure(thumbnails: thumbnails, videoPages: videoPages, pipeline: pipeline)
    }

    /// The clip the post is playing on `page`, mirrored into its preview while
    /// browsing (nil: none) — the CELL owns playback and hands the surface.
    func setBrowseLiveSurface(_ view: UIView?, page: Int) {
        browseStrip.setLiveView(view, page: page)
    }

    /// A finger started sliding through the pages: the page's talk fades as
    /// it does under a clip's scrub, and the previews come up over the strip.
    var onMediaBrowseBegan: (() -> Void)?
    /// The page under the finger changed — the CELL turns the carousel.
    var onMediaBrowse: ((Int) -> Void)?
    /// The finger let go on this page.
    var onMediaBrowseEnded: ((Int) -> Void)?

    private func beginBrowse(at page: Int) {
        setScrubFocus(true)
        placeBrowseStrip()
        // Above everything, re-stated on every show — the scrub card's rule.
        host.bringSubviewToFront(browseStrip)
        browseStrip.show(selecting: page, anchorX: browseAnchor(page))
        onMediaBrowseBegan?()
    }

    private func browse(to page: Int) {
        browseStrip.select(page, anchorX: browseAnchor(page))
        onMediaBrowse?(page)
    }

    private func endBrowse(at page: Int) {
        browseStrip.hide()
        setScrubFocus(false)
        onMediaBrowseEnded?(page)
    }

    /// The filmstrip across the chrome's width, its counter on the strip's
    /// line — the row takes the caption's room above it, faded for the
    /// browse — as the reference app lays it out.
    private func placeBrowseStrip() {
        let bar = host.mediaPageBar.frame
        let height = SnapBrowseStripView.height
        let counterMid = height - SnapBrowseStripView.counterHeight / 2
        browseStrip.frame = CGRect(x: 0, y: bar.midY - counterMid, width: host.bounds.width, height: height)
    }

    /// Where the chosen tile stands: over the finger's slot on the strip, in
    /// the filmstrip's space.
    private func browseAnchor(_ page: Int) -> CGFloat {
        host.mediaPageBar.frame.minX + host.mediaPageBar.browseSlotCenter(page) - browseStrip.frame.minX
    }

    #if DEBUG
    var debugBrowseStrip: SnapBrowseStripView { browseStrip }
    #endif

    // MARK: - The scrub's focus

    /// What each faded view was worth before the scrub took it, so the fade
    /// back RESTORES rather than asserts.
    ///
    /// ⚠️ Restoring to 1 would be a bug with a long tail: several of these are
    /// faded by someone else for their own reasons — the rail rides the
    /// pull-down's progress, the band and the caption fade through an
    /// engagement — and a scrub that ended by setting them all to full would
    /// hand back a page brighter than the one it borrowed.
    private var scrubFadeRestore: [(view: UIView, alpha: CGFloat)] = []

    /// Fades the page's talk out under a scrub, and back when it ends.
    ///
    /// A viewer dragging along a clip's bar is looking for a MOMENT in the
    /// picture, and the card showing it is a small thing over a page still
    /// crowded with everything else. So the page recedes for the length of the
    /// gesture and comes back when the thumb lifts.
    func setScrubFocus(_ focused: Bool, animated: Bool = true) {
        // Guarding on the ledger, not on a flag: entering twice would capture
        // the faded values as the ones to restore, which is how a fade becomes
        // permanent.
        guard focused == scrubFadeRestore.isEmpty else { return }
        let restoring = scrubFadeRestore
        if focused {
            scrubFadeRestore = host.scrubFadedViews.map { (view: $0, alpha: $0.alpha) }
        } else {
            scrubFadeRestore = []
        }
        let targets: [(view: UIView, alpha: CGFloat)] = focused
            ? scrubFadeRestore.map { (view: $0.view, alpha: 0) }
            : restoring
        let apply = { for target in targets { target.view.alpha = target.alpha } }
        guard animated else { return apply() }
        UIView.animate(
            withDuration: Self.scrubFocusDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: apply
        )
    }

    /// Long enough to read as a fade, short enough that a quick tap-and-drag on
    /// a bar does not spend its first moments in a dissolve.
    static let scrubFocusDuration: TimeInterval = 0.2

    #if DEBUG
    /// What the page's talk is worth right now — the question a spec asks to
    /// prove the scrub took it away and gave it back.
    var debugScrubFadedAlphas: [CGFloat] { host.scrubFadedViews.map(\.alpha) }
    #endif

    /// The viewer dragged along a clip's bar. The CELL owns playback, so the
    /// request travels out rather than the chrome reaching for a player.
    var onMediaSeekRequested: ((Double) -> Void)? {
        get { host.mediaPageBar.onSeekRequested }
        set { host.mediaPageBar.onSeekRequested = newValue }
    }

    /// A drag took hold of the clip's playhead — see `SnapMediaPageBarView
    /// .onScrubBegan`.
    var onMediaScrubBegan: (() -> Void)? {
        get { host.mediaPageBar.onScrubBegan }
        set { host.mediaPageBar.onScrubBegan = newValue }
    }

    /// The drag let go, at this fraction (nil on a cancel).
    var onMediaScrubEnded: ((Double?) -> Void)? {
        get { host.mediaPageBar.onScrubEnded }
        set { host.mediaPageBar.onScrubEnded = newValue }
    }


    /// The viewer asked for a page by touching the indicator. The CELL owns the
    /// carousel, so the request travels out rather than the chrome reaching in.
    var onMediaPageRequested: ((Int) -> Void)? {
        get { host.mediaPageBar.onPageRequested }
        set { host.mediaPageBar.onPageRequested = newValue }
    }

    /// The indicator's scrub, passed up so the screen's own pans can yield to
    /// it. See `MediaPageIndicatorView.scrubGesture`.
    var mediaScrubGesture: UIGestureRecognizer { host.mediaPageBar.scrubGesture }
}
