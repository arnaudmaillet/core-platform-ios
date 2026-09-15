// `AVURLAsset` — the trim strip asks the FILE how long it is rather than
// trusting the item's declared duration. See `refreshTimelineTrack`.
import AVFoundation
import DesignSystem
// `VideoRenderView` — the surface a picked clip plays in, one page at a time.
// See `MediaPreviewPlayer` for why this screen owns its player rather than
// borrowing the feed's.
import MediaPlayback
import UIKit

/// Whether a picture fills its frame and is cropped, or is shown whole with the
/// ground around it.
///
/// ⚠️ **MODULE SCOPE, BECAUSE THE CHOICE OUTLIVES THE EDITOR.** It was nested in
/// `MediaEditorViewController` while the editor was the only screen that cared.
/// The new-post screen's thumbnails have to honour the same decision — a picture
/// the author chose to show whole must not come back cropped one screen later —
/// so the type travels with the media.
///
/// ⚠️ **THE GLYPH OFFERS THE OTHER STATE.** A button is named for what it will
/// do, not for what is: while the picture FILLS, the button shows the inward
/// arrows that will shrink it to fit. Drawing the current state instead is the
/// classic way to make a toggle read backwards.
enum ContentFit {
    case fill, fit

    var mode: UIView.ContentMode { self == .fill ? .scaleAspectFill : .scaleAspectFit }
    var toggled: ContentFit { self == .fill ? .fit : .fill }
    var symbolName: String {
        self == .fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }
    var actionName: String { self == .fill ? "Fit the picture" : "Fill the screen" }
}

/// The second step of posting media: what was chosen, full-bleed, with the
/// editing categories beneath it.
///
/// ```
/// ┌──────────────────────────┐
/// │ ‹ Save draft     ⤡  Next │
/// │                          │
/// │                          │
/// │      the media, filling  │
/// │      the whole canvas    │
/// │                          │
/// │                          │
/// │ ⊕ Add a song  Effects ░░ │
/// └──────────────────────────┘
/// ```
///
/// **Several items page sideways, one to a screen**, in the order the picker
/// handed them over — so nothing here has to ask which of them is "the" one
/// being edited.
///
/// ⚠️ **NOTHING HERE EDITS ANYTHING YET, AND THAT IS DELIBERATE.** The category
/// pills select and drive nothing, and "Add a song" has no destination: this
/// repository holds no audio seam of any kind — no track model, no picker, no
/// mock, nothing behind `CoreNetworking`. Drawing the control and saying so in
/// the source is the precedent Feed's own sound pill sets. Inventing a seam to
/// put behind it would be inventing a product decision.
///
/// ⚠️ **A VIDEO DRAWS ITS POSTER FRAME, NOT PLAYBACK.** The seam can hand over a
/// clip's file now (`MediaLibraryReading.videoFile(for:)`), but no player is
/// injected into this package — `UploadFeatureBuilder.init` takes a composer and
/// the text-post screens, nothing else — so a chosen video still shows the same
/// frame the grid showed it by. No play glyph is laid over it, on purpose: a
/// button that promises playback and does nothing is worse than a still that
/// promises nothing.
///
/// **The sheet becomes the whole screen here.** The flow is a stack inside a
/// page sheet that rests on a single album row, and a canvas one row tall is not
/// a canvas — so this screen states the detent it needs on the way in, and the
/// picker takes its own back on the way out.
final class MediaEditorViewController: UIViewController {
    private enum Metrics {
        /// What the canvas is worth before it has been laid out once — the
        /// narrowest phone this app is built for. Only a first thumbnail request
        /// can ever land on it.
        static let canvasFallback = CGSize(width: 375, height: 812)

        /// How long the picture takes to settle into the crop frame and back.
        /// Short enough to feel like a response, long enough to be followed.
        static let cropTransition: TimeInterval = 0.28

        /// How much larger the editing surface starts, so entering reads as the
        /// picture settling in rather than appearing. A few percent: any more and
        /// it reads as a zoom the author did not ask for.
        static let cropEntryScale: CGFloat = 1.06
    }


    /// One editing mode the strip offers.
    ///
    /// ⚠️ **ICONS, NOT WORDS — AND THAT IS WHAT MAKES FIVE OF THEM POSSIBLE.**
    /// Four titles already overran this toolbar: the fourth sat off the trailing
    /// edge and could not be tapped at all, which is why `-upload-category` had to
    /// exist to reach it. A symbol is a fixed 36pt square, so five fit in 196pt
    /// where four words did not fit in any width this bar has.
    struct Category {
        let title: String
        let symbol: String
    }

    /// What the strip at the foot of the screen offers.
    static let categories: [Category] = [
        Category(title: "Effects", symbol: "wand.and.stars"),
        Category(title: "Text", symbol: "textformat"),
        Category(title: "Stickers", symbol: "face.smiling"),
        Category(title: "Filters", symbol: "camera.filters"),
        // Crop and straighten are one mode and one icon: the viewer reaches for
        // the same tool to square a horizon and to cut a border away.
        Category(title: "Crop", symbol: "crop.rotate"),
        // ⚠️ `timeline.selection` EXISTS — ASKED OF THE RUNTIME, NOT ASSUMED.
        // A name that does not resolve draws an empty capsule and nothing
        // errors; this strip shipped one once
        // (`arrow.trianglehead.counterclockwise.rotate`). The plist lookups are
        // unreliable across bundles; `UIImage(systemName:)` inside the simulator
        // is the instrument that cannot be wrong.
        Category(title: "Trim", symbol: "timeline.selection")
    ]

    private let items: [MediaLibraryItem]
    private let itemsByID: [String: MediaLibraryItem]
    private let library: any MediaLibraryReading
    /// Plays the settled page's clip. Owned by this screen, pool and all.
    private let preview: any MediaVideoPreviewing
    /// Which item the preview is currently bound to, if any — so a settle that
    /// lands back on the same page does not restart it.
    private var playingID: String?
    /// What "Next" hands the media to. The step that writes a caption and
    /// publishes is still a stand-in, so the builder passes a screen saying so.
    /// ⚠️ CARRIES EVERY DECISION THE AUTHOR MADE — see `MediaEdits`. The step
    /// after this one draws the same pictures as thumbnails, where a picture the
    /// author chose to show WHOLE must not reappear cropped, and it is where the
    /// crop and the look are baked into the full-resolution image that is
    /// uploaded.
    private let onNext: ([MediaLibraryItem], [String: MediaEdits]) -> UIViewController

    /// ⚠️ A `CarouselCollectionView`, NOT A PLAIN ONE: on its first page it
    /// declines a rightward drag so the stack's back-swipe can carry the screen
    /// back. See `CarouselBackSwipe`.
    private var canvas: CarouselCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    /// ⚠️ **NOT `PagedTabBar`, AND THE DIFFERENCE IS THE CONTRACT.** That bar is
    /// built for tabs standing over a pager: a drag publishes a fractional page
    /// and the PAGER answers where it lands. Seven screens are right to use it.
    /// This one has no pager — its categories switch a mode, they do not turn a
    /// page — so that contract had nothing on the other end, and the screen spent
    /// a release driving the bar by hand and still needing a tap after every
    /// slide. `IconSelectorBar` is the same gesture with the contract this screen
    /// actually has.
    private let categoryBar = IconSelectorBar(
        items: MediaEditorViewController.categories.map {
            IconSelectorBar.Item(symbolName: $0.symbol, accessibilityLabel: $0.title)
        }
    )

    private lazy var nextItem = UIBarButtonItem(
        title: "Next",
        primaryAction: UIAction { [weak self] _ in self?.goNext() }
    )

    /// Undoes every cut and every degree on the picture in front of the author.
    ///
    /// ⚠️ **ON THE LEADING SIDE, AFTER "Save draft".** It began as a third button
    /// in the band beside the quarter turn and the row of shapes — which put "undo
    /// everything" a few points from "hold the box to 4:5", two acts of very
    /// different weight in one row — and then briefly took the fill/fit glyph's
    /// slot on the trailing side. It sits with the other things that act on the
    /// whole screen rather than on the picture: `[‹][Save draft][undo] ⋯ [Next]`,
    /// leaving the trailing side to the one action that moves the flow forward.
    /// ⚠️ **`arrow.trianglehead.counterclockwise.rotate` DOES NOT EXIST, AND A
    /// SYMBOL THAT DOES NOT EXIST IS AN EMPTY BUTTON, NOT AN ERROR.**
    /// `UIImage(systemName:)` answers nil and the bar draws a blank capsule that
    /// still takes taps — shipped, it reads as a rendering bug on someone's phone.
    /// This SDK's catalogue holds `arrow.trianglehead.counterclockwise` (this one,
    /// the undo arrow) and `arrow.trianglehead.counterclockwise.rotate.90`, which
    /// means "turn by ninety degrees" and is the QUARTER-TURN button's job, not
    /// undo's. `everyGlyphInTheCropToolsExists` is what stops the next one being
    /// invisible.
    private lazy var resetItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.counterclockwise"),
            primaryAction: UIAction { [weak self] _ in self?.resetTheCurrentMode() }
        )
        item.accessibilityLabel = "Undo every change in this mode"
        return item
    }()

    /// ⚠️ **ONE ARROW, WHOSE MEANING IS THE MODE THE AUTHOR IS IN.** Crop resets
    /// the rectangle and the angle; the timeline resets the cut. Two bar items
    /// would put two undo arrows a few points apart, each undoing a different
    /// thing, and nothing on screen to say which is which.
    private func resetTheCurrentMode() {
        if band.content === timelineTrack {
            resetTimeline()
        } else {
            resetCrop()
        }
    }

    private func resetTimeline() {
        guard let id = currentItemID else { return }
        change(id) { $0.timeline = .whole }
        timelineTrack.configure(duration: trackSeconds, timeline: .whole)
        refreshResetItem()
    }

    /// The arrow is dead when there is nothing to undo — a control that reaches
    /// nothing has to say so.
    /// ⚠️ **ENABLED ONLY WHERE THE TAP CAN ACT, AND IT WAS ENABLED EVERYWHERE.**
    /// `resetCrop` begins `guard let id = croppingID`, and `croppingID` is set in
    /// `enterCrop` and cleared in `exitCrop` — so outside the crop surface the
    /// arrow drew ENABLED over a photograph carrying a crop and did nothing at
    /// all when tapped. That is the shape this screen has removed three times
    /// now: a control that reaches nothing. It used to be hidden by living only
    /// in the crop bar; standing in the bar permanently, it has to say so itself.
    private func refreshResetItem() {
        guard let id = currentItemID else {
            resetItem.isEnabled = false
            return
        }
        let edited = edits(for: id)
        if band.content === timelineTrack {
            resetItem.isEnabled = MediaTimelining.cuts(
                edited.timeline, withinSource: trackSeconds
            )
        } else {
            resetItem.isEnabled = croppingID != nil && !edited.crop.isUntouched
        }
    }

    private func resetCrop() {
        guard let id = croppingID else { return }
        cropRatios[id] = .free
        cropSurface.reset()
        cropTools.adopt(angle: 0, ratio: .free)
    }

    /// What the author has decided about each picture: how it is laid, the look
    /// it wears, and what is kept of it.
    ///
    /// ⚠️ **PER ITEM, NOT PER SCREEN.** Every one of those is a decision about
    /// ONE picture: a portrait shot and a landscape one in the same carousel want
    /// opposite answers, and a single screen-wide value would make choosing for
    /// one of them undo the choice for the other.
    ///
    /// ⚠️ **CARRIED TO THE PUBLISH PATH, AND BAKED THERE.** `onNext` hands this
    /// on, and the finalisation screen applies the crop and the look to the
    /// FULL-RESOLUTION picture it uploads — not to the preview. What is chosen
    /// here is therefore in the post, which is why nothing may quietly drop it.
    ///
    /// ⚠️ **AND ONLY WHAT WAS ACTUALLY CHOSEN IS IN HERE.** Reading with
    /// `edits[id, default: .untouched]` would write an entry for every page that
    /// merely scrolled past, and "nothing was changed, so nothing is carried"
    /// would stop being true — `nextHandsOnWhatWasChosenInTheOrderItWasChosen`
    /// pins it. Read through `edits(for:)`, write through `change(_:_:)`.
    private var edits: [String: MediaEdits] = [:]

    private func edits(for id: String) -> MediaEdits { edits[id] ?? .untouched }

    /// The canvas-sized picture the library last answered with, undressed and
    /// uncut.
    ///
    /// ⚠️ **THIS IS WHAT MAKES AN EDIT LAND AT ONCE.** Leaving crop mode used to
    /// ask the library for the picture all over again before it could paint the
    /// result, so the canvas showed the OLD framing for as long as
    /// `PHImageManager` took to answer — a visible beat, and longer on an iCloud
    /// asset. The author has already been looking at this exact render inside the
    /// crop surface; keeping it means the cut can be drawn in the same turn the
    /// mode is left.
    ///
    /// ⚠️ **ONE ENTRY, NOT A CACHE.** A canvas-sized render is ~1.4MB, and this
    /// flow carries up to twenty pictures; keeping them all would be 28MB held for
    /// a convenience. Edits happen on the picture in front of the author, so one
    /// entry covers every case that matters and a swipe simply falls back to the
    /// asynchronous path that has always been there.
    private var lastSource: (id: String, image: UIImage)?

    private func remember(_ image: UIImage?, for id: String) {
        guard let image else { return }
        lastSource = (id, image)
    }

    /// How many renders are in flight, and the spinner that eventually says so.
    ///
    /// ⚠️ **A COUNT, NOT A FLAG.** Two renders can overlap — a look chosen while a
    /// crop is still drawing — and a flag would let the first one to finish stop
    /// the indicator for both.
    private var rendersInFlight = 0

    private let busy: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .label
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    /// ⚠️ **THE SPINNER WAITS BEFORE IT APPEARS, AND MOST OF THE TIME IT NEVER
    /// DOES.** A render from the held picture finishes in a few milliseconds; a
    /// spinner shown the instant work begins would flash on every tap of the
    /// selector, which reads worse than the wait it is reporting.
    private static let spinnerDelay: TimeInterval = 0.15

    private func beginRender() {
        rendersInFlight += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinnerDelay) { [weak self] in
            guard let self, rendersInFlight > 0 else { return }
            busy.startAnimating()
        }
    }

    private func endRender() {
        rendersInFlight = max(0, rendersInFlight - 1)
        if rendersInFlight == 0 { busy.stopAnimating() }
    }

    /// Draws a picture as the author left it, off the main thread, and hands it to
    /// its page when it is ready.
    ///
    /// ⚠️ **OFF THE MAIN ACTOR, AND THAT IS THE WHOLE POINT.** Cutting and
    /// filtering a canvas-sized picture is a Core Image round trip. Doing it in the
    /// same turn as the tap made the selector's pill stutter as it travelled: the
    /// animation and the render were competing for one thread, and the mode felt
    /// heavy. Reported from a device. The work is the same work — it simply no
    /// longer happens where the animation lives.
    private func render(_ source: UIImage, as chosen: MediaEdits, for id: String) {
        beginRender()
        Task.detached(priority: .userInitiated) { [weak self] in
            let drawn = Self.draw(source, as: chosen)
            await MainActor.run {
                guard let self else { return }
                // ⚠️ RE-READ AT LANDING: two renders can be in flight and whichever
                // lands last must paint what is chosen NOW, not what was chosen when
                // it started. A render that has been overtaken is simply redone.
                if self.edits(for: id) == chosen {
                    self.show(drawn, for: id)
                } else {
                    self.render(source, as: self.edits(for: id), for: id)
                }
                self.endRender()
            }
        }
    }

    /// ⚠️ `nonisolated`, so it may run anywhere: everything it touches is a value
    /// or a renderer that documents itself as thread-safe.
    nonisolated private static func draw(_ source: UIImage, as chosen: MediaEdits) -> UIImage {
        chosen.applied(to: source)
    }

    /// ⚠️ AN ENTRY THAT SAYS NOTHING IS WORSE THAN NO ENTRY: it makes "was this
    /// picture edited?" answerable two ways. Undoing every change removes the
    /// entry rather than storing a neutral one.
    private func change(_ id: String, _ mutate: (inout MediaEdits) -> Void) {
        var value = edits[id] ?? .untouched
        mutate(&value)
        edits[id] = value.isUntouched ? nil : value
    }

    /// The row of looks the band holds while "Filters" is the chosen category.
    /// Built once, because rebuilding it per selection would re-render nine
    /// thumbnails for a band that is merely being reopened.
    private lazy var filterRow: MediaFilterRowView = {
        let row = MediaFilterRowView()
        row.onPick = { [weak self] filter in
            guard let self, let id = self.currentItemID else { return }
            self.applyFilter(filter, to: id)
        }
        return row
    }()

    /// Which glyph the bar is currently wearing, so the item is only re-stated
    /// when it actually changes — see `updateFitItem(animated:)`.
    private var shownFit: ContentFit = .fill

    /// Which of several media is showing. Hides itself for a single one.
    private let pageDots = MediaPageDotsView()

    /// The reserved strip an editing control is put into — see
    /// `MediaEditorBandView`. It holds the row of looks while "Filters" is the
    /// chosen category, and collapses to nothing otherwise.
    private let band = MediaEditorBandView()

    /// The dissolve the chrome sits on: clear where it begins, full material at
    /// the foot of the screen, so the picture runs on underneath and merely loses
    /// definition as it passes behind the controls.
    ///
    /// ⚠️ **IT IS NEVER HIDDEN — THE TOP ANCHOR IS THE DIAL.** The picker learned
    /// this on its own copy: an earlier cut there set `isHidden` and took the
    /// whole band away instead of shortening it. Here the two constraints below
    /// swap, and the view stays.
    private let backdrop = ProgressiveBlurView()

    /// Where the dissolve begins when the band is holding something: the band's
    /// own top edge, so the ramp starts exactly where the controls do.
    private var backdropFromBand: NSLayoutConstraint!

    /// And where it begins when the band is empty: the top of the toolbar.
    ///
    /// ⚠️ **THESE ARE NOT THE SAME POINT, WHICH IS WHY THERE ARE TWO.** An empty
    /// band collapses to zero height at `safeArea.bottom - Spacing.sm`, so hanging
    /// the dissolve from `band.topAnchor` alone would start it 8pt above the
    /// toolbar rather than at it.
    private var backdropFromChrome: NSLayoutConstraint!

    /// What the toolbar appearance was before this screen borrowed it. The
    /// toolbar belongs to the STACK, and the picker underneath draws its album
    /// strip in the same one.
    private var restoreToolbar: (() -> Void)?

    #if DEBUG
    /// Guards `-upload-post` against firing twice: `viewDidAppear` runs again
    /// every time the finalisation screen is popped back off this one.
    private var hasAutoAdvanced = false

    /// The same guard for `-upload-category`, which would otherwise reopen the
    /// band on every return from the finalisation screen.
    private var hasSelectedDebugCategory = false

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
    #endif

    /// ⚠️ DRAWN, AND WIRED TO NOTHING — see the type comment. There is no audio
    /// seam in this repository for it to reach. The same control the text-post
    /// composer uses, which is why it lives in DesignSystem.
    private let soundPill = SoundPillView(title: "Add a song", neverTruncates: true)

    /// ⚠️ DRAWN AND INERT TOO, and for a nearer reason: media drafts do not
    /// exist. `MediaDraftsViewController` is an empty list waiting for the
    /// notion, so there is nothing for this to save into yet.
    /// ⚠️ **AN ICON, NOT THE WORDS "Save draft" — AND THE REASON IS THE BAR'S
    /// WIDTH BUDGET.** A navigation bar lays its leading items out from the
    /// chevron inwards and collapses what will not fit into a `•••` overflow;
    /// `navbar-leading-selector-collapse` records this screen family losing a
    /// control to exactly that on an SE. Two words cost more than sixty points
    /// beside a chevron and a reset arrow, which is more than a small phone has
    /// to give. `square.and.arrow.down.badge.clock` is the system's own drawing
    /// for "put this away for later" and was verified against the RUNTIME, not a
    /// catalogue — a symbol that does not exist draws an empty capsule that still
    /// takes taps, which reads as a rendering fault on somebody's phone.
    private lazy var saveDraftItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.down.badge.clock"),
            style: .plain, target: nil, action: nil
        )
        item.accessibilityLabel = "Save draft"
        return item
    }()

    init(
        items: [MediaLibraryItem],
        library: any MediaLibraryReading,
        preview: any MediaVideoPreviewing = MediaPreviewPlayer(),
        onNext: @escaping ([MediaLibraryItem], [String: MediaEdits]) -> UIViewController
    ) {
        self.items = items
        self.itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.library = library
        self.preview = preview
        self.onNext = onNext
        super.init(nibName: nil, bundle: nil)
        // ⚠️ THE TOP BAR BELONGS TO THE SCREEN, NOT TO ITS VIEW. A navigation
        // controller reads `navigationItem` on the way in, so a screen that has
        // been made but not yet shown would hand back a bar with nothing in it.
        // The picker's `init` carries the same note.
        configureBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ **THIS SCREEN IS ALWAYS DARK, AND IT IS THE ONE SURFACE IN THE APP
        // THAT IGNORES THE SYSTEM'S APPEARANCE ON PURPOSE.** The note here used to
        // argue the opposite — "an editor whose ground ignores the system's
        // appearance is the one surface in the app that does" — and that was the
        // right instinct applied to the wrong kind of screen. A media editor is a
        // viewing surface before it is a form: the letterbox around a fitted
        // portrait clip, the dissolve under the toolbars and the band behind the
        // film all have to be BLACK, because that is the colour that disappears
        // next to a picture. In white they frame the author's footage in
        // something the author did not shoot. Every editor the references ship —
        // CapCut, 快影, Instagram's own — is dark whatever the phone is set to.
        //
        // ⚠️ **`overrideUserInterfaceStyle`, NOT LITERAL BLACK — AND THE
        // DIFFERENCE IS EVERY INK ON THE SCREEN.** The dial, the shapes, the
        // notice and the spinner were once stated in literal white BECAUSE the
        // ground was literally black; they were all made semantic when the ground
        // started following the device (`StraightenDialView` records measuring
        // that). Forcing the TRAIT rather than the colour keeps every one of them
        // correct for free: `systemBackground` resolves black, `.label` resolves
        // white, and nothing has to be re-stated or re-measured.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .systemBackground
        // ⚠️ **THE BARS WERE INSETTING THE CANVAS, NOT MERELY COVERING IT — AND
        // A TRANSPARENT APPEARANCE ALONE DID NOT FIX IT.** Measured from a
        // screenshot: the sheet spans 63→874pt while the picture spanned only
        // 131→795, short by ~68pt at the top and ~79 at the foot — a navigation
        // bar, and a toolbar plus the home indicator. That is UIKit's opaque-bar
        // rule: `extendedLayoutIncludesOpaqueBars` is FALSE by default, so a
        // child's view is laid out BELOW an opaque bar rather than under it, and
        // `pin(to: view)` then pins to a view that already stops at the chrome.
        // Stating it here is what lets "fill" fill the window and "fit" fit the
        // window; the transparent appearance is what makes the picture visible
        // through the bars once it gets there. Both are needed.
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        configureCanvas()
        configureCategoryStrip()
        showItems()
    }

    /// The stack's toolbar carries the category strip, and a toolbar's
    /// VISIBILITY belongs to the stack rather than to a screen's `toolbarItems`
    /// — so the screen raises it itself, as the picker and the relationship
    /// lists both do.
    ///
    /// This screen used to narrow the sheet to a single detent on the way in,
    /// because the picker underneath offered a resting height of one album row
    /// and a canvas that could be dragged down to it was no canvas at all. The
    /// picker now opens to the top and stays, so there is nothing left to narrow
    /// — and with it went the restore on the way out, which had to run after the
    /// pop or it took the whole app down with a stack overflow.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        configureBarAppearance()
    }

    /// ⚠️ **CROP MODE IS UNWOUND HERE TOO, NOT ONLY WHEN ANOTHER MODE IS
    /// CHOSEN.** "Next" pushes straight from the middle of a crop, and nothing
    /// else would put the canvas, the sheet and the stack's back-swipe back — the
    /// finalisation screen would inherit a locked canvas and a sheet that cannot
    /// be pulled shut.
    /// ⚠️ **THE LINK IS INVALIDATED WHEN THE SCREEN GOES, AND THE PROXY ALONE
    /// WAS NOT ENOUGH.** The proxy's reference back is weak, so the editor can be
    /// deallocated — but the proxy's only `invalidate()` is inside `tick()`, and
    /// a PAUSED link never ticks. `setEditingAccessory` builds and schedules the
    /// link on every band change, including the one that shuts it, so opening
    /// Crop or Filters and then leaving left a link on the main run loop forever.
    /// One per editor session.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent || navigationController == nil else { return }
        followerProxy.link?.invalidate()
        followerProxy.link = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠️ BEFORE `exitCrop`, WHICH SETTLES THE CANVAS AND WOULD START IT AGAIN.
        stopPreview()
        exitCrop()
        restoreToolbar?()
        restoreToolbar = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // ⚠️ **THE MODE OUTLIVES THE SCREEN'S DISAPPEARANCE, SO IT HAS TO BE
        // REOPENED.** `viewWillDisappear` unwinds crop mode — it must, or "Next"
        // would push with the canvas locked and the sheet pinned — and stepping
        // back from the finalisation screen used to land on an editor whose pill
        // said Crop over an empty band, with no way to reopen it: selecting the
        // index the strip already rests on announces nothing.
        if selectedCategory == "Crop", !isCropping { enterCrop() }
        // The first page has never settled — nothing scrolled — so this is the
        // only moment it can start. Stepping back from the finalisation screen
        // lands here too, which is what restarts a clip the author left running.
        playSettledPage()
        #if DEBUG
        logCanvas("didAppear")
        // ⚠️ **THE FINALISATION SCREEN HAD NO SCRIPTED WAY IN.** `-upload-edit`
        // stops at this screen and `debugTapNext()` is internal-to-tests, so the
        // keyboard and the caption — both reported as broken there — could not be
        // reached in a running app at all. One flag carries the flow the last
        // step, after a beat so the push does not race this appearance.
        if ProcessInfo.processInfo.arguments.contains("-upload-post"), !hasAutoAdvanced {
            hasAutoAdvanced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.goNext()
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
           let index = Int(raw), Self.categories.indices.contains(index) {
            hasSelectedDebugCategory = true
            categoryBar.select(index)
            // ⚠️ `select(_:)` ANNOUNCES ONLY ON A CHANGE — picking the index the
            // strip already rests on sends nothing, and the band would never open.
            categoryChanged()
        }
        #endif
    }

    /// ⚠️ **THE CANVAS ALREADY RAN THE FULL WINDOW — THE BARS WERE PAINTING
    /// OVER IT.** `pin(to:)` anchors to `.edges` by default and the canvas
    /// ignores inset adjustment, so the picture has always spanned the sheet
    /// top to bottom. What stopped at the bars was the VIEW of it: an opaque
    /// bar background drawn on top. Both bars go transparent, so "fill" fills
    /// the window and "fit" fits the window, each running behind the chrome.
    ///
    /// ⚠️ **THE NAVIGATION BAR IS SET PER ITEM AND THE TOOLBAR IS NOT.** A
    /// `navigationItem` appearance is scoped to this screen and unwinds itself
    /// on the way out; a `UIToolbar`'s belongs to the STACK, and the picker
    /// underneath draws its album strip in that same toolbar — so this one is
    /// captured and put back in `viewWillDisappear`.
    private func configureBarAppearance() {
        guard let toolbar = navigationController?.toolbar, restoreToolbar == nil else { return }
        let standard = toolbar.standardAppearance
        let compact = toolbar.compactAppearance
        let scrollEdge = toolbar.scrollEdgeAppearance
        restoreToolbar = { [weak toolbar] in
            toolbar?.standardAppearance = standard
            toolbar?.compactAppearance = compact
            toolbar?.scrollEdgeAppearance = scrollEdge
        }

        let foot = UIToolbarAppearance()
        foot.configureWithTransparentBackground()
        toolbar.standardAppearance = foot
        toolbar.compactAppearance = foot
        toolbar.scrollEdgeAppearance = foot
    }

    // MARK: - The canvas

    private func configureCanvas() {
        canvas = CarouselCollectionView(frame: .zero, collectionViewLayout: Self.canvasLayout())
        canvas.backgroundColor = .clear
        canvas.addGestureRecognizer(mediaTap)
        canvas.isPagingEnabled = true
        canvas.showsHorizontalScrollIndicator = false
        // ⚠️ FULL-BLEED UNDER THE BARS TAKES THREE STATEMENTS, NOT ONE. The
        // inset adjustment would push the picture down below the navigation bar;
        // the two scroll edge effects would lay a fade over the top and the
        // bottom of it. The snap feed's full-screen media states all three, for
        // exactly this reason.
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.topEdgeEffect.isHidden = true
        canvas.bottomEdgeEffect.isHidden = true
        canvas.pin(to: view)

        // ⚠️ FULL WIDTH OF THE SHEET, NOT OF THE MARGINS. The band is a rail for
        // a horizontal scroller, and a scroller that starts inside a margin reads
        // as a short list rather than a list running off the edge. Anchored to the
        // safe area at the foot for the same reason the indicator was: the canvas
        // is full-bleed on purpose and its bottom edge is behind the home
        // indicator.
        //
        // ⚠️ ADDED BEFORE THE INDICATOR, BECAUSE `constrain(in:)` RE-PARENTS —
        // its first statement is `addSubview`, so whatever is stated last sits on
        // top. They do not overlap, but the order is stated rather than left to
        // chance; `pin(to:)` has the same bite and has cost this flow a screen
        // before.
        band.constrain(in: view) { guide in
            band.leadingAnchor.constraint(equalTo: guide.leadingAnchor)
            band.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
            band.bottomAnchor.constraint(
                equalTo: guide.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.sm
            )
        }

        // ⚠️ **`insertSubview(_:aboveSubview:)`, NEVER `pin(to:)` OR
        // `constrain(in:)`.** Both of those call `addSubview` first, which MOVES
        // the view to the TOP of the stack — the dissolve would then cover the
        // band, the indicator and the bars, which is the exact opposite of its
        // job. The picker states the same rule for its access notice, and this
        // flow has already lost a screen to that helper once.
        //
        // Above the canvas and below everything else: the picture dissolves, the
        // chrome does not.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, aboveSubview: canvas)
        backdropFromBand = backdrop.topAnchor.constraint(equalTo: band.topAnchor)
        backdropFromChrome = backdrop.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor
        )
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // ⚠️ THE FOOT OF THE SCREEN, NOT THE SAFE AREA. The canvas is
            // full-bleed and runs behind the home indicator; a dissolve stopping
            // at the safe area would leave a sharp band of untouched picture
            // beneath it. The picker's blur ends at `view.bottomAnchor` for the
            // same reason.
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // The band starts empty, so the chrome anchor is the one that holds.
            backdropFromChrome
        ])

        // ⚠️ ABOVE THE BAND, NOT ABOVE THE TOOLBAR. The toolbar's items are the
        // sound pill and the category strip; the indicator belongs to the PICTURE,
        // so it sits on the canvas just clear of the chrome — and now just clear
        // of whatever the band is holding.
        //
        // ⚠️ NO CONSTANT HERE, ON PURPOSE. The gap is inside the band (see its
        // type comment): stating it twice would push the indicator 8pt down from
        // where it sits today whenever the band is empty, which is most of the
        // time and is invisible on a single medium, where there is no indicator.
        pageDots.constrain(in: view) { guide in
            pageDots.centerXAnchor.constraint(equalTo: guide.centerXAnchor)
            pageDots.bottomAnchor.constraint(equalTo: band.topAnchor)
        }
        // ⚠️ THIS HIDES ITSELF UNDER TWO ITEMS (`isHidden = count < 2`), which is
        // what makes the band's placement unconditional: nothing here has to ask
        // whether there is a carousel.
        pageDots.configure(count: items.count, current: 0)

        // ⚠️ ABOVE EVERYTHING A PICTURE IS DRAWN IN, so it shows whether it is the
        // canvas or the crop surface that is waiting.
        view.addSubview(busy)
        NSLayoutConstraint.activate([
            busy.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            busy.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // The canvas reports its own paging, so the bar glyph and the dots can
        // follow whichever picture the viewer has swiped to.
        canvas.delegate = self

        let cell = UICollectionView.CellRegistration<MediaEditorPageCell, String> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.prepare(for: item)
            // ⚠️ RE-STATED ON EVERY REGISTRATION, because a cell is recycled and
            // would otherwise arrive wearing the previous picture's choice.
            let chosen = edits(for: id)
            cell.lay(chosen.fit, within: self.fitWindow, animated: false)
            let size = canvasSize
            // ⚠️ AND THE CUT AND THE LOOK ARE RE-APPLIED FOR THE SAME REASON, on
            // the same beat. A cropped, filtered page that scrolls off and comes
            // back would otherwise return whole and undressed — the recycled cell
            // knows nothing of what was chosen for the picture it now carries.
            // ⚠️ **RE-READ AT LANDING, NOT APPLIED FROM THE CAPTURE.** A cell is
            // configured, the author changes the crop, `redraw` fetches and lands —
            // and then this slower fetch lands too, painting the picture as it was
            // before the change. Reading the edits again at the moment the pixels
            // arrive makes the last render the correct one whichever order they
            // come back in, which a `guard … == chosen` cannot: that would leave
            // the cell showing nothing at all.
            Task { [weak cell] in
                let image = await self.library.thumbnail(for: id, size: size)
                self.remember(image, for: id)
                cell?.show(image.map { self.edits(for: id).applied(to: $0) }, for: id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: canvas) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
    }

    /// One item the size of the screen, scrolling sideways.
    private static func canvasLayout() -> UICollectionViewCompositionalLayout {
        var configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]
        )
        let section = NSCollectionLayoutSection(group: group)
        // ⚠️ **THE SAFE AREA WAS THE INSET, AND ONLY A MEASUREMENT FOUND IT.**
        // `contentInsetsReference` defaults to `.safeArea`, so a
        // `fractionalHeight(1)` group is measured against the SAFE AREA rather
        // than against the canvas. Measured on device: the view and the canvas
        // were both (0,0,402,812) — already correct — while the cell came back
        // (0,70,402,656), which is 812 less a 70pt top inset and an 86pt bottom
        // one. Two earlier attempts (transparent bar appearances, then
        // `extendedLayoutIncludesOpaqueBars`) were right in themselves and
        // irrelevant to this: they govern the VIEW's frame. This is the layout's
        // own idea of where the content may go.
        section.contentInsetsReference = .none
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    /// The window a FITTED picture is centred in: from the foot of the top bar to
    /// the head of the page indicator.
    ///
    /// ⚠️ **IT MOVES WHEN THE BAND DOES**, because the indicator sits on the band's
    /// top edge — so this is read at layout rather than stored.
    private var fitWindow: UIEdgeInsets {
        let head = view.safeAreaInsets.top
        let foot = max(0, view.bounds.height - pageDots.frame.minY)
        return UIEdgeInsets(top: head, left: 0, bottom: foot, right: 0)
    }

    /// ⚠️ **EVERY VISIBLE PAGE, NOT JUST THE CURRENT ONE.** The neighbours are
    /// already laid out and a swipe reveals them instantly; leaving them behind
    /// would show the previous window sliding in beside the new one.
    private func layPagesInTheirWindow(animated: Bool) {
        let window = fitWindow
        for cell in canvas.visibleCells {
            guard let page = cell as? MediaEditorPageCell,
                  let id = page.representedID
            else { continue }
            page.lay(edits(for: id).fit, within: window, animated: animated)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layPagesInTheirWindow(animated: false)
    }

    /// The size a full-page picture is asked for, in points.
    private var canvasSize: CGSize {
        let bounds = view.bounds.size
        return bounds.width > 0 && bounds.height > 0 ? bounds : Metrics.canvasFallback
    }

    private func showItems() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Bars

    /// ⚠️ **SET IN `init`, NOT ON APPEAR.** The navigation controller decides
    /// whether to inset this screen's view when the screen is pushed; an
    /// appearance installed in `viewWillAppear` arrives after that decision has
    /// already been taken, which is why the first cut of this changed nothing.
    private func configureNavigationAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        navigationItem.standardAppearance = bar
        navigationItem.scrollEdgeAppearance = bar
        navigationItem.compactAppearance = bar
    }

    private func configureBars() {
        configureNavigationAppearance()
        // ⚠️ **THE BACK BUTTON IS UIKit'S OWN, AND THE BACK-SWIPE COMES WITH
        // IT.** A custom leading item REPLACES the back button, and UIKit
        // disables the interactive pop along with it — silently, so only a real
        // edge drag ever shows it. Measured on this flow: with a hand-made
        // chevron standing in, an edge drag moved nothing; with
        // `leftItemsSupplementBackButton` set, the identical drag popped the
        // screen. `SearchResultsViewController` records paying for the same trap.
        //
        // The chevron that used to stand here did nothing but `popViewController`
        // — exactly what UIKit's own does.
        //
        // ⚠️ AND THE OLD NOTE'S FEAR DOES NOT MATERIALISE: it warned that an
        // inherited button wears the previous screen's title, but no Upload
        // screen HAS a title, so it draws as a bare chevron. Verified on device.
        // `[‹][save][undo] ⋯ [fit][next]` — the reset arrow stands with the other
        // things that act on the whole screen rather than on the picture.
        navigationItem.leftBarButtonItems = [saveDraftItem, resetItem]
        navigationItem.leftItemsSupplementBackButton = true
        // The chevron the NEXT screen wears, kept wordless if a title ever lands
        // here.
        navigationItem.backButtonDisplayMode = .minimal
        // ⚠️ RIGHT ITEMS ARE LAID OUT FROM THE TRAILING EDGE INWARDS, so the
        // FIRST one written is the RIGHTMOST. `[next, fit]` is what draws
        // `[fit][next]` on screen — the order this screen promises.
        navigationItem.rightBarButtonItems = [nextItem, makeFitItem(for: .fill)]
        nextItem.style = .done
    }

    private func configureCategoryStrip() {
        // ⚠️ **THE TOOLBAR ALREADY SUPPLIES A CAPSULE.** iOS composites every bar
        // item through its own neutral glass, so a strip carrying its own
        // backdrop renders as a bubble inside a bubble — the defect the picker's
        // first cut shipped.
        categoryBar.suppressesBackdrop = true
        // ⚠️ **THE PILL DOES NOT MOVE ITSELF — AND THIS COMMENT USED TO CLAIM IT
        // DID.** `PagedTabBar` answers a tap by setting `selectedIndex` and
        // sending `.valueChanged`; the pill is placed by `applyProgress`, which
        // only `setProgress` calls, and every screen that works drives that from
        // a pager reporting its scroll. This screen has no pager, so with no
        // action wired the tap looked dead — which is exactly how it was
        // reported. It states the position itself instead.
        //
        // There is still nothing BEHIND a category: choosing one moves the pill
        // and changes nothing else, because editing is not built yet.
        // ⚠️ **ONE CHANNEL FOR TAP AND SLIDE ALIKE.** The bar this replaced
        // announced a tap through `.valueChanged` and a drag through nothing at
        // all, on the reasoning that a pager would answer for the drag — correct
        // for a screen that has one. This screen does not, so a slide went
        // unheard and the viewer had to tap to finish what it had already
        // decided. Reported from a device.
        categoryBar.onSelect = { [weak self] _ in self?.categoryChanged() }
        touchProbe.attach(to: categoryBar)
        // ⚠️ **THE PILL KEEPS ITS WORD AND THE STRIP GIVES.** The two together
        // over-subscribe the band — a pill beside a four-segment strip does not
        // fit a phone — and the pill was the one that yielded, coming out as
        // "Add a…".
        //
        // Compression resistance was the WRONG LEVER and setting it here did
        // nothing: `PagedTabBar` STATES an intrinsic width, and resistance only
        // governs shrinking below an intrinsic size — lowering the strip's let
        // it shrink but obliged nobody to respect the pill, which had no minimum
        // of its own. The pill now carries a width FLOOR (`neverTruncates`), and
        // the strip is told it may give, which it can afford: it already handles
        // being short by scrolling its overflow, where the pill can only lose
        // letters.
        categoryBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // [song][categories], both leading, with the flexible space pushing them
        // left together. The fixed space keeps them two bubbles rather than one
        // platter — the same spacing the composer's own footer uses between its
        // pill and the buttons beside it.
        toolbarItems = [
            UIBarButtonItem(customView: soundPill),
            .fixedSpace(Spacing.sm),
            UIBarButtonItem(customView: categoryBar),
            .flexibleSpace()
        ]
    }

    /// Moves the pill onto the category that was tapped — see the note in
    /// `configureCategoryStrip` for why a tap does not do this by itself.
    /// ⚠️ **NOTHING TO DRIVE BY HAND ANY MORE.** This used to animate
    /// `setProgress` onto the bar's own `selectedIndex`, because `PagedTabBar`
    /// places its pill only from that call and expected a pager to make it. The
    /// selector moves its own pill, so what is left here is the screen's actual
    /// job: show what the chosen mode offers.
    private func categoryChanged() {
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
    private var selectedCategory: String? {
        let index = categoryBar.selectedIndex
        return Self.categories.indices.contains(index) ? Self.categories[index].title : nil
    }

    /// ⚠️ **LEAVING CROP IS AN ACT, NOT AN ABSENCE.** Choosing another mode has
    /// to put the canvas, the sheet and the stack back before the new band opens
    /// — the surface holds three suspensions and none of them unwinds itself.
    private func showAccessory(for category: String?) {
        if isCropping, category != "Crop" { exitCrop() }
        switch category {
        case "Filters":
            // ⚠️ **A VIDEO GETS THE NOTICE, NOT THE ROW — AND THIS BECAME TRUE
            // THE DAY VIDEOS STARTED PUBLISHING.** The row was offered on every
            // page for as long as a clip was dropped at publish: the look went
            // nowhere, but so did the video, and the finalisation screen said so.
            // Now the clip goes and `post()`'s video branch never reads `edits`
            // — `MediaFilter` is `UIImage`-to-`UIImage` — so leaving the row here
            // would let an author choose a look, watch it applied on the canvas,
            // and publish the untouched clip. That is the exact defect
            // `where !item.isVideo` was removed to end, wearing a different
            // sleeve.
            if currentItemID.flatMap({ itemsByID[$0] })?.isVideo == true {
                setEditingAccessory(filtersUnavailable)
            } else {
                setEditingAccessory(filterRow)
                refreshFilterRow()
            }
        case "Trim":
            guard let id = currentItemID, case .video(let seconds)? = itemsByID[id]?.kind else {
                setEditingAccessory(trimUnavailable)
                return
            }
            setEditingAccessory(timelineTrack)
            refreshTimelineTrack(id: id, duration: seconds)
        case "Crop":
            enterCrop()
        default:
            setEditingAccessory(nil)
        }
    }

    /// Feeds the row the picture it is choosing a look for, and restores the
    /// look this item already carries.
    ///
    /// ⚠️ **ONE FETCH, NOT NINE.** The row filters locally from a single source;
    /// the library seam caches nothing, so nine thumbnail requests would be nine
    /// `PHImageManager` round trips for one photograph.
    private func refreshFilterRow() {
        guard let id = currentItemID else { return }
        filterRow.setSelected(edits(for: id).filter)
        // ⚠️ THE THUMBNAIL'S SIDE, NOT THE ROW'S HEIGHT. The row is taller than
        // its pictures by a caption, and asking for that size would fetch a
        // picture bigger than anything shown.
        let side = MediaFilterRowView.thumbnailSide
        Task { [weak self] in
            guard let self else { return }
            let source = await self.library.thumbnail(for: id, size: CGSize(width: side, height: side))
            guard self.currentItemID == id else { return }
            // ⚠️ **CUT HERE, AND NEVER INSIDE THE ROW.** The row is handed ONE
            // picture and renders nine looks from it locally; teaching it about
            // crops would make it learn a second concept it exists not to know.
            // Handing it the uncut picture instead is the invisible version of
            // this bug: nine chips previewing looks on a photograph that no
            // longer matches the canvas above them.
            let crop = self.edits(for: id).crop
            self.filterRow.show(source.flatMap { MediaCropRenderer.apply(crop, to: $0) } ?? source)
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
    /// ⚠️ **RE-ASKED AFTER THE AWAIT, TWICE.** The author may have swiped to
    /// another page or left the mode entirely while the frames were being
    /// decoded, and `band.content` is the only thing that says the track is still
    /// the tenant.
    private func refreshTimelineTrack(id: String, duration: Double) {
        trackSeconds = duration
        timelineTrack.configure(duration: duration, timeline: edits(for: id).timeline)
        timelineTrack.forgetFrames()
        Task { [weak self] in
            guard let self else { return }
            guard let file = await library.videoFile(for: id) else { return }
            guard currentItemID == id, band.content === timelineTrack else { return }
            // ⚠️ **THE FILE'S OWN LENGTH, NOT THE ITEM'S DECLARED ONE.** The
            // declared duration is what the grid stamps on a tile and is only as
            // good as whatever vended it — under `-rich-media` a fixture whose
            // download failed falls back to a synthetic clip, so an item can
            // truthfully say 52 seconds while the file on disk runs two and a
            // half. Handles laid out against the declaration would then resolve a
            // cut that is not inside the clip, and the export would come back
            // empty. Asked of the asset, this cannot drift.
            let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? duration
            guard currentItemID == id, band.content === timelineTrack else { return }
            let length = real.isFinite && real > 0 ? real : duration
            // Decided on the FILE's length, not the declaration — the whole
            // reason the real duration is loaded above.
            guard length > MediaTimelining.shortestSourceSeconds else {
                setEditingAccessory(trimTooShort)
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
            // A page that has just settled is playing, unless the author stopped
            // it — the glyph says which.
            timelineTrack.showPaused(
                playingSurface.flatMap { preview.isPaused(in: $0) } ?? pausedByAuthor
            )
            view.layoutIfNeeded()
        }
    }

    /// How long the clip the track is showing actually runs.
    ///
    /// ⚠️ **THE FILE'S LENGTH, AND IT IS WHAT TURNS A SCRUB INTO A SEEK.** The
    /// track speaks in seconds of the file and the player takes a FRACTION of it;
    /// dividing by the declared duration instead would scrub to the wrong moment
    /// on exactly the clips whose declaration is wrong — the ones the reload
    /// above exists for.
    private var trackSeconds: Double = 0

    /// Follows the playing clip with the needle, at the display's own rate.
    ///
    /// ⚠️ **A NEEDLE NAILED TO THE CENTRE THAT NEVER MOVES READS AS BROKEN.** The
    /// film has to travel under it while the clip runs, and nothing in AVFoundation
    /// pushes that: `playhead(in:)` is a poll. What rate it must run at is not a
    /// judgement — see the note on the link itself, and charter T1.
    ///
    /// ⚠️ **AND IT IS PAUSED WHENEVER THE TRACK IS NOT THE TENANT.** A link left
    /// running would poll a player nobody is watching for as long as the editor
    /// is open.
    ///
    /// ⚠️ **AND IT IS DRIVEN THROUGH A PROXY, BECAUSE A `CADisplayLink` RETAINS
    /// ITS TARGET.** A link holding this screen strongly is a cycle the screen
    /// can never break: the run loop holds the link, the link holds the screen,
    /// and `deinit` — the only place left to invalidate from — therefore never
    /// runs. An editor dismissed with the track open would stay alive holding a
    /// player, a pool and every decoded frame. This repo's one recorded player
    /// leak, `profile-gallery-player-leak`, is the same story told about
    /// surfaces. The proxy's reference back is weak, and it invalidates the link
    /// the first time it finds nobody home.
    private lazy var follower: CADisplayLink = {
        let link = CADisplayLink(target: followerProxy, selector: #selector(DisplayLinkProxy.tick))
        // ⚠️ **NOT RATE-LIMITED, AND LIMITING IT WAS THE STUTTER.** This asked for
        // 15Hz to be frugal. At 60 points of film per second that moves the strip
        // in FOUR-POINT STEPS while the video beside it runs smooth, and the
        // whole band reads as dropped frames — reported from the device as "the
        // scrolling stutters during playback, maybe it is not optimised". It was
        // not a cost problem: `AVPlayerItem.currentTime()` reads a timebase, and
        // assigning `contentOffset` on a scroll view whose content is already
        // laid out moves layers and lays nothing out. The default range is the
        // display's own, which is what every scroll in the system runs at.
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        followerProxy.owner = self
        followerProxy.link = link
        return link
    }()

    private let followerProxy = DisplayLinkProxy()

    /// ⚠️ **A PROBE, BECAUSE "IT LOOKS SMOOTHER" IS NOT A MEASUREMENT.** The
    /// stutter was a rate cap and the cure is a rate, so the honest check is the
    /// interval between beats — not a screenshot and not a feeling. Under
    /// `-timeline-probe` the follower prints, once a second, how many times it
    /// ran and the worst gap between two runs. At the display's own rate the
    /// worst gap is a frame; at the 15Hz this used to ask for it was 67ms, which
    /// at 60 points of film per second is a four-point jump.
    private var probeBeats = 0
    private var probeWorstGap: CFTimeInterval = 0
    private var probeLastBeat: CFTimeInterval = 0
    private var probeWindowStart: CFTimeInterval = 0

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

    fileprivate func followPlayhead() {
        probeFollowBeat()
        guard band.content === timelineTrack, let surface = playingSurface,
              let head = preview.playhead(in: surface)
        else { return }
        // ⚠️ **THE GLYPH IS BOUND TO THE PLAYER, NOT SET AT THE MOMENTS WE
        // HAPPEN TO KNOW ABOUT.** It was updated on a tap, on a scrub and on a
        // settle — which leaves it stale for everything else that stops a clip:
        // reaching the end, an interruption, a stall. A button showing "pause"
        // over a stopped clip is a control that lies about the thing it controls.
        // One bool a beat, and the setter below is a no-op when nothing moved.
        timelineTrack.showPaused(preview.isPaused(in: surface) ?? true)
        let seconds = head.fraction * head.seconds
        // ⚠️ **THE TRACK KEEPS THE TIME UNTIL THE PLAYER CATCHES UP.** A seek is
        // tolerant by a quarter second and is not instant, so the first tick
        // after a finger lifts reads a player that has not moved yet — and
        // copying that back over the author's position is the "it jumps back to
        // where I started" they reported. The rule and its give-up are in
        // `MediaTimelining.handover`, which is where they can be tested.
        let (mayFollow, next) = MediaTimelining.handover(handover, playerSeconds: seconds)
        handover = next
        guard mayFollow else { return }
        // ⚠️ **THE PREVIEW STAYS INSIDE THE CUT.** Playing on past the end handle
        // shows the author footage they have just decided to throw away, as
        // though it were part of the post. Checked after the handover, so a
        // scrub's own seek is never mistaken for playback running out.
        if !pausedByAuthor, let id = currentItemID,
           let back = MediaTimelining.loopback(
               playheadSeconds: seconds,
               within: MediaTimelining.resolved(
                   edits(for: id).timeline, withinSource: trackSeconds
               )
           ), trackSeconds > 0 {
            preview.seek(toFraction: back / trackSeconds, in: surface, toleranceSeconds: 0.02)
            timelineTrack.follow(sourceSeconds: back)
            return
        }
        timelineTrack.follow(sourceSeconds: seconds)
    }

    /// What the track is waiting for before it lets the player move it again.
    private var handover: MediaTimelining.Handover = .settled

    /// Where the author last put the needle, so the handover knows what arrival
    /// to wait for. Nil when this gesture has not moved anything.
    private var lastScrubbedSeconds: Double?

    /// The surface the settled page is playing in, if it is playing at all.
    private var playingSurface: VideoRenderView? {
        guard let id = playingID, let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
                as? MediaEditorPageCell
        else { return nil }
        return page.videoSurface
    }

    /// The film moved under the needle: put that moment on the canvas.
    ///
    /// ⚠️ **A SEEK, NOT A STORE.** Scrubbing changes what is on screen and
    /// nothing else; `onChange` is the channel that writes to `edits`, and it
    /// fires on release only.
    private func scrubbed(toSourceSeconds seconds: Double) {
        // ⚠️ **HOW FAR THIS SAMPLE MOVED IS HOW FAST THE FINGER IS GOING**, and
        // that is what the seek's tolerance is worth — charter T7. See
        // `MediaTimelining.seekTolerance`.
        let moved = lastScrubbedSeconds.map { seconds - $0 } ?? 0
        lastScrubbedSeconds = seconds
        guard let surface = playingSurface, trackSeconds > 0 else { return }
        preview.seek(
            toFraction: seconds / trackSeconds, in: surface,
            toleranceSeconds: MediaTimelining.seekTolerance(movedSeconds: moved)
        )
    }

    /// ⚠️ **PLAYBACK STOPS WHILE A FINGER IS ON THE TRACK, AND IT HAS TO.** A
    /// clip that keeps running fights every seek the scroll asks for: the player
    /// advances between samples, the track seeks it back, and the picture lands
    /// somewhere neither the author nor the player chose. The pause is what makes
    /// scrubbing feel like moving the film rather than arguing with it.
    private func scrubbing(_ scrubbing: Bool) {
        if scrubbing {
            // A gesture that moves nothing must not arm a handover: the track
            // would then wait for an arrival at a position nobody asked for.
            lastScrubbedSeconds = nil
            handover = .settled
        } else {
            handover = MediaTimelining.Handover(target: lastScrubbedSeconds)
        }
        follower.isPaused = scrubbing || band.content !== timelineTrack
        guard let surface = playingSurface else { return }
        // Stopped while the finger is down; afterwards it goes back to whatever
        // the AUTHOR last asked for, which is not necessarily "playing".
        let paused = scrubbing || pausedByAuthor
        preview.setPaused(paused, in: surface)
        timelineTrack.showPaused(paused)
    }

    /// ⚠️ **SILENT WHEN THE BAND IS SHUT, AND THAT IS THE POINT.** Both settle
    /// hooks call this on every swipe; without the guard each one would run a
    /// full `PHImageManager` request — iCloud access allowed — to dress a row
    /// nobody is looking at.
    private func refreshFilterRowIfShowing() {
        guard band.content === filterRow else { return }
        refreshFilterRow()
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
    private func refreshTimelineTrackIfShowing() {
        guard band.content === timelineTrack
                || band.content === trimUnavailable
                || band.content === trimTooShort
        else { return }
        showAccessory(for: "Trim")
    }

    /// ⚠️ **A VIDEO LEAVES CROP MODE STANDING ON ITS NOTICE, AND ONLY A SETTLE
    /// CAN CLEAR IT.** Choosing "Crop" on a video puts a line of text in the band
    /// and returns without locking anything — so the canvas still pages. Swiping
    /// on to a photograph used to change nothing: the band kept the notice, the
    /// pill kept saying Crop, and tapping Crop again announced nothing because the
    /// selection had not changed. The mode was unreachable for that picture until
    /// another one was chosen and come back from.
    private func reopenCropIfWaiting() {
        guard !isCropping, selectedCategory == "Crop" else { return }
        showAccessory(for: "Crop")
    }

    private func applyFilter(_ filter: MediaFilter, to id: String) {
        change(id) { $0.filter = filter }
        redraw(id)
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
    private func redraw(_ id: String) {
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
    private func show(_ image: UIImage?, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
        (page as? MediaEditorPageCell)?.show(image, for: id)
    }

    // MARK: - Fill or fit

    /// Which page the canvas is resting on. Read from the offset rather than
    /// stored: the canvas pages itself, and a stored index drifts the moment a
    /// swipe is interrupted.
    private var currentIndex: Int {
        guard canvas.bounds.width > 0, !items.isEmpty else { return 0 }
        let page = Int((canvas.contentOffset.x / canvas.bounds.width).rounded())
        return min(max(page, 0), items.count - 1)
    }

    private var currentItemID: String? {
        items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    }

    private var currentFit: ContentFit {
        currentItemID.map { edits(for: $0).fit } ?? .fill
    }

    private func toggleFit() {
        guard let id = currentItemID else { return }
        let next = edits(for: id).fit.toggled
        change(id) { $0.fit = next }
        let page = canvas.cellForItem(at: IndexPath(item: currentIndex, section: 0))
        (page as? MediaEditorPageCell)?.lay(next, within: fitWindow, animated: true)
        updateFitItem(animated: true)
    }

    private func makeFitItem(for fit: ContentFit) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: fit.symbolName),
            primaryAction: UIAction { [weak self] _ in self?.toggleFit() }
        )
        item.accessibilityLabel = fit.actionName
        return item
    }

    /// Keeps the glyph offering the move the viewer can actually make on the
    /// picture in front of them — including after a swipe, when the next
    /// picture may have been left in the other state.
    ///
    /// ⚠️ **A NEW ITEM, NOT A NEW IMAGE.** Assigning `.image` on the item that
    /// is already in the bar swaps the glyph in a single frame. UIKit animates
    /// the capsule only when the ITEM ITSELF is replaced and the change is
    /// stated through `setRightBarButtonItems(_:animated:)` — identity is what
    /// it diffs on.
    ///
    /// ⚠️ **AND ONLY WHEN IT ACTUALLY CHANGES.** Re-stating the bar on every
    /// settle would animate the item while swiping between two pictures that
    /// share a fit state, which reads as a flicker for no reason.
    private func updateFitItem(animated: Bool) {
        // ⚠️ **NOT WHILE THE CROP SURFACE HOLDS THAT SLOT.** Undo stands where the
        // fill/fit glyph does, and a settle arriving mid-crop would quietly put the
        // glyph back over it. The canvas is locked while cropping so no settle
        // should arrive — this is the guard that makes "should" unnecessary.
        guard !isCropping else { return }
        let fit = currentFit
        guard fit != shownFit else { return }
        shownFit = fit
        navigationItem.setRightBarButtonItems([nextItem, makeFitItem(for: fit)], animated: animated)
    }

    /// Puts undo in the bar while the crop surface is up, and the fill/fit glyph
    /// back when it goes.
    ///
    /// ⚠️ **THE FILL/FIT GLYPH LEAVES FOR THE DURATION, AND THAT IS DELIBERATE.**
    /// Filling or fitting is a decision about how a picture is laid in the frame it
    /// will be shown in; while the author is deciding what that picture even IS,
    /// the control has nothing meaningful to act on. It comes back with the mode.
    ///
    /// ⚠️ **`shownFit` IS RE-SEEDED ON THE WAY BACK, NOT TRUSTED.** It records
    /// which glyph the bar is WEARING, and while the mode was up the bar was
    /// wearing neither — so restoring through `updateFitItem`'s "only when it
    /// changes" rule would leave the slot empty whenever the fit had not moved.
    private func showCropBarItems(_ isCropping: Bool, animated: Bool) {
        if isCropping {
            navigationItem.setLeftBarButtonItems([saveDraftItem, resetItem], animated: animated)
            navigationItem.setRightBarButtonItems([nextItem], animated: animated)
        } else {
            navigationItem.setLeftBarButtonItems(
                [saveDraftItem, resetItem], animated: animated
            )
            shownFit = currentFit
            navigationItem.setRightBarButtonItems(
                [nextItem, makeFitItem(for: shownFit)], animated: animated
            )
        }
    }

    private func goNext() {
        navigationController?.pushViewController(onNext(items, edits), animated: true)
    }

    // MARK: - Cropping

    /// The tools the band holds while "Crop" is the chosen mode.
    ///
    /// ⚠️ BUILT ONCE, like the filter row and for the same reason: reopening a
    /// band should not rebuild the controls inside it.
    private lazy var cropTools: MediaCropToolsView = {
        let tools = MediaCropToolsView()
        tools.onTurn = { [weak self] angle in self?.cropSurface.setAngle(angle) }
        tools.onRatio = { [weak self] ratio in
            guard let self, let id = currentItemID else { return }
            cropRatios[id] = ratio
            cropSurface.choose(ratio)
        }
        tools.onQuarterTurn = { [weak self] in self?.cropSurface.turnQuarter() }
        tools.onFlip = { [weak self] in self?.cropSurface.flipAcross() }
        return tools
    }()

    private lazy var cropSurface: MediaCropSurfaceView = {
        let surface = MediaCropSurfaceView()
        surface.onChange = { [weak self] crop in self?.cropChanged(crop) }
        return surface
    }()

    /// What the band says instead, for a picture this mode cannot serve.
    ///
    /// ⚠️ **THE SECOND HALF USED TO READ "only the photos in this selection will
    /// go", AND IT IS NOW FALSE.** Videos publish. Leaving it would have the
    /// screen tell the author their clip is about to be dropped while it quietly
    /// posts it — a notice outliving its reason, which is worse than no notice.
    private lazy var cropUnavailable = BandNoticeView(
        "A video can't be cropped yet — it'll be posted as it is."
    )

    /// The clip as a strip of film pushed past a fixed needle.
    private lazy var timelineTrack: MediaTimelineTrackView = {
        let track = MediaTimelineTrackView()
        track.onChange = { [weak self] timeline in
            guard let self, let id = currentItemID else { return }
            change(id) { $0.timeline = timeline }
            refreshResetItem()
        }
        track.onScrub = { [weak self] seconds in
            self?.scrubbed(toSourceSeconds: seconds)
        }
        track.onScrubbing = { [weak self] scrubbing in
            self?.scrubbing(scrubbing)
        }
        track.onPlayPause = { [weak self] in
            self?.togglePreviewPlayback()
        }
        return track
    }()

    /// ⚠️ **WHETHER THE AUTHOR STOPPED THE CLIP, AS OPPOSED TO THE TRACK.**
    /// Scrubbing stops playback and lets it go again, and without this the
    /// release would restart a clip the author had deliberately paused — their
    /// decision undone by a gesture that was only meant to move the film.
    /// `VideoTrimmerControl`'s example carries the same flag under the name
    /// `wasPlaying`, for the same moment.
    private var pausedByAuthor = false

    /// ⚠️ **A TAP ON THE PICTURE IS THE PLAY BUTTON EVERY VIDEO SURFACE HAS.**
    /// The ruler's glyph is the explicit control; this is the one nobody has to
    /// find.
    ///
    /// ⚠️ **AND IT CARRIES NO `!isCropping` GUARD, WHICH IT DID FOR ONE BUILD.**
    /// The reasoning was sound — the crop surface owns the canvas, so a tap there
    /// is aimed at the box rather than at the film — and the guard was
    /// unreachable: `enterCrop` REFUSES videos, so a clip is never behind a crop
    /// surface, and a photograph has no player for this to reach. This screen has
    /// already removed one dead guard for exactly that reason (a `stopPreview()`
    /// in `enterCrop` that could not run). It comes back with the compositor,
    /// when a video can be cropped and there is something for it to protect.
    @objc private func mediaTapped() {
        togglePreviewPlayback()
    }

    private lazy var mediaTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped))
        // ⚠️ **IT MUST NOT EAT THE PAGING.** A tap recogniser and a scroll view's
        // pan do not compete — one needs a still finger and the other a moving
        // one — but a tap that CANCELS touches would stop a cell ever seeing one.
        tap.cancelsTouchesInView = false
        return tap
    }()

    private func togglePreviewPlayback() {
        guard let surface = playingSurface else { return }
        let paused = preview.isPaused(in: surface) ?? true
        pausedByAuthor = !paused
        preview.setPaused(!paused, in: surface)
        timelineTrack.showPaused(!paused)
    }

    /// ⚠️ **THE MIRROR IMAGE OF THE OTHER TWO NOTICES.** Crop and Filters refuse
    /// a video; Trim refuses a photograph. Same rule — a mode that cannot serve
    /// the medium in front of the author says so rather than offering a control
    /// that reaches nothing.
    private lazy var trimUnavailable = BandNoticeView(
        "A photo has nothing to trim."
    )

    /// ⚠️ **HANDLES THAT CANNOT MOVE ARE WORSE THAN NO HANDLES.**
    /// `MediaTimelining` will not leave less than `shortestSourceSeconds` behind, so on
    /// a clip already at or below that floor every drag resolves back to where
    /// it started. The strip looked operable and was inert, which is the same
    /// shape of lie as a control that reaches nothing — it just fails one step
    /// earlier.
    private lazy var trimTooShort = BandNoticeView(
        "This clip is too short to trim."
    )

    /// The same, for the look. See the note in `showAccessory(for:)`.
    private lazy var filtersUnavailable = BandNoticeView(
        "A video can't be filtered yet — it'll be posted as it is."
    )

    /// The shape each picture's box is being held to.
    ///
    /// ⚠️ **NOT PART OF `MediaEdits`, ON PURPOSE.** It is how the author is
    /// working, not what they decided: a 4:5 rectangle IS a 4:5 crop whether it
    /// was reached through the chip or dragged there by hand, and neither the
    /// renderer nor the post can tell the two apart. Carrying it would be
    /// carrying a mode, and the next screen has no mode.
    private var cropRatios: [String: CropRatio] = [:]

    private var isCropping = false

    /// Which picture the surface is cutting.
    ///
    /// ⚠️ **CAPTURED ON THE WAY IN, NEVER RE-READ.** `currentItemID` is derived
    /// from the canvas's content offset, and an offset divided by a width is not
    /// stable across a device rotation — this app allows landscape. A crop landing
    /// on a different item than the one the author is looking at is not a visual
    /// glitch, it is a rectangle stored against somebody else's photograph. The
    /// canvas cannot be paged while the surface is up, so one capture is enough.
    private var croppingID: String?

    /// What the screen borrowed on the way into crop mode, ready to be given
    /// back. ⚠️ CAPTURED ONCE AND CAPTURED AS IT WAS — restoring to `true`
    /// instead of to the prior value is how a suspension becomes permanent.
    private var cropRestore: (() -> Void)?

    /// Black behind the editing tools, for as long as they are up.
    ///
    /// ⚠️ **THE BAND IS CHROME HERE, NOT MORE PICTURE.** Everywhere else on this
    /// screen the canvas runs full-bleed beneath the controls and the dissolve
    /// softens it — that is the design, and the filter row depends on it. While a
    /// crop is being made it read wrong: the strip showed the UNCUT photograph
    /// under a ruler measuring the cut one. Reported from a device as "on aperçoit
    /// par derrière les outils d'édition le media". The dissolve stays and now has
    /// black to dissolve.
    private let cropChrome: UIView = {
        let chrome = UIView()
        chrome.backgroundColor = .systemBackground
        chrome.isUserInteractionEnabled = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        return chrome
    }()

    private func enterCrop() {
        guard let id = currentItemID, let item = itemsByID[id] else { return }
        guard !item.isVideo else {
            // ⚠️ SAID, NOT SILENTLY DROPPED — AND THE REASON HAS NARROWED.
            // `post()` no longer discards videos; a clip publishes. What it
            // cannot carry is an EDIT: `MediaCrop.apply` and `MediaFilter` are
            // `UIImage`-to-`UIImage`, so the only thing this mode could cut here
            // is the poster frame, and the cut would never reach the file that
            // gets uploaded. Still a control that reaches nothing — for a
            // different reason, written down in
            // `dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4.
            setEditingAccessory(cropUnavailable)
            return
        }
        guard !isCropping else { return }
        isCropping = true

        let wasScrolling = canvas.isScrollEnabled
        let wasModal = navigationController?.isModalInPresentation ?? false
        cropRestore = { [weak self] in
            guard let self else { return }
            canvas.isScrollEnabled = wasScrolling
            navigationController?.isModalInPresentation = wasModal
        }
        // ⚠️ **A LOCK, NOT A REFUSAL.** `CarouselCollectionView` declines a drag
        // by answering false in `gestureRecognizerShouldBegin`, which hands the
        // touch to the stack's full-width pan — so refusing here would page
        // nothing and pop the screen instead. `IconSelectorBar` states the same
        // choice, and states why a `require(toFail:)` into a scroll view's
        // recogniser graph is not the tool either.
        canvas.isScrollEnabled = false
        // ⚠️ **AND THIS IS WHAT KEEPS A DOWNWARD DRAG ON THE PICTURE FROM
        // CLOSING THE SHEET.** Dismissal is velocity-dominated — measured on the
        // filter row at 139pt/~3000pt/s — so no amount of gesture arbitration
        // makes it safe; the sheet has to be told it is not dismissible. Set on
        // the NAVIGATION CONTROLLER, which is the presented screen.
        navigationController?.isModalInPresentation = true
        updateStackGestures()

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
        setEditingAccessory(cropTools)
        showCropPicture(for: id)
        settleIntoCrop()
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

    private func exitCrop() {
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
        if band.content === cropTools { setEditingAccessory(nil) }
        cropRestore?()
        cropRestore = nil
        updateStackGestures()
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

    /// Hands the surface the picture to cut.
    ///
    /// ⚠️ **NOTHING MAY BE TOUCHED UNTIL THE PICTURE LANDS.** The library answers
    /// on its own turn — `PHImageManager` with iCloud allowed can take a visible
    /// moment — and until it does, the surface holds a placeholder source of one
    /// point square. A drag in that window would compute a crop against nothing,
    /// store it, and then have it overwritten by the arrival below; a turn of the
    /// dial would do the same. Both controls are dead for exactly as long as there
    /// is nothing to cut.
    private func showCropPicture(for id: String) {
        let chosen = edits(for: id)
        let ratio = cropRatios[id] ?? .free
        let size = canvasSize
        cropTools.adopt(angle: MediaCropGeometry.split(chosen.crop.angle).fine, ratio: ratio)
        resetItem.isEnabled = !chosen.crop.isUntouched
        // ⚠️ THE SAME SHORTCUT AS `redraw`: the picture the canvas is showing is
        // the picture the surface wants, so opening the mode need not wait for the
        // library to answer a question it has already answered.
        if let held = lastSource, held.id == id {
            dress(held.image, in: chosen, crop: edits(for: id).crop, ratio: ratio)
            return
        }
        cropSurface.isUserInteractionEnabled = false
        cropTools.isUserInteractionEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let source = await library.thumbnail(for: id, size: size)
            remember(source, for: id)
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

    private func cropChanged(_ crop: MediaCrop) {
        guard let id = croppingID else { return }
        change(id) { $0.crop = crop }
        // ⚠️ ONLY THE UNDO BUTTON, NEVER THE DIAL — see `setCanReset`. Re-stating
        // the dial's angle from here would fight the finger that is turning it.
        resetItem.isEnabled = !crop.isUntouched
    }

    // MARK: - The strip wins its own touches

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`. The
    /// picker skips this because it is the only screen in its stack; this screen
    /// is pushed, so a sideways drag on the strip is a drag the back-swipe wants
    /// for itself.
    private lazy var touchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.isTouchingStrip = isTouching
        self?.updateStackGestures()
    }

    private var isTouchingStrip = false

    /// ⚠️ **ONE PREDICATE, TWO OWNERS — AND WITH TWO OWNERS IT WAS A DEFECT.**
    /// `setStackGesturesEnabled` keeps a single list of suspended recognisers and
    /// refuses to suspend twice (`suspendedPans.isEmpty`), while the strip's probe
    /// announces `false` on every lift and restored them unconditionally. Enter
    /// crop mode, then brush the category strip, and the back-swipe came back
    /// alive underneath a live crop surface — a rightward drag on the picture
    /// would have taken the screen away. Asking one question with both answers in
    /// it is what makes the single slot correct.
    private func updateStackGestures() {
        setStackGesturesEnabled(!(isCropping || isTouchingStrip))
    }

    private var suspendedPans: [(UIGestureRecognizer, Bool)] = []

    /// Suspends every pan on the navigation controller's own container view for
    /// the length of a touch on the strip.
    ///
    /// ⚠️ **THE STACK HAS TWO BACK-SWIPE RECOGNISERS AND
    /// `interactivePopGestureRecognizer` VENDS ONLY ONE** — audited on the search
    /// results screen, where gating the vended one looked right and popped the
    /// screen anyway. Every pan on the container is suspended, each restored to
    /// the value it had rather than to `true`, and only while this screen is the
    /// top one.
    ///
    /// These lines also exist in Profile's relationship lists. Features cannot
    /// import one another, so the choice was this or promoting the helper into
    /// DesignSystem — a change with a wider blast radius than the one screen that
    /// needed it.
    private func setStackGesturesEnabled(_ isEnabled: Bool) {
        if isEnabled {
            for (recogniser, wasEnabled) in suspendedPans { recogniser.isEnabled = wasEnabled }
            suspendedPans = []
            return
        }
        guard navigationController?.topViewController === self,
              suspendedPans.isEmpty,
              let host = navigationController?.view
        else { return }
        let pans = (host.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
        suspendedPans = pans.map { ($0, $0.isEnabled) }
        for recogniser in pans { recogniser.isEnabled = false }
    }
}

/// One page of the canvas: the media, filling it.
final class MediaEditorPageCell: UICollectionViewCell {
    /// ⚠️ A PICTURE ARRIVES LATE AND A CELL IS REUSED EARLY — the same guard the
    /// grid's tile carries, for the same reason.
    private(set) var representedID: String?

    private let picture = UIImageView()
    private let surface = VideoRenderView()

    /// ⚠️ **HELD, BECAUSE A FITTED PICTURE DOES NOT LIVE IN THE SAME RECTANGLE AS
    /// A FILLED ONE.** Filling means the whole window, bars included — that is what
    /// full-bleed is for. Fitting means showing the picture WHOLE, and a whole
    /// picture centred in the window puts its middle behind the toolbar and its
    /// edges under the chrome: it reads as hanging low. The window a fitted picture
    /// is centred in runs from the foot of the top bar to the head of the page
    /// indicator, and these four constants are how it gets there.
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(picture)
        top = picture.topAnchor.constraint(equalTo: contentView.topAnchor)
        bottom = picture.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            top, bottom,
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        // ⚠️ **PINNED TO THE PICTURE, NOT TO THE CONTENT VIEW.** The fit/fill
        // window is four constants held on `picture`, and a surface that
        // duplicated them would drift the first time one of the two was changed
        // alone. Pinned here it inherits the geometry for free: when the author
        // fits a clip, the video is laid in the same rectangle as the poster it
        // replaces, and the swap from one to the other moves nothing.
        surface.isHidden = true
        surface.isUserInteractionEnabled = false
        // The page draws its own ground (the editor paints behind everything);
        // an opaque black surface would put a letterbox back under a fitted clip.
        surface.paintsOpaqueGround = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: picture.topAnchor),
            surface.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: picture.trailingAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **A REUSED CELL MUST NOT KEEP A SURFACE THAT IS STILL PLAYING.** The
    /// canvas recycles pages, so the cell that carried page 2's clip becomes
    /// page 5's without asking anyone. Whoever put a player here has to be told;
    /// the editor sets this when it hands the cell a surface to play in.
    var onReuse: ((VideoRenderView) -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        picture.image = nil
        onReuse?(surface)
        onReuse = nil
        surface.isHidden = true
    }

    func prepare(for item: MediaLibraryItem) {
        representedID = item.id
        accessibilityLabel = item.isVideo ? "Video" : "Photo"
    }

    /// The surface a video plays in, for the editor to hand to its player.
    /// Hidden until something is actually bound to it — an empty
    /// `VideoRenderView` over the poster is a black rectangle.
    var videoSurface: VideoRenderView { surface }

    /// Reveals the video and lets the poster underneath show through until the
    /// first decoded frame arrives.
    func beginShowingVideo() {
        // The poster is the picture this page already drew — the very frame the
        // grid showed and the publish path will upload. Handing the surface the
        // same one means the swap to live playback changes the motion and
        // nothing else.
        surface.setPoster(picture.image)
        surface.isHidden = false
        surface.fadeInOnFirstFrame(over: 0.2)
    }

    func stopShowingVideo() {
        surface.isHidden = true
        surface.setPoster(nil)
    }

    /// Hands over a picture fetched for `id`, and ignores one whose page has
    /// moved on.
    func show(_ image: UIImage?, for id: String) {
        guard representedID == id else { return }
        picture.image = image
    }

    /// ⚠️ **`contentMode` IS NOT AN ANIMATABLE PROPERTY.** Assigning it inside a
    /// `UIView.animate` block changes the picture in one frame. A crossfade
    /// through `UIView.transition` is how the jump is softened — the same move
    /// the feed's render view makes when it swaps a poster for live playback.
    func setContentMode(_ mode: UIView.ContentMode, animated: Bool) {
        guard picture.contentMode != mode else { return }
        guard animated else {
            picture.contentMode = mode
            return
        }
        UIView.transition(
            with: picture, duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.picture.contentMode = mode
        }
    }

    /// Lays the picture the way the author left it, in the window a fitted one is
    /// centred in.
    ///
    /// ⚠️ **THE INSETS APPLY TO `fit` ONLY.** A filled picture keeps the whole
    /// window on purpose — it is cropped by the frame either way, so insetting it
    /// would only show less of it for nothing.
    func lay(_ fit: ContentFit, within window: UIEdgeInsets, animated: Bool) {
        setContentMode(fit.mode, animated: animated)
        // ⚠️ THE VIDEO OBEYS THE SAME CHOICE AS THE PICTURE. Left at the feed's
        // `.resizeAspectFill`, a clip the author asked to see WHOLE would carry
        // on being cropped — and the poster beneath it would not be, so the swap
        // to live playback would jump.
        surface.videoGravity = fit == .fit ? .resizeAspect : .resizeAspectFill
        let applied = fit == .fit ? window : .zero
        guard top.constant != applied.top || bottom.constant != -applied.bottom else { return }
        top.constant = applied.top
        bottom.constant = -applied.bottom
        guard animated else {
            contentView.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.contentView.layoutIfNeeded()
        }
    }

    /// Internal for tests: where the picture actually sits in its page.
    var debugPictureFrame: CGRect { picture.frame }

    /// Internal for tests: whether a picture has actually landed.
    var debugHasPicture: Bool { picture.image != nil }
    /// Internal for tests: how the picture is currently laid in its page.
    var debugContentMode: UIView.ContentMode { picture.contentMode }
    /// Internal for tests: the size of what is actually on the page — the only
    /// thing that can tell a rendered crop from the picture it was cut from.
    var debugPictureSize: CGSize { picture.image?.size ?? .zero }
    /// Internal for tests: whether this page is showing a video surface at all.
    var debugIsShowingVideo: Bool { !surface.isHidden }
    /// Internal for tests: how the video is laid, which must track the picture.
    var debugVideoGravityIsFit: Bool { surface.videoGravity == .resizeAspect }
}

// MARK: - Playing the settled page

private extension MediaEditorViewController {
    /// ⚠️ **ONE PAGE PLAYS, AND IT IS THE ONE THAT HAS COME TO REST.** The canvas
    /// holds every chosen medium and recycles their cells, so "play the videos"
    /// would mean a player per page, a pool the screen does not own, and
    /// surfaces outliving the cells they were bound to — which is precisely the
    /// shape of this repo's one recorded player leak. One player, one page, and
    /// the binding torn down before the next one is made.
    ///
    /// ⚠️ **NOT DURING CROP.** Crop mode lifts the picture onto its own surface
    /// and takes the gestures with it; a clip still running underneath would be
    /// moving pixels nobody is looking at, behind a still the author IS looking
    /// at.
    func playSettledPage() {
        guard !isCropping else { return stopPreview() }
        guard let id = currentItemID, itemsByID[id]?.isVideo == true else {
            return stopPreview()
        }
        // A settle that lands where it already was must not restart the clip —
        // the fill/fit toggle and the band both settle the canvas.
        guard playingID != id else { return }
        stopPreview()

        guard let page = canvas.cellForItem(at: IndexPath(item: currentIndex, section: 0))
                as? MediaEditorPageCell
        else { return }

        playingID = id
        page.beginShowingVideo()
        // ⚠️ THE CELL TELLS US WHEN IT IS TAKEN AWAY. A canvas recycles pages
        // without asking, and a surface handed to a player and then re-used for
        // another item would keep the previous clip's frames.
        page.onReuse = { [weak self] surface in
            guard let self else { return }
            preview.stop(surface)
            if playingID == id { playingID = nil }
        }

        let surface = page.videoSurface
        Task { [weak self] in
            guard let self else { return }
            guard let file = await library.videoFile(for: id) else {
                // Nothing to play — the poster stays, which is what this page
                // showed before playback existed.
                if playingID == id { stopPreview() }
                return
            }
            // ⚠️ RE-ASKED AFTER THE AWAIT. Reading a file can take a moment —
            // an iCloud clip can take much longer — and the author may have
            // swiped on, or opened crop, while it did.
            guard playingID == id else { return }
            await preview.play(file, in: surface)
        }
    }

    /// Unbinds whatever is playing and puts the page back to its poster.
    func stopPreview() {
        guard let id = playingID else { return }
        playingID = nil
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
                as? MediaEditorPageCell
        else { return }
        page.onReuse = nil
        preview.stop(page.videoSurface)
        page.stopShowingVideo()
    }
}

// MARK: - The canvas reports its paging

/// Only so the fill/fit glyph can follow the picture the viewer swiped to. The
/// canvas has no selection and wants none — a tap on the media edits nothing
/// yet.
extension MediaEditorViewController: UICollectionViewDelegate {
    /// ⚠️ THE DOTS FOLLOW THE SCROLL, THE GLYPH FOLLOWS THE SETTLE. The mark
    /// should track the finger — an indicator that jumps only once the page
    /// lands reads as lagging — while the fill/fit item must NOT be re-stated
    /// mid-drag, since re-stating it animates the bar.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pageDots.setCurrent(currentIndex)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateFitItem(animated: true)
        refreshFilterRowIfShowing()
        refreshTimelineTrackIfShowing()
        reopenCropIfWaiting()
        playSettledPage()
    }

    /// ⚠️ **A DRAG RELEASED WITH NO VELOCITY DECELERATES NOWHERE.** Neither hook
    /// below fires for it, which was survivable while only the fill/fit glyph
    /// depended on settling — it would simply be re-stated on the next event.
    /// A clip that never starts is not survivable in the same way.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        updateFitItem(animated: true)
        refreshFilterRowIfShowing()
        refreshTimelineTrackIfShowing()
        reopenCropIfWaiting()
        playSettledPage()
    }

    /// ⚠️ **BOTH SETTLE HOOKS, NOT JUST THE DRAGGED ONE.** A canvas that arrives
    /// by `scrollToItem` announces itself here instead, and handling only the
    /// dragged case would leave the row dressed in the previous picture while the
    /// canvas shows the next one.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateFitItem(animated: true)
        refreshFilterRowIfShowing()
        refreshTimelineTrackIfShowing()
        reopenCropIfWaiting()
        playSettledPage()
    }
}

// MARK: - The editing band

extension MediaEditorViewController {
    /// Puts a control in the strip between the toolbar and the page indicator,
    /// or takes it away with `nil`.
    ///
    /// The band reserves room and owns placement; what goes in it — a horizontal
    /// row of filter thumbnails first — is built separately and handed over here,
    /// so the screen never learns what a filter is.
    ///
    /// ⚠️ **THIS IS PRODUCTION CODE AND MUST STAY OUT OF `#if DEBUG`. IT DID NOT,
    /// AND IT COST A RED CI CYCLE.** It was first written just below
    /// `debugTapFit()` — inside the DEBUG-only extension that starts a few lines
    /// down — while its only callers, `showAccessory(for:)`, are ordinary code.
    /// Debug compiled, the 120-test suite passed, and the flow was verified end to
    /// end on a device; **every one of those instruments builds Debug**, where the
    /// symbol exists. CI compiles Debug *and* Release, and Release failed with
    /// `cannot find 'setEditingAccessory' in scope`. The old comment here already
    /// said "NOT A DEBUG HOOK" — the intent was right, only the placement was
    /// wrong, which is why a comment is no substitute for the right side of a
    /// `#if`. Before pushing anything added near those accessors, build Release.
    func setEditingAccessory(_ accessory: UIView?) {
        // ⚠️ **DEACTIVATE BEFORE ACTIVATING.** Both anchors pin the same edge, so
        // leaving the old one alive for even one pass gives Auto Layout a conflict
        // to arbitrate — and it may keep the one being replaced.
        if let accessory {
            band.show(accessory)
            backdropFromChrome.isActive = false
            backdropFromBand.isActive = true
        } else {
            band.clear()
            backdropFromBand.isActive = false
            backdropFromChrome.isActive = true
        }
        // ⚠️ **THE ONE FUNNEL EVERY BAND CHANGE GOES THROUGH, WHICH IS WHY THE
        // FOLLOWER IS STARTED AND STOPPED HERE.** Six routes install a tenant —
        // three settle hooks, the category bar, the too-short notice and crop's
        // own exit — and a link started next to only some of them would keep
        // polling a player nobody is watching for as long as the editor is open.
        follower.isPaused = accessory !== timelineTrack
        // The undo arrow's meaning changes with the band, so its enabled state
        // has to be re-decided here too.
        refreshResetItem()
        // ⚠️ THE BAND JUST MOVED THE INDICATOR, AND THE INDICATOR IS THE FOOT OF A
        // FITTED PICTURE'S WINDOW. Laying out first is what makes `fitWindow` true
        // rather than one band-height out of date.
        view.layoutIfNeeded()
        layPagesInTheirWindow(animated: true)
    }
}

#if DEBUG
extension MediaEditorViewController {
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

    /// Internal for tests: the canvas's own bounds, to compare a page against.
    var debugCanvasBounds: CGRect { canvas.bounds }

    /// Internal for tests: how many pages the canvas holds.
    var debugPageCount: Int { dataSource.snapshot().numberOfItems }
    /// Internal for tests: what the fill/fit button currently offers.
    var debugFitActionName: String? {
        navigationItem.rightBarButtonItems?.last?.accessibilityLabel
    }
    /// Internal for tests: the fit chosen for an item, defaulting as the screen does.
    func debugFit(for id: String) -> ContentFit { edits(for: id).fit }
    /// Internal for tests: the path the fill/fit button takes, without a bar to tap.
    func debugTapFit() { toggleFit() }

    /// Internal for tests: the band itself, to measure where it put things.
    var debugBand: MediaEditorBandView { band }

    /// Internal for tests: the dissolve behind the chrome, to measure where it
    /// begins, how far it reaches, and which side of the band it draws on.
    var debugBackdrop: UIView { backdrop }

    /// Internal for tests: the indicator, whose position is what the band moves.
    var debugPageDots: UIView { pageDots }

    /// Internal for tests: the categories the strip spells.
    var debugCategoryTitles: [String] { Self.categories.map(\.title) }
    /// Internal for tests: whether the picture runs under the bars.
    var debugCanvasIgnoresInsets: Bool { canvas.contentInsetAdjustmentBehavior == .never }
    /// Internal for tests: the strip itself, to read what it is wearing.
    var debugCategoryBar: IconSelectorBar { categoryBar }

    /// Internal for tests: the end of a scrub, through the very routine the
    /// track's own callback calls.
    func debugEndScrub() { scrubbing(false) }

    /// Internal for tests: one beat of the follower, through the very routine the
    /// display link calls rather than alongside it.
    func debugFollowTick() { followPlayhead() }

    /// Internal for tests: a tap on the picture, through the very routine the
    /// recogniser calls.
    func debugTapMedia() { mediaTapped() }

    /// Internal for tests: whether the canvas actually carries the tap.
    var debugMediaTapIsAttached: Bool {
        canvas.gestureRecognizers?.contains(mediaTap) ?? false
    }

    /// Internal for tests: what the track is waiting for, if anything.
    var debugHandover: MediaTimelining.Handover { handover }
    /// Internal for tests: the path "Next" takes, without a bar to tap.
    func debugTapNext() { goNext() }

    /// Internal for tests: whether the screen is in crop mode.
    var debugIsCropping: Bool { isCropping }
    /// Internal for tests: the editing surface, to drive a drag without a finger.
    var debugCropSurface: MediaCropSurfaceView { cropSurface }
    /// Internal for tests: the tools in the band, to turn the dial without one.
    var debugCropTools: MediaCropToolsView { cropTools }
    /// Internal for tests: the crop stored for an item, defaulting as the screen does.
    func debugCrop(for id: String) -> MediaCrop { edits(for: id).crop }
    /// Internal for tests: whether anything at all is stored for an item — the
    /// difference between "chose the default" and "never chose".
    func debugHasEdits(for id: String) -> Bool { edits[id] != nil }
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

    /// Internal for tests: where the picture sits on screen, in the editor's own
    /// coordinates — the only thing that can say whether a fitted picture is
    /// centred between the chrome or hanging behind it.
    func debugPictureFrame(for id: String) -> CGRect {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaEditorPageCell
        else { return .zero }
        return page.convert(page.debugPictureFrame, to: view)
    }

    /// Internal for tests: the black the crop tools stand on, if it is up at all.
    var debugCropChrome: UIView? { cropChrome.superview == nil ? nil : cropChrome }

    /// Internal for tests: where the page indicator sits, which is the foot of a
    /// fitted picture's window.
    var debugPageDotsTop: CGFloat { pageDots.frame.minY }

    /// Internal for tests: the size of the picture currently on a page.
    func debugPageImageSize(for id: String) -> CGSize {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return .zero }
        let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
        return (page as? MediaEditorPageCell)?.debugPictureSize ?? .zero
    }

    /// Internal for tests: the path the bar's undo takes, without a bar to tap.
    func debugTapResetCrop() { resetCrop() }
    /// Internal for tests: whether undo is offered, and where it lives now.
    var debugCanResetCrop: Bool { resetItem.isEnabled }
    /// Internal for tests: whether a display link is still scheduled.
    var debugFollowerIsScheduled: Bool { followerProxy.link != nil }
    /// Internal for tests: whether the bar is offering undo, and on which side.
    var debugBarOffersCropReset: Bool {
        navigationItem.leftBarButtonItems?.contains(where: { $0 === resetItem }) ?? false
    }
    /// Internal for tests: the order the leading side spells, after the chevron.
    var debugLeadingBarItems: [UIBarButtonItem] { navigationItem.leftBarButtonItems ?? [] }
    /// Internal for tests: the item undo actually is, to read its glyph.
    var debugCropResetItem: UIBarButtonItem { resetItem }

    /// Internal for tests: whether the canvas is the thing being looked at.
    var debugCanvasIsShowing: Bool { !canvas.isHidden }
    /// Internal for tests: how visible the canvas is, which `isHidden` cannot say.
    var debugCanvasAlpha: CGFloat { canvas.alpha }
    /// Internal for tests: whether the canvas can still be paged.
    var debugCanvasScrolls: Bool { canvas.isScrollEnabled }
    /// Internal for tests: how many of the stack's pans are currently suspended.
    var debugSuspendedPans: Int { suspendedPans.count }
    /// Internal for tests: whether the sheet has been told it cannot be dismissed.
    var debugSheetIsPinned: Bool { navigationController?.isModalInPresentation ?? false }
    /// Internal for tests: the path the strip's touch probe takes.
    func debugSetTouchingStrip(_ isTouching: Bool) {
        isTouchingStrip = isTouching
        updateStackGestures()
    }
    /// Internal for tests: whether the surface is in the hierarchy at all — the
    /// half of "left crop mode" that a flag cannot answer.
    var debugCropSurfaceIsShowing: Bool { cropSurface.superview != nil }
}
#endif


/// Drives a `CADisplayLink` without being held by it.
///
/// ⚠️ **THE ONLY REASON THIS EXISTS IS THE RETAIN.** `CADisplayLink(target:)`
/// holds its target strongly and the run loop holds the link, so a screen that
/// is its own target cannot be deallocated and cannot therefore invalidate the
/// link from `deinit`. The reference here is weak, and a tick that finds nobody
/// home shuts the link down rather than spinning against a dead owner.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: MediaEditorViewController?
    weak var link: CADisplayLink?

    @objc func tick() {
        guard let owner else {
            link?.invalidate()
            return
        }
        owner.followPlayhead()
    }
}
