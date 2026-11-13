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
/// ⚠️ **EVERY CATEGORY IS A MODE, AND THE SONG PILL IS NOT A CATEGORY.** Each
/// icon in the strip opens a `MediaEditorMode` of its own (`Views/Editor/`) —
/// Crop and Trim are the two the screen still serves itself. The pill beside
/// them opens the soundtrack mode, which no icon selects: a song is not one of
/// the six, and it has to be reachable from whichever one is resting.
///
/// ⚠️ **A VIDEO PLAYS HERE, AND ONLY THE PAGE THAT HAS COME TO REST.** The
/// screen owns its player behind `MediaVideoPreviewing` — one page, one binding,
/// see `playSettledPage` for why a player per page is the shape of this repo's
/// one recorded leak. No play glyph is laid over the picture: a tap on it is the
/// control every video surface already has, and the explicit one stands on the
/// trim ruler where the film is.
///
/// **The sheet becomes the whole screen here.** The flow is a stack inside a
/// page sheet that rests on a single album row, and a canvas one row tall is not
/// a canvas — so this screen states the detent it needs on the way in, and the
/// picker takes its own back on the way out.
final class MediaEditorViewController: UIViewController {
    enum Metrics {
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

    /// What the strip at the foot of the screen offers, for the medium in front
    /// of the author.
    ///
    /// ⚠️ **A PHOTOGRAPH IS NOT OFFERED THE TIMELINE.** It used to be, and
    /// choosing it put a line of text in the band saying a photo has nothing to
    /// trim — a control that reaches nothing, which is the line
    /// `dev/BACKEND_GAPS.md` §22 draws. Asked for in those words: *"lorsqu'on
    /// édite une photo, il faudrait retirer de la toolbar l'option de timeline
    /// car elle ne sert à rien"*.
    ///
    /// ⚠️ **AND A VIDEO'S LIST OPENS ON IT.** Asked for in those words: *"[timeline,
    /// baguette magique, texte, stickers, filtres, recadrement] pour une vidéo"*.
    /// The two lists are two strips, not one strip that gains an icon — see
    /// `dressCategoryStrip` — so nothing depends on Trim being last any more,
    /// and nothing may depend on an index: a category is found by its title.
    static func categories(for kind: MediaLibraryItem.Kind) -> [Category] {
        switch kind {
        case .photo: photoCategories
        case .video: videoCategories
        }
    }

    /// A photograph's list.
    static let photoCategories: [Category] = [
        Category(title: "Effects", symbol: "wand.and.stars"),
        Category(title: "Text", symbol: "textformat"),
        Category(title: "Stickers", symbol: "face.smiling"),
        Category(title: "Filters", symbol: "camera.filters"),
        // Crop and straighten are one mode and one icon: the viewer reaches for
        // the same tool to square a horizon and to cut a border away.
        Category(title: "Crop", symbol: "crop.rotate")
    ]

    /// A video's list: the timeline, then everything a photograph is offered.
    static let videoCategories: [Category] = [
        // ⚠️ `timeline.selection` EXISTS — ASKED OF THE RUNTIME, NOT ASSUMED.
        // A name that does not resolve draws an empty capsule and nothing
        // errors; this strip shipped one once
        // (`arrow.trianglehead.counterclockwise.rotate`). The plist lookups are
        // unreliable across bundles; `UIImage(systemName:)` inside the simulator
        // is the instrument that cannot be wrong.
        Category(title: "Trim", symbol: "timeline.selection")
    ] + photoCategories

    // ⚠️ **INTERNAL WHERE A MODE OR THE HOST FILE READS IT, PRIVATE ELSEWHERE.**
    // The modes live in their own files (`Views/Editor/`) and reach the screen
    // through `MediaEditorHosting`, whose conformance is in
    // `MediaEditorViewController+Host.swift` — and a `private` member is
    // invisible from another file.
    let items: [MediaLibraryItem]
    let itemsByID: [String: MediaLibraryItem]
    let library: any MediaLibraryReading
    /// Plays the settled page's clip. Owned by this screen, pool and all.
    let preview: any MediaVideoPreviewing
    /// Which item the preview is currently bound to, if any — so a settle that
    /// lands back on the same page does not restart it.
    var playingID: String?
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
    private(set) var canvas: CarouselCollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    /// ⚠️ **NOT `PagedTabBar`, AND THE DIFFERENCE IS THE CONTRACT.** That bar is
    /// built for tabs standing over a pager: a drag publishes a fractional page
    /// and the PAGER answers where it lands. Seven screens are right to use it.
    /// This one has no pager — its categories switch a mode, they do not turn a
    /// page — so that contract had nothing on the other end, and the screen spent
    /// a release driving the bar by hand and still needing a tap after every
    /// slide. `IconSelectorBar` is the same gesture with the contract this screen
    /// actually has.
    ///
    /// ⚠️ **TWO STRIPS, ONE PER MEDIUM, EACH BUILT ONCE WITH ITS WHOLE LIST.**
    /// There used to be one strip that gained the timeline's icon on a video
    /// and lost it on a photograph, handed over again under the same
    /// identifier. UIKit read that as "the same item, new content" and played
    /// its replace transition — which the author saw as the whole strip
    /// scaling in by hand, and said so: *"c'est pire qu'avant"*. What was asked
    /// for instead, in those words: change the selector's ENTIRE content and
    /// name it by that content, so the only animation is the bar's own. Each
    /// strip's identifier is its list (`ItemID.categories(_:)`), so a swipe
    /// between a photograph and a clip is one item leaving and another
    /// arriving, and UIKit alone decides how that looks.
    private let photoStrip = MediaEditorViewController.makeStrip(offering: photoCategories)
    private let videoStrip = MediaEditorViewController.makeStrip(offering: videoCategories)

    private static func makeStrip(offering list: [Category]) -> IconSelectorBar {
        IconSelectorBar(items: list.map {
            IconSelectorBar.Item(symbolName: $0.symbol, accessibilityLabel: $0.title)
        })
    }

    /// Whether the bar is wearing the video's strip — re-decided on every
    /// settle, by `dressCategoryStrip`.
    var wearsTheVideoStrip = false

    /// The strip in the bar.
    var categoryBar: IconSelectorBar { wearsTheVideoStrip ? videoStrip : photoStrip }

    /// The list the strip in the bar is offering.
    var categories: [Category] {
        wearsTheVideoStrip ? Self.videoCategories : Self.photoCategories
    }

    /// Dresses the bar for the page in front of the author.
    ///
    /// ⚠️ **THE CHOICE CROSSES OVER BY NAME.** Filters chosen on a photograph is
    /// still Filters on the clip beside it, at another index. A choice the new
    /// list does not have — Trim, swiping from a clip onto a photograph — is
    /// let go, and the band closes with it rather than keeping a track nobody
    /// can reach.
    private func dressCategoryStrip(for id: String?) {
        var isVideo = false
        if case .video? = id.flatMap({ itemsByID[$0]?.kind }) { isVideo = true }
        guard isVideo != wearsTheVideoStrip else { return }
        let standing = selectedCategory
        wearsTheVideoStrip = isVideo
        let landing = standing.flatMap { title in categories.firstIndex { $0.title == title } }
        if let landing {
            categoryBar.select(landing, notify: false)
        } else {
            categoryBar.selectNothing(notify: false)
        }
        // ⚠️ **ONE HAND-OVER, NOT TWO.** Letting Trim go closes the timeline,
        // which hands the bar its leading item back — and, since the strip in
        // the bar is already the new one, the new strip with it. Handing over
        // first and closing after was two transitions in one turn, the second
        // landing on the first: the moment the bar holds two sets at once.
        if standing != nil, landing == nil { showAccessory(for: nil) }
        refreshToolbarItems(animated: true)
    }

    /// What the leading end of the toolbar offers while the timeline is open.
    ///
    /// ⚠️ **AN ACTION BAR, NOT A SECOND SELECTOR — AND A SELECTOR COULD NOT DO
    /// IT.** `IconSelectorBar.select(_:notify:)` announces only when the index
    /// CHANGES, which is the right contract for "which mode am I in" and the
    /// wrong one for "cut here": the second tap on the scissors would be silent,
    /// so a clip could be split exactly once and the failure would read as a dead
    /// button. `IconActionBar` is the same capsule, the same 36pt segments and
    /// the same tint, momentary.
    ///
    /// ⚠️ **APPENDED, NEVER INSERTED.** The raw value is the bar's index, and the
    /// tests address the actions by it.
    enum TrackAction: Int, CaseIterable {
        case split
        case speed
        /// A look for the piece the author is holding, beside the whole-media
        /// look the category bar offers.
        case filter

        var symbolName: String {
            switch self {
            case .split: "scissors"
            case .speed: "speedometer"
            case .filter: "camera.filters"
            }
        }

        var spoken: String {
            switch self {
            case .split: "Split at the playhead"
            case .speed: "Playback speed"
            case .filter: "Filter this clip"
            }
        }
    }

    lazy var actionBar: IconActionBar = {
        let bar = IconActionBar(
            items: TrackAction.allCases.map {
                IconActionBar.Item(symbolName: $0.symbolName, accessibilityLabel: $0.spoken)
            }
        )
        // ⚠️ THE TOOLBAR ALREADY SUPPLIES A CAPSULE — see `configureCategoryStrip`
        // for what a bubble inside a bubble looks like.
        bar.hosting = .platter
        // ⚠️ **THE FILTER STARTS DEAD.** It acts on a HELD piece, and nothing is
        // held when the bar is built; `refreshTrackActions` decides it from then
        // on, but only once a clip's length is known.
        bar.setEnabled(false, at: TrackAction.filter.rawValue)
        bar.onTap = { [weak self] index in
            guard let action = TrackAction(rawValue: index) else { return }
            switch action {
            case .split: self?.splitAtTheNeedle()
            case .speed: self?.toggleTheRateChips()
            case .filter: self?.segmentFilterMode.actionTapped()
            }
        }
        // ⚠️ **IT KEEPS ITS WIDTH AND THE SELECTOR GIVES**, which is the rule the
        // sound pill already stands on: two icons cannot scroll their overflow
        // away, and the six-mode strip can.
        bar.setContentCompressionResistancePriority(.required, for: .horizontal)
        return bar
    }()

    private lazy var nextItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Next", primaryAction: UIAction { [weak self] _ in self?.goNext() })
        item.identifier = ItemID.primary
        return item
    }()

    /// What the trailing side says while a text overlay is being typed.
    ///
    /// ⚠️ **"Next" BECOMES "Done"; A SECOND BUTTON UNDER IT IS THE BUG.** The
    /// composer used to carry its own white "Done" capsule a few points below
    /// this item — *"le bouton 'Done' ne doit pas etre sous 'Next', c'est
    /// 'Next' qui devient 'Done'"* — two controls at the same corner of the
    /// screen, one putting the keyboard away and one leaving for the
    /// finalisation page. There is one now, and it means the nearer thing:
    /// finish what is being typed. "Next" comes back the moment the session
    /// ends, because leaving the screen mid-sentence is not what "Done" is for.
    private lazy var doneTypingItem = makeDoneTypingItem(hasWords: false)

    /// "Next"'s slot while typing: under "Next"'s identifier, so the bar
    /// morphs one into the other (#1679).
    private func makeDoneTypingItem(hasWords: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            primaryAction: UIAction { [weak self] _ in self?.overlayMode.finishComposing() }
        )
        item.image = Self.typingGlyph(hasWords: hasWords)
        item.accessibilityLabel = hasWords ? "Done" : "Discard"
        item.identifier = ItemID.primary
        return item
    }

    /// The glyph the one typing button wears.
    ///
    /// ⚠️ **IT IS THE SAME BUTTON AND THE SAME ACTION; ONLY THE PROMISE
    /// CHANGES.** Finishing an empty field already removes the text — that is
    /// `composed(_:)`'s documented rule — so a tick over nothing would promise
    /// to keep something that is about to be thrown away. A cross says what
    /// will actually happen. ⚠️ A new glyph is a NEW item under the slot's
    /// identifier, set animated — the bar morphs the glyph (#1679, R3) —
    /// never an image swapped on the item it shows.
    private static func typingGlyph(hasWords: Bool) -> UIImage? {
        UIImage(systemName: hasWords ? "checkmark" : "xmark")
    }

    /// Whether the composer holds any words right now — see
    /// `MediaEditorHosting.typedWordsDidChange`.
    var typedWords = false {
        didSet {
            guard typedWords != oldValue else { return }
            doneTypingItem = makeDoneTypingItem(hasWords: typedWords)
            if isTypingText { showTheTrailingItem(animated: view.window != nil) }
        }
    }

    /// States the trailing side for what the screen is doing right now.
    ///
    /// ⚠️ **THE TWO ARROWS STAND HERE, NOT WITH THE DRAFT** — asked for as
    /// *"[back][save]-----[precedent, suivant][next]"*. They left the leading
    /// side because that side is where LEAVING lives (the chevron, the draft)
    /// and the arrows are not a way out; they belong with the action that moves
    /// the work forward.
    ///
    /// ⚠️ **AND THE ORDER READS BACKWARDS HERE.** Trailing items are laid out
    /// from the edge INWARDS, so the first one written is the RIGHTMOST: this
    /// array draws `[◀][▶][Next]`.
    ///
    /// ⚠️ THE SAME ITEMS ARE NOT HANDED OVER AGAIN (#2331): the bar keeps
    /// what stays, and a list unchanged would restart a transition already
    /// running (#756).
    private func showTheTrailingItem(animated: Bool = false) {
        let items = [isTypingText ? doneTypingItem : nextItem, redoItem, undoItem]
        guard !(navigationItem.rightBarButtonItems ?? []).elementsEqual(items, by: ===) else { return }
        navigationItem.setRightBarButtonItems(items, animated: animated)
    }

    /// ⚠️ **THE HEADER WALKS THE AUTHOR'S OWN HISTORY NOW, AND THE ONE-MODE
    /// UNDO IS GONE.** It used to carry a single arrow whose meaning was the
    /// mode: Crop reset the rectangle, the timeline reset the cut, every other
    /// mode reset what it owned. Two arrows in its place — asked for as
    /// *"supprimer réinitialiser et mettre à la place des icônes de précédent et
    /// suivant, pour naviguer dans l'historique des modifications"* — so a step
    /// back is a step back whatever the author was doing when they made it, and
    /// a step they regret taking back can be taken again.
    ///
    /// ⚠️ **AND THE SYMBOLS ARE ASKED OF THE RUNTIME.** `UIImage(systemName:)`
    /// answers nil for a name this SDK does not have, and the bar draws a blank
    /// capsule that still takes taps — shipped, it reads as a rendering bug on
    /// someone's phone.
    lazy var undoItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            primaryAction: UIAction { [weak self] _ in self?.stepBack() }
        )
        item.accessibilityLabel = "Undo"
        item.identifier = ItemID.undo
        return item
    }()

    lazy var redoItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.forward"),
            primaryAction: UIAction { [weak self] _ in self?.stepForward() }
        )
        item.accessibilityLabel = "Redo"
        item.identifier = ItemID.redo
        return item
    }()

    private func resetTimeline() {
        guard let id = currentItemID else { return }
        change(id) { $0.timeline = .whole }
        timelineTrack.configure(duration: trackSeconds, timeline: .whole)
        timelineTrack.select(nil, notify: false)
        refreshHistoryItems()
        refreshTrackActions()
        refreshPreview()
    }

    /// Lights the two arrows from what the page's history actually holds.
    ///
    /// ⚠️ **NOT WHILE A CUT'S TRANSITION — OR A PIECE'S FILTER — IS BEING
    /// CHOSEN.** Stepping back there could take away the very cut, or the very
    /// piece, the row is open on, and the row would be left pointing at
    /// nothing.
    func refreshHistoryItems() {
        guard let id = currentItemID, rowFocus.transition == nil, !segmentFilterMode.isOpen,
              !isTypingText
        else {
            undoItem.isEnabled = false
            redoItem.isEnabled = false
            return
        }
        undoItem.isEnabled = session.canUndo(id)
        redoItem.isEnabled = session.canRedo(id)
    }

    /// One step back through this page's own changes — see
    /// `MediaEditSession.undo(_:)`.
    func stepBack() {
        guard let id = currentItemID, let kind = session.undo(id) else { return }
        showRestored(kind, on: id)
    }

    func stepForward() {
        guard let id = currentItemID, let kind = session.redo(id) else { return }
        showRestored(kind, on: id)
    }

    /// Tells everything that draws the page that the session put a state back
    /// on it.
    ///
    /// ⚠️ **THE SCREEN REDRAWS, THE CLIP IS REBUILT, AND EVERY MODE RE-READS.**
    /// A restored state can differ from the one on screen in any field at all —
    /// a look, a cut, an overlay, a song — so `kind` is the look or the widest
    /// change the screen has, and `editsWereRestored` is how a mode that is
    /// showing its own controls learns to state them again.
    private func showRestored(_ kind: MediaEditKind, on id: String) {
        editsDidChange(id, kind)
        refreshTimelineTrackIfShowing()
        for mode in modes { mode.editsWereRestored(for: id) }
        if isCropping { showCropPicture(for: id) }
        showTheFitGlyph()
        refreshHistoryItems()
    }

    func resetCrop() {
        guard let id = croppingID else { return }
        cropRatios[id] = .free
        cropSurface.reset()
        cropTools.adopt(angle: 0, ratio: .free)
    }

    /// What the author has decided about each picture, and the steps the two
    /// arrows walk — see `MediaEditSession`. ⚠️ **CARRIED TO THE PUBLISH PATH**
    /// by `onNext`, so nothing may quietly drop it.
    let session: MediaEditSession

    func edits(for id: String) -> MediaEdits { session.edits(for: id) }

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
    private(set) var lastSource: (id: String, image: UIImage)?

    func remember(_ image: UIImage?, for id: String) {
        guard let image else { return }
        lastSource = (id, image)
    }

    /// Lends the strip the page's own picture, if the strip is up and the
    /// picture is of the clip it is showing.
    private func offerThePosterToTheTrack(for id: String) {
        guard isTimelineShowing, currentItemID == id,
              let source = lastSource, source.id == id
        else { return }
        timelineTrack.showPoster(source.image)
    }

    /// How many renders are in flight, and the spinner that eventually says so.
    ///
    /// ⚠️ **A COUNT, NOT A FLAG.** Two renders can overlap — a look chosen while a
    /// crop is still drawing — and a flag would let the first one to finish stop
    /// the indicator for both.
    private var rendersInFlight = 0
    /// The busy stretch's pending reveal — see `beginRender`.

    private let busy: AppLoaderView = {
        let spinner = AppLoaderView(size: .large)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    /// ⚠️ **THE SPINNER WAITS BEFORE IT APPEARS, AND MOST OF THE TIME IT NEVER
    /// DOES.** A render from the held picture finishes in a few milliseconds; a
    /// spinner shown the instant work begins would flash on every tap of the
    /// selector, which reads worse than the wait it is reporting. The kit's
    /// grace and minimum (`LoaderGate`, #1768).
    private lazy var busyGate = LoaderGate(loader: busy)

    /// ⚠️ **NOT WHILE A SLIDER IS UNDER A FINGER** (`MediaEditorEffectsMode`):
    /// a render is always in flight during a drag, and the spinner would flash.
    ///
    /// ⚠️ **THE DELAY RUNS FROM THE START OF A BUSY STRETCH, AND ONE STRETCH HAS
    /// ONE TIMER.** A timer per render let render A's fire while a later render B
    /// had begun a few milliseconds earlier — the count was non-zero, so the
    /// spinner came up for B's last instants and went straight down: the flash
    /// the delay exists to prevent, on quick taps through the looks. The timer
    /// is armed when the count leaves zero and called off when it returns there.
    private func beginRender() {
        rendersInFlight += 1
        guard rendersInFlight == 1 else { return }
        busyGate.begin { [weak self] in
            guard let self else { return false }
            return rendersInFlight > 0 && !effectsMode.isTracking
        }
    }

    private func endRender() {
        rendersInFlight = max(0, rendersInFlight - 1)
        guard rendersInFlight == 0 else { return }
        busyGate.end()
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
    func render(_ source: UIImage, as chosen: MediaEdits, for id: String) {
        beginRender()
        Task.detached(priority: .userInitiated) { [weak self] in
            let drawn = Self.draw(source, as: chosen)
            await MainActor.run {
                guard let self else { return }
                // ⚠️ RE-READ AT LANDING: two renders can be in flight and whichever
                // lands last must paint what is chosen NOW, not what was chosen when
                // it started. A render that has been overtaken is simply redone.
                // ⚠️ COMPARED ON WHAT THE PAGE DRAWS — the finish without its
                // overlays. An overlay dragged across the page is a view moving,
                // and must not redo a render whose pixels it cannot change.
                if self.edits(for: id).finish(includingOverlays: false)
                    == chosen.finish(includingOverlays: false) {
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
    ///
    /// ⚠️ **NEVER THE OVERLAYS.** The page shows them as views over the picture
    /// (`MediaEditorOverlayMode`); baked in here as well, each would be drawn
    /// twice and the copy in the pixels would not follow a finger.
    nonisolated private static func draw(_ source: UIImage, as chosen: MediaEdits) -> UIImage {
        chosen.applied(to: source, artwork: nil, includingOverlays: false)
    }

    /// `image` with the page's current cut and look, drawn off the main
    /// actor; the image itself when there is nothing to draw. If the edits
    /// change while the draw runs, it runs again on the new ones, so what
    /// lands is what is chosen at landing.
    private func dressed(_ image: UIImage?, for id: String) async -> UIImage? {
        guard let image else { return nil }
        var chosen = edits(for: id)
        while true {
            guard !chosen.finish(includingOverlays: false).isNone else { return image }
            let snapshot = chosen
            let drawn = await Task.detached(priority: .userInitiated) { @Sendable in Self.draw(image, as: snapshot) }.value
            let current = edits(for: id)
            if current.finish(includingOverlays: false) == chosen.finish(includingOverlays: false) {
                return drawn
            }
            chosen = current
        }
    }

    /// Writes an edit through the session — see `MediaEditSession.change` for
    /// the rules — and re-lights the arrows once it is a step.
    func change(_ id: String, settling: Bool = true, _ mutate: (inout MediaEdits) -> Void) {
        session.change(id, settling: settling, mutate)
        guard settling else { return }
        refreshHistoryItems()
    }

    // MARK: - Modes

    /// The categories that are objects of their own, each in `Views/Editor/`.
    ///
    /// ⚠️ **BUILT LAZILY AND HELD HERE, AND EACH HOLDS THIS SCREEN WEAKLY.** The
    /// screen is the only owner; a mode that held its host strongly would be a
    /// cycle nothing breaks.
    ///
    /// Trim and Crop are not among them: both are older than the split and live
    /// in this file.
    private(set) lazy var effectsMode = MediaEditorEffectsMode(host: self)
    private(set) lazy var filtersMode = MediaEditorFiltersMode(host: self)
    /// The look of one PIECE of a clip — opened from the timeline's action bar,
    /// not from the category bar.
    private(set) lazy var segmentFilterMode = MediaEditorSegmentFilterMode(host: self)
    /// Text and Stickers: one mode, told which of the two it is before it opens.
    private(set) lazy var overlayMode = MediaEditorOverlayMode(host: self)

    /// Whether a text overlay is being typed over this screen right now — set
    /// by `MediaEditorHosting.textEditingDidChange(_:)`, which the overlay mode
    /// calls once at each end of a typing session.
    ///
    /// ⚠️ **THE SEAM ONLY: NOTHING HERE TOUCHES A BAR ITEM.** "Next" is meant
    /// to read "Done" while this is true, and the composer's own Done button is
    /// meant to go with it. Both are changes to `navigationItem`, which one
    /// worker owns at a time; this property is what that change reads. Not
    /// `private(set)`: the conformance lives in
    /// `MediaEditorViewController+Host.swift`, and `private` is per FILE.
    var isTypingText = false {
        didSet {
            showTheTrailingItem(animated: true)
            // ⚠️ **AND THE ARROWS GO DEAD FOR THE LENGTH OF THE SESSION.** A
            // step back while the composer is up would put an edit on the page
            // that the open composer knows nothing about — including one that
            // takes away the very overlay being typed, which leaves a field
            // with no destination. Same rule as a transition row's.
            refreshHistoryItems()
            #if DEBUG
            textEditingChanges.append(isTypingText)
            #endif
        }
    }

    #if DEBUG
    /// Internal for tests: every value `isTypingText` has been HANDED, in
    /// order, deduped nowhere — so a mode that announced one session twice is
    /// visible here as `[true, false, false]`.
    private(set) var textEditingChanges: [Bool] = []
    #endif
    /// The song under a clip — opened from the sound pill, not from the
    /// category bar.
    private(set) lazy var soundtrackMode = MediaEditorSoundtrackMode(host: self, sourcing: soundtracks)

    /// Where "Add a song" finds the author's songs.
    private let soundtracks: any MediaSoundtrackSourcing

    /// Every mode, for the moments each of them has to hear about: the band
    /// changing, a page settling, the screen going.
    var modes: [any MediaEditorMode] {
        [effectsMode, filtersMode, segmentFilterMode, overlayMode, soundtrackMode]
    }

    /// The mode whose tools the band is holding, if any.
    private var showingMode: (any MediaEditorMode)? {
        guard let content = band.content else { return nil }
        return modes.first { $0.tenant === content }
    }

    /// The mode behind the category the bar has chosen — nil for Trim and Crop,
    /// which are not mode objects.
    private var selectedMode: (any MediaEditorMode)? {
        switch selectedCategory {
        case "Effects": effectsMode
        case "Text", "Stickers": overlayMode
        case "Filters": filtersMode
        default: nil
        }
    }

    /// Opens a category's mode on the page in front of the author.
    func open(_ mode: any MediaEditorMode) {
        guard let id = currentItemID, let item = itemsByID[id] else {
            setEditingAccessory(nil, animated: true)
            return
        }
        mode.open(for: id, item: item)
    }

    /// The category the bar has chosen was tapped again.
    ///
    /// ⚠️ **ONLY WHEN ITS TOOLS ARE NOT ALREADY UP.** A repeat tap on a mode that
    /// is showing does nothing, as it always has; one whose tools were put away
    /// while its icon stayed chosen — or never shown, like Effects, chosen at
    /// launch over an empty band — opens again. A mode with nothing to show
    /// (`tenant == nil`) is left alone, so the band is not re-stated for
    /// nothing.
    /// ⚠️ **A SECOND TAP PUTS THE TOOLS AWAY.** Asked for in those words: the
    /// strip has a neutral state, it is what the screen opens on, and tapping
    /// the icon that is already chosen returns to it. The tools that were open
    /// are closed by `showAccessory(for: nil)`, which also unwinds crop.
    ///
    /// The one exception is a mode whose tools are not up yet — choosing a
    /// category and then swiping to a page that mode cannot serve leaves the
    /// band on a notice — where a repeat tap re-opens rather than closes.
    private func categoryReselected() {
        if let mode = selectedMode, let tenant = mode.tenant, band.content !== tenant {
            showAccessory(for: selectedCategory)
            return
        }
        categoryBar.selectNothing(notify: false)
        showAccessory(for: nil)
    }

    /// Which glyph the bar is currently wearing, so the item is only re-stated

    /// Which of several media is showing. Hides itself for a single one.
    let pageDots = MediaPageDotsView()

    /// The reserved strip an editing control is put into — see
    /// `MediaEditorBandView`. It holds the row of looks while "Filters" is the
    /// chosen category, and collapses to nothing otherwise.
    let band = MediaEditorBandView()

    /// The dissolve the chrome sits on: clear where it begins, full material at
    /// the foot of the screen, so the picture runs on underneath and merely loses
    /// definition as it passes behind the controls.
    ///
    /// ⚠️ **IT IS NEVER HIDDEN — THE TOP ANCHOR IS THE DIAL.** The picker learned
    /// this on its own copy: an earlier cut there set `isHidden` and took the
    /// whole band away instead of shortening it. Here the two constraints below
    /// swap, and the view stays.
    let backdrop = ProgressiveBlurView()

    /// Where the dissolve begins when the band is holding something: the band's
    /// own top edge, so the ramp starts exactly where the controls do.
    var backdropFromBand: NSLayoutConstraint!

    /// And where it begins when the band is empty: the top of the toolbar.
    ///
    /// ⚠️ **THESE ARE NOT THE SAME POINT, WHICH IS WHY THERE ARE TWO.** An empty
    /// band collapses to zero height at `safeArea.bottom - Spacing.sm`, so hanging
    /// the dissolve from `band.topAnchor` alone would start it 8pt above the
    /// toolbar rather than at it.
    var backdropFromChrome: NSLayoutConstraint!

    /// What the toolbar appearance was before this screen borrowed it. The
    /// toolbar belongs to the STACK, and the picker underneath draws its album
    /// strip in the same one.
    private var restoreToolbar: (() -> Void)?

    #if DEBUG
    /// Guards `-upload-post` against firing twice: `viewDidAppear` runs again
    /// every time the finalisation screen is popped back off this one.
    /// Internal (not private) only for the +QA hooks.
    var hasAutoAdvanced = false

    /// The same guard for `-upload-category`, which would otherwise reopen the
    /// band on every return from the finalisation screen.
    /// Internal (not private) only for the +QA hooks.
    var hasSelectedDebugCategory = false

    /// The same guard for `-upload-seed-cuts` — see `seedDebugCuts`.
    /// Internal (not private) only for the +QA hooks.
    var hasSeededDebugCuts = false
    #endif

    /// Opens the song tools (`MediaEditorSoundtrackMode`), and names the song
    /// once one is chosen. The same control the text-post composer uses, which
    /// is why it lives in DesignSystem.
    ///
    /// ⚠️ **CROP IS LEFT FIRST, AS CHOOSING ANY OTHER MODE LEAVES IT.** The pill
    /// stays tappable under the crop surface, and a band handed to the song
    /// tools with the surface still up would leave the canvas locked behind
    /// tools that have nothing to do with it.
    lazy var soundPill: SoundPillView = {
        let pill = SoundPillView(title: MediaEditorSoundtrackMode.addTitle, neverTruncates: true)
        pill.onTap = { [weak self] in
            guard let self else { return }
            if isCropping { exitCrop() }
            soundtrackMode.toggle()
        }
        return pill
    }()

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
        item.identifier = ItemID.saveDraft
        return item
    }()

    init(
        items: [MediaLibraryItem],
        library: any MediaLibraryReading,
        preview: any MediaVideoPreviewing = MediaPreviewPlayer(),
        soundtracks: any MediaSoundtrackSourcing = SystemSoundtrackSource(),
        initialEdits: [String: MediaEdits] = [:],
        onNext: @escaping ([MediaLibraryItem], [String: MediaEdits]) -> UIViewController
    ) {
        self.items = items
        self.itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // What the media arrive wearing is where the editing starts, not a step
        // — see `MediaEditSession.init`.
        self.session = MediaEditSession(initial: initialEdits, ids: items.map(\.id))
        self.library = library
        self.preview = preview
        self.soundtracks = soundtracks
        self.onNext = onNext
        // ⚠️ **THE STRIP IS RIGHT FROM THE FIRST HAND-OVER.** The screen opens
        // on the first item, and dressed only by a settle or an appearance, a
        // screen opening on a clip handed the bar a photograph's strip and then
        // swapped it, animated, in front of the author arriving.
        if case .video? = items.first?.kind { self.wearsTheVideoStrip = true }
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
        // ⚠️ **THE ARROWS ARE ASKED WHAT THEY CAN DO BEFORE THEY ARE FIRST
        // DRAWN.** `UIBarButtonItem.isEnabled` is TRUE at birth, so a screen
        // that only ever re-decides them on a change opens with two live arrows
        // over a photograph nobody has touched — `stepBack` finds no step,
        // returns, and the author taps a control that does nothing. Seen on the
        // simulator before it was seen here.
        //
        // ⚠️ **AND AFTER THE CANVAS, NOT IN `configureBars`.** The answer is
        // `session.canUndo(currentItemID)`, and `currentItemID` reads the
        // canvas's own offset: asked from the bars, which are stated first, it
        // traps on a canvas that does not exist yet.
        refreshHistoryItems()
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
        // ⚠️ **WARMED HERE, OR THE FIRST POP IS THE LATE ONE.** A first `play()`
        // decodes the file and opens the route — tens of milliseconds on a cold
        // app, which is long enough for the first element of the first row to
        // be seen landing before it is heard.
        UISound.prepare()
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
        exitCrop(resuming: false)
        // ⚠️ **AND EVERY MODE UNWINDS WHAT IT HOLDS, FOR THE REASON CROP DOES** —
        // "Next" pushes from the middle of any of them, and a lock, a sheet or a
        // keyboard left behind would be inherited by the finalisation screen.
        for mode in modes { mode.screenWillDisappear() }
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
        dressCategoryStrip(for: currentItemID)
        playSettledPage()
        #if DEBUG
        logCanvas("didAppear")
        runDebugAppearanceHooks()
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
            // ⚠️ AND ITS OVERLAYS, FOR THE SAME REASON: they are views over the
            // picture, never pixels in it (`includingOverlays: false` below).
            overlayMode.dress(cell, for: id)
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
                // ⚠️ DRESSED OFF THE MAIN ACTOR (charter P13). This ran
                // `applied(to:)` — a CoreImage render — right here, on the
                // main actor, for every page of a reopened draft that had a
                // cut or a look; `-presentation-budget` counted it inside the
                // editor's arrival. The same detached draw `render` uses, and
                // the same re-read at landing: the edits are checked again
                // once the pixels are back, and drawn once more if they moved.
                let dressed = await self.dressed(image, for: id)
                cell?.show(dressed, for: id)
                // ⚠️ **AND THE TRACK IS WAITING FOR THIS SAME PICTURE.** Opening
                // the timeline hands over whatever `lastSource` holds, which on a
                // page that has just been swiped to is still the PREVIOUS clip's
                // — so it hands over nothing rather than the wrong film, and the
                // strip would stand on its skeleton until a decoded frame
                // arrived. This is the moment the right one exists.
                self.offerThePosterToTheTrack(for: id)
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

    /// Lays the screen out after the band changed height, moving a fitted
    /// picture with it.
    ///
    /// ⚠️ **THE PAGES ARE LAID BY THE LAYOUT PASS ITSELF, SO THAT PASS IS WHAT
    /// MUST ANIMATE.** Every call site used to lay the screen out and THEN ask
    /// for an animated lay — by which time `viewDidLayoutSubviews` had already
    /// laid every page unanimated, and the animated call found nothing left to
    /// move. The picture jumped each time a row of rates, a row of lengths or
    /// a new tenant resized the band, while every one of those lines said it
    /// animated.
    func followTheBand(animated: Bool) {
        laysPagesAnimated = animated && view.window != nil
        defer { laysPagesAnimated = false }
        view.layoutIfNeeded()
    }

    /// Whether the layout pass in progress moves the pages rather than
    /// placing them — see `followTheBand`.
    private var laysPagesAnimated = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layPagesInTheirWindow(animated: laysPagesAnimated)
        // The toolbar's width is only knowable once something has laid it out,
        // and it changes with rotation and with the sheet's own size.
        let held = shareTheBarBetweenTheTwoStrips()
        guard !isHandingOver else { return }
        let moved = zip([handedWidths?.leading, handedWidths?.trailing], [held?.leading, held?.trailing])
            .contains { abs(($0 ?? -1) - ($1 ?? -2)) > 0.5 }
        if owesAHandover || moved { refreshToolbarItems(animated: false) }
    }

    /// The size a full-page picture is asked for, in points.
    var canvasSize: CGSize {
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
        // `[‹][save] ⋯ [◀][▶][next]` — the leading side is the ways OUT of this
        // screen, and nothing else.
        navigationItem.leftBarButtonItems = [saveDraftItem]
        navigationItem.leftItemsSupplementBackButton = true
        // The chevron the NEXT screen wears, kept wordless if a title ever lands
        // here.
        navigationItem.backButtonDisplayMode = .minimal
        // ⚠️ **ONE ITEM ON THE TRAILING SIDE, AND WHICH ONE IS THE SCREEN'S
        // STATE.** The fill/fit glyph used to stand beside it and has gone to
        // the crop tools; what shares the slot now is "Done", for the length of
        // a typing session — see `showTheTrailingItem`.
        showTheTrailingItem()
        nextItem.style = .done
    }

    private func configureCategoryStrip() {
        // Both strips are dressed alike: either may be the one in the bar.
        for strip in [photoStrip, videoStrip] { configure(strip) }
        // ⚠️ **BOTH STRIPS, ONE PROBE — AND THE PROBE COUNTS.** A finger sliding
        // off one bar onto the other used to announce "nothing is being touched"
        // while a finger was still down, which put the stack's back-swipe back
        // underneath it. See `SelectorTouchProbe`.
        touchProbe.attach(to: actionBar)
        // [song][categories], both leading, with the flexible space pushing them
        // left together. The fixed space keeps them two bubbles rather than one
        // platter — the same spacing the composer's own footer uses between its
        // pill and the buttons beside it.
        refreshToolbarItems(animated: false)
    }

    private func configure(_ strip: IconSelectorBar) {
        // ⚠️ **THE TOOLBAR ALREADY SUPPLIES A CAPSULE.** iOS composites every bar
        // item through its own neutral glass, so a strip carrying its own
        // backdrop renders as a bubble inside a bubble — the defect the picker's
        // first cut shipped.
        strip.hosting = .platter
        // ⚠️ **THE PILL DOES NOT MOVE ITSELF — AND THIS COMMENT USED TO CLAIM IT
        // DID.** `PagedTabBar` answers a tap by setting `selectedIndex` and
        // sending `.valueChanged`; the pill is placed by `applyProgress`, which
        // only `setProgress` calls, and every screen that works drives that from
        // a pager reporting its scroll. This screen has no pager, so with no
        // action wired the tap looked dead — which is exactly how it was
        // reported. It states the position itself instead.
        //
        // Choosing one now opens the mode behind it — `showAccessory(for:)` is
        // where the strip's index becomes a band tenant.
        // ⚠️ **ONE CHANNEL FOR TAP AND SLIDE ALIKE.** The bar this replaced
        // announced a tap through `.valueChanged` and a drag through nothing at
        // all, on the reasoning that a pager would answer for the drag — correct
        // for a screen that has one. This screen does not, so a slide went
        // unheard and the viewer had to tap to finish what it had already
        // decided. Reported from a device.
        strip.onSelect = { [weak self] _ in self?.categoryChanged() }
        // ⚠️ **A TAP ON THE CHOSEN ICON IS HEARD TOO.** `onSelect` is silent on
        // it, and Effects is chosen at launch over an empty band: without this
        // the first mode could never be opened on first entry.
        strip.onReselect = { [weak self] _ in self?.categoryReselected() }
        // The strip can lose the item it was on when the medium changes; the
        // band closes with it.
        strip.onSelectNothing = { [weak self] in self?.showAccessory(for: nil) }
        // ⚠️ **THE SCREEN OPENS ON NOTHING.** It used to open with Effects
        // chosen over an EMPTY band, so the one filled icon was a promise the
        // band did not keep and the first tap on it was a reselect.
        strip.selectNothing(notify: false)
        touchProbe.attach(to: strip)
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
        strip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// ⚠️ **THE LEADING CONTROL IS THE MODE'S, AND THE SONG PILL IS ONLY ITS
    /// DEFAULT.** The pill opens the song tools, so the slot is never free — the
    /// bar simply cannot hold both it and the track's actions on a phone (see
    /// `shareTheBarBetweenTheTwoStrips`, where a third action already overran an
    /// SE), and while the timeline is open the actions are what the finger is
    /// reaching for. Charter F18, asked for in exactly those words: with the mode
    /// on, the bottom-left pill is replaced by a second bar carrying split and
    /// speed.
    func refreshToolbarItems(animated: Bool) {
        // ⚠️ **NOTHING IS HANDED OVER BEFORE THE BAR CAN HOLD IT.** UIKit
        // decides whether an item fits ONCE, from the size its view has at the
        // hand-over, and never reconsiders. The first call comes from
        // `viewDidLoad`, where the toolbar is still hidden and its width is
        // zero: `shareTheBarBetweenTheTwoStrips` then takes its own early
        // return, turns both width constraints OFF and writes no frames, and
        // the six-category strip goes over at its FULL intrinsic width beside a
        // pill at its full width. The two overran the bar and iOS swept the
        // strip into a `•••` — photographed by the author on an iPhone 18 Pro,
        // where there is otherwise room to spare.
        // ⚠️ **ON SCREEN, NOT MERELY NON-ZERO.** A `UIToolbar` that has never
        // been in a window already answers the SCREEN's width — measured: 402
        // on an iPhone 18 Pro, from `viewDidLoad`, before anything was laid
        // out. So "does it have a width" is a question that is always yes and
        // never true: the first hand-over was measured against a bar that does
        // not exist yet, and is right only where the sheet happens to be as
        // wide as the screen.
        // ⚠️ **AND THE TOOLBAR'S OWN WINDOW IS TOO STRICT TO ASK FOR**: the bar
        // is hidden until `viewWillAppear` raises it, so waiting on it would
        // leave the screen with no items at all in every flow that never runs
        // an appearance transition. This screen's own window is the moment its
        // widths become real.
        guard view.window != nil, (navigationController?.toolbar.bounds.width ?? 0) > 0 else {
            owesAHandover = true
            return
        }
        guard !isHandingOver else { return }
        isHandingOver = true
        defer { isHandingOver = false }
        owesAHandover = false
        let leading: UIView = isTimelineShowing ? actionBar : soundPill
        refreshSoundPill()
        // ⚠️ **BEFORE THE HAND-OVER, NOT AFTER**, for the same reason: held
        // afterwards, the two strips were measured at their full widths and
        // swept into a `•••` on an iPhone SE.
        handedWidths = shareTheBarBetweenTheTwoStrips()
        #if DEBUG
        debugHandoverWidths.append(view.window == nil ? 0 : (navigationController?.toolbar.bounds.width ?? 0))
        debugOnToolbarHandover?()
        #endif
        // ⚠️ **THE SAME VIEWS IN THE SAME PLACES ARE NOT HANDED OVER AGAIN.**
        // A hand-over that changes nothing is not free: UIKit starts a
        // transition for it, and a transition started while another is still
        // running is the moment the bar holds two sets of items at once.
        let held = toolbarItems ?? []
        // A swipe between a photograph and a clip is never skipped by this: the
        // strip in the bar is then ANOTHER view (`dressCategoryStrip`).
        let unchanged = held.count == 3
            && held[0].customView === leading
            && held[2].customView === categoryBar
        if !unchanged {
            #if DEBUG
            debugRealHandovers += 1
            debugLastHandoverWasAnimated = animated
            #endif
            // The selector stands at the TRAILING edge and the slack sits
            // between the two groups: it is as wide as it needs to be, never
            // as wide as the room (asked 2026-09-23 — it used to fill the
            // room whatever its five or three icons wanted).
            setToolbarItems(
                [
                    Self.barItem(leading, as: ItemID.leading),
                    .flexibleSpace(),
                    Self.barItem(categoryBar, as: ItemID.categories(categories))
                ],
                animated: animated
            )
        }
        handedWidths = shareTheBarBetweenTheTwoStrips()
    }

    // MARK: - The bar's items — state here, behaviour in `MediaEditorViewController+BarItems.swift`
    /// A hand-over the bar could not take yet, owed to the first layout pass
    /// that gives it a width.
    private var owesAHandover = false
    /// ⚠️ **`setToolbarItems` LAYS THE BAR OUT, AND THIS IS CALLED FROM THAT
    /// LAYOUT.** Without the flag, handing over re-enters itself.
    private var isHandingOver = false
    /// The two widths the bar was last HANDED.
    ///
    /// ⚠️ **A WIDTH THAT HAS MOVED SINCE IS A WIDTH UIKit IS NOT HONOURING.**
    /// The pill's title becomes a song's name while the screen is up
    /// (`refreshSoundPill`), and nothing re-hands anything for it. Comparing
    /// what was handed against what the rule now says is what catches it,
    /// without the call site having to know about the bar.
    private var handedWidths: (leading: CGFloat, trailing: CGFloat)?
    /// What the bar charges around its items — measured once it has hosted
    /// two neighbours, the SE's numbers until then.
    var barGeometry = ToolbarGeometry.fallback
    /// Internal for tests: runs just before the bar is handed its items.
    var debugOnToolbarHandover: (() -> Void)?
    /// Internal for tests: how many elements each arrival staged, in order —
    /// the choreography's DECISION, which is the half a test can see. The
    /// drawing is a presentation-layer value that only exists while a curve is
    /// actually running (`uiview-animate-from-value-trap`).
    var debugPopIns: [Int] = []
    /// Internal for tests: how many tenants were animated out.
    var debugPopOuts = 0
    /// Internal for tests: how many surfaces each arrival swept, in order.
    var debugReveals: [Int] = []
    /// Internal for tests: how many times the bar was ACTUALLY handed a new
    /// set of items — as opposed to asked to, which is `debugHandoverWidths`.
    private(set) var debugRealHandovers = 0
    /// Internal for tests: whether the last real hand-over asked UIKit to
    /// animate it.
    private(set) var debugLastHandoverWasAnimated = false
    /// Internal for tests: the toolbar's width at each hand-over, in order.
    /// Every one of them must be greater than zero — see `refreshToolbarItems`.
    private(set) var debugHandoverWidths: [CGFloat] = []
    lazy var actionBarWidth: NSLayoutConstraint =
        actionBar.widthAnchor.constraint(equalToConstant: IconActionBar.height)
    /// The pill's ceiling — see `shareTheBarBetweenTheTwoStrips`. Always on,
    /// and inert until a title is long enough to crowd the selector out.
    lazy var soundPillCap: NSLayoutConstraint = {
        let cap = soundPill.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        cap.isActive = true
        return cap
    }()
    lazy var photoStripWidth: NSLayoutConstraint =
        photoStrip.widthAnchor.constraint(equalToConstant: IconSelectorBar.height)
    lazy var videoStripWidth: NSLayoutConstraint =
        videoStrip.widthAnchor.constraint(equalToConstant: IconSelectorBar.height)
    /// How long the clip the track is showing actually runs.
    ///
    /// ⚠️ **THE FILE'S LENGTH, AND IT IS WHAT TURNS A SCRUB INTO A SEEK.** The
    /// track speaks in seconds of the file and the player takes a FRACTION of it;
    /// dividing by the declared duration instead would scrub to the wrong moment
    /// on exactly the clips whose declaration is wrong — the ones the reload
    /// above exists for.
    var trackSeconds: Double = 0
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
    lazy var follower: CADisplayLink = {
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
    var probeBeats = 0
    var probeWorstGap: CFTimeInterval = 0
    var probeLastBeat: CFTimeInterval = 0
    var probeWindowStart: CFTimeInterval = 0
    /// Whether the track has opened on a clip and not yet been put where the
    /// player is.
    var trackNeedsPlacement = false
    /// Whether something is standing over the editor — a picker, a sheet.
    ///
    /// ⚠️ **READ, NOT STORED.** A flag would have to be lowered by whoever
    /// raised it, and a path that forgot would leave the clip stopped for good;
    /// `presentedViewController` is the truth and cannot go stale. It is a THIRD
    /// term beside the finger and the author's own pause, and it is never
    /// written into `pausedByAuthor` — a cover is not a decision the author
    /// made, and treating it as one would leave the clip stopped after the
    /// sheet had gone.
    var isCovered: Bool { presentedViewController != nil }
    var previewSubject: PreviewSubject?
    /// Bumped for every load asked for: only the newest may land.
    var previewLoads = 0
    /// Whether a load is on its way, during which the player's clock describes
    /// an item that is about to go.
    var previewPending = false
    /// Whether a finger is on the track — what a load that lands decides the
    /// pause from.
    var fingerOnTrack = false
    /// The FILE second a held handle last aimed at, so a creeping edge gets a
    /// tight seek and a flung one a loose one.
    var lastAimedSeconds: Double?
    /// The file's real length, per clip, once asked.
    var fileLengths: [String: Double] = [:]
    var lastAnsweredNeedle: Double = .infinity
    /// What the track is waiting for before it lets the player move it again.
    var handover: MediaTimelining.Handover = .settled
    /// Where the author last put the needle, so the handover knows what arrival
    /// to wait for. Nil when this gesture has not moved anything.
    var lastScrubbedSeconds: Double?
    var boundSurface: VideoRenderView?

    // MARK: - Fill or fit

    /// Which page the canvas is resting on. Read from the offset rather than
    /// stored: the canvas pages itself, and a stored index drifts the moment a
    /// swipe is interrupted.
    var currentIndex: Int {
        guard canvas.bounds.width > 0, !items.isEmpty else { return 0 }
        let page = Int((canvas.contentOffset.x / canvas.bounds.width).rounded())
        return min(max(page, 0), items.count - 1)
    }

    var currentItemID: String? {
        items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    }

    private var currentFit: ContentFit {
        currentItemID.map { edits(for: $0).fit } ?? .fill
    }

    func toggleFit() {
        guard let id = currentItemID else { return }
        let next = edits(for: id).fit.toggled
        change(id) { $0.fit = next }
        let page = canvas.cellForItem(at: IndexPath(item: currentIndex, section: 0))
        (page as? MediaEditorPageCell)?.lay(next, within: fitWindow, animated: true)
        showTheFitGlyph()
    }

    /// Keeps the crop tools' glyph offering the move the author can actually
    /// make on the picture in front of them — including after a swipe, when
    /// the next picture may have been left in the other state.
    ///
    /// ⚠️ **IT LIVES IN THE CROP TOOLS NOW, NOT IN THE HEADER**, so there is no
    /// bar item to replace and none of the identity dance that went with it: a
    /// `UIBarButtonItem`'s glyph only animates when the ITEM is swapped, which
    /// is why this used to rebuild one and guard against rebuilding it too
    /// often. A button's image is just an image.
    private func showTheFitGlyph() {
        let fit = currentFit
        cropTools.showFit(symbol: fit.symbolName, label: fit.actionName)
    }

    /// The header while the crop surface is up.
    ///
    /// ⚠️ **IT NO LONGER SWAPS THE FILL/FIT GLYPH IN AND OUT.** That control
    /// used to stand in the header and leave for the duration of the mode,
    /// because while the author is deciding what the picture even IS there is
    /// nothing for it to act on. It now lives in the crop tools themselves,
    /// where it is only reachable at exactly the moment it means something.
    func showCropBarItems(_ isCropping: Bool, animated: Bool) {
        // The same draft item again is not handed over (#2331).
        if navigationItem.leftBarButtonItems ?? [] != [saveDraftItem] {
            navigationItem.setLeftBarButtonItems([saveDraftItem], animated: animated)
        }
        showTheTrailingItem(animated: animated)
    }

    func goNext() {
        navigationController?.pushViewController(onNext(items, session.edits), animated: true)
    }

    // MARK: - Cropping

    /// The tools the band holds while "Crop" is the chosen mode.
    ///
    /// ⚠️ BUILT ONCE, like the filter row and for the same reason: reopening a
    /// band should not rebuild the controls inside it.
    lazy var cropTools: MediaCropToolsView = {
        let tools = MediaCropToolsView()
        // ⚠️ **THE DIAL TURNS THE PICTURE PER FRAME AND FILES ONE STEP.** The
        // surface states its crop on every sample, deliberately — the picture
        // has to turn under the finger — so the moment the dial says the finger
        // is down is the moment the history must be told to hold.
        tools.onTurn = { [weak self] angle in
            self?.isTurningTheDial = true
            self?.cropSurface.setAngle(angle)
        }
        tools.onTurnSettled = { [weak self] angle in
            guard let self else { return }
            isTurningTheDial = false
            cropSurface.setAngle(angle)
        }
        tools.onRatio = { [weak self] ratio in
            guard let self, let id = currentItemID else { return }
            cropRatios[id] = ratio
            cropSurface.choose(ratio)
        }
        tools.onQuarterTurn = { [weak self] in self?.cropSurface.turnQuarter() }
        tools.onFlip = { [weak self] in self?.cropSurface.flipAcross() }
        tools.onFit = { [weak self] in self?.toggleFit() }
        return tools
    }()

    lazy var cropSurface: MediaCropSurfaceView = {
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

    /// The clip as a strip of film pushed past a fixed needle, with the rate
    /// chips above it when they have been asked for.
    ///
    /// ⚠️ **THE BAND'S TENANT IS THE HOST, NOT THE TRACK — AND EVERY IDENTITY
    /// CHECK GOES THROUGH `isTimelineShowing` FOR THAT REASON.** Eight places ask
    /// "is the band holding the timeline", and eight `band.content ===
    /// timelineTrack` comparisons would ALL have gone quietly false the day a
    /// second control joined the track inside it: the follower would stop, the
    /// settle hooks would stop re-targeting, and the reset arrow would start
    /// answering for crop. One name, one edit.
    lazy var timelineTools: MediaTimelineToolsView = {
        let tools = MediaTimelineToolsView()
        let track = tools.track
        track.onChange = { [weak self] timeline in
            guard let self, let id = currentItemID else { return }
            change(id) { $0.timeline = timeline }
            refreshHistoryItems()
            refreshTrackActions()
            // ⚠️ **THE PREVIEW PLAYS THE EDIT.** A handle release, a carry, a
            // spoken adjustment: the arrangement changed, or a handle had the
            // file on screen, and either way the item has to catch up.
            refreshPreview()
        }
        track.onScrub = { [weak self] moment in
            self?.scrubbed(to: moment)
            self?.refreshTrackActions()
        }
        track.onScrubbing = { [weak self] scrubbing in
            self?.scrubbing(scrubbing)
        }
        track.onPlayPause = { [weak self] in
            self?.togglePreviewPlayback()
        }
        track.onSelect = { [weak self] _ in
            // What the rate chips speak for has just changed, and so has what a
            // tap on them will set.
            self?.refreshTrackActions()
        }
        tools.speeds.onPick = { [weak self] rate in
            self?.chooseRate(rate)
        }
        track.onSeam = { [weak self] seam in
            self?.openTransitions(atSeam: seam)
        }
        tools.transitions.onPick = { [weak self] kind in
            self?.chooseTransition(kind)
        }
        tools.transitions.onClose = { [weak self] in
            self?.closeTransitions(animated: true)
        }
        tools.onTransitionDuration = { [weak self] seconds in
            self?.chooseTransitionDuration(seconds)
        }
        // ⚠️ THE LENGTHS RAISE AND LOWER THE BAND, AND THE BAND IS THE FOOT OF
        // A FITTED PICTURE'S WINDOW — the rate chips' two lines, for their
        // reason (`toggleTheRateChips`).
        // ⚠️ **ONLY WHILE THE TOOLS ARE THE BAND'S TENANT.** Leaving the
        // timeline with the lengths up closes the row, which lowers them — and
        // that callback, laying the screen out in the middle of
        // `setEditingAccessory`, handed the bar over UNANIMATED from inside the
        // layout pass, before the animated hand-over that follows could; that
        // one then found nothing to change. `setEditingAccessory` follows the
        // band itself once the new tenant is in.
        tools.onHeightChange = { [weak self] in
            guard let self, isTimelineShowing else { return }
            followTheBand(animated: true)
        }
        tools.segmentFilters.onPick = { [weak self] filter in
            self?.chooseSegmentFilter(filter)
        }
        tools.segmentFilters.onClose = { [weak self] in
            self?.closeSegmentFilters(animated: true)
        }
        return tools
    }()

    var timelineTrack: MediaTimelineTrackView { timelineTools.track }

    // MARK: - Choosing a cut's transition and a piece's filter — state here, behaviour in `MediaEditorViewController+TransitionsAndFilters.swift`
    /// Which row the timeline has open, on which clip, and the author's pause
    /// it borrowed — see `MediaTimelineRowFocus`.
    var rowFocus = MediaTimelineRowFocus()
    /// Whether the filter row is open on a piece of this clip.
    var segmentFilterIsOpen: Bool { rowFocus.piece != nil }
    /// Bumped for every set of card pictures asked for: only the newest lands.
    var pictureRequests = 0
    /// Whether the band is holding the timeline.
    var isTimelineShowing: Bool { band.content === timelineTools }

    // MARK: - Cutting the clip up, and setting a piece's rate — state here, behaviour in `MediaEditorViewController+Cutting.swift`
    lazy var playbackFlash = MediaPlaybackFlashView()
    lazy var mediaTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped))
        // ⚠️ **IT MUST NOT EAT THE PAGING.** A tap recogniser and a scroll view's
        // pan do not compete — one needs a still finger and the other a moving
        // one — but a tap that CANCELS touches would stop a cell ever seeing one.
        tap.cancelsTouchesInView = false
        return tap
    }()
    /// ⚠️ **HANDLES THAT CANNOT MOVE ARE WORSE THAN NO HANDLES.**
    /// `MediaTimelining` will not leave less than `shortestSourceSeconds` behind, so on
    /// a clip already at or below that floor every drag resolves back to where
    /// it started. The strip looked operable and was inert, which is the same
    /// shape of lie as a control that reaches nothing — it just fails one step
    /// earlier.
    lazy var trimTooShort = BandNoticeView(
        "This clip is too short to trim."
    )
    /// The shape each picture's box is being held to.
    ///
    /// ⚠️ **NOT PART OF `MediaEdits`, ON PURPOSE.** It is how the author is
    /// working, not what they decided: a 4:5 rectangle IS a 4:5 crop whether it
    /// was reached through the chip or dragged there by hand, and neither the
    /// renderer nor the post can tell the two apart. Carrying it would be
    /// carrying a mode, and the next screen has no mode.
    var cropRatios: [String: CropRatio] = [:]
    var isCropping = false
    /// Which picture the surface is cutting.
    ///
    /// ⚠️ **CAPTURED ON THE WAY IN, NEVER RE-READ.** `currentItemID` is derived
    /// from the canvas's content offset, and an offset divided by a width is not
    /// stable across a device rotation — this app allows landscape. A crop landing
    /// on a different item than the one the author is looking at is not a visual
    /// glitch, it is a rectangle stored against somebody else's photograph. The
    /// canvas cannot be paged while the surface is up, so one capture is enough.
    var croppingID: String?
    /// Black behind the editing tools, for as long as they are up.
    ///
    /// ⚠️ **THE BAND IS CHROME HERE, NOT MORE PICTURE.** Everywhere else on this
    /// screen the canvas runs full-bleed beneath the controls and the dissolve
    /// softens it — that is the design, and the filter row depends on it. While a
    /// crop is being made it read wrong: the strip showed the UNCUT photograph
    /// under a ruler measuring the cut one. Reported from a device as "on aperçoit
    /// par derrière les outils d'édition le media". The dissolve stays and now has
    /// black to dissolve.
    let cropChrome: UIView = {
        let chrome = UIView()
        chrome.backgroundColor = .systemBackground
        chrome.isUserInteractionEnabled = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        return chrome
    }()
    /// Hands the surface the picture to cut.
    ///
    /// ⚠️ **NOTHING MAY BE TOUCHED UNTIL THE PICTURE LANDS.** The library answers
    /// on its own turn — `PHImageManager` with iCloud allowed can take a visible
    /// moment — and until it does, the surface holds a placeholder source of one
    /// point square. A drag in that window would compute a crop against nothing,
    /// store it, and then have it overwritten by the arrival below; a turn of the
    /// dial would do the same. Both controls are dead for exactly as long as there
    /// is nothing to cut.
    /// The picture to cut on its way (#1775): the kit's centred loader past
    /// its grace — a full-screen picture waits under it (#1764), never a
    /// dead, empty surface.
    lazy var cropLoader: AppLoaderView = {
        let loader = AppLoaderView(size: .large)
        loader.translatesAutoresizingMaskIntoConstraints = false
        return loader
    }()
    lazy var cropLoaderGate = LoaderGate(loader: cropLoader)
    /// Whether the straighten dial is under a finger — see its wiring.
    var isTurningTheDial = false

    // MARK: - The strip wins its own touches

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`. The
    /// picker skips this because it is the only screen in its stack; this screen
    /// is pushed, so a sideways drag on the strip is a drag the back-swipe wants
    /// for itself.
    private lazy var touchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.isTouchingStrip = isTouching
        self?.updateStackGestures()
    }

    var isTouchingStrip = false

    /// Who is holding the canvas still. The canvas is locked while this is not
    /// empty.
    private(set) var canvasLocks: Set<CanvasLockOwner> = []

    /// What the first lock borrowed, ready to be given back by the last unlock.
    /// ⚠️ CAPTURED ONCE AND CAPTURED AS IT WAS — restoring to `true` instead of
    /// to the prior value is how a suspension becomes permanent.
    private var canvasRestore: (() -> Void)?

    /// Holds the canvas still for `owner`: no paging, a sheet that cannot be
    /// pulled shut, and the stack's back-swipe suspended.
    ///
    /// ⚠️ **OWNERS, NOT A FLAG — THE CROP SURFACE AND THE OVERLAYS BOTH NEED
    /// IT.** A second owner locking an already-locked canvas borrows nothing (the
    /// values it would capture are the lock's own), and the canvas is given back
    /// only when the LAST owner lets go — otherwise the first to leave would
    /// unlock the canvas under the other.
    func lockCanvas(by owner: CanvasLockOwner) {
        let wasUnlocked = canvasLocks.isEmpty
        guard canvasLocks.insert(owner).inserted else { return }
        if wasUnlocked {
            let wasScrolling = canvas.isScrollEnabled
            let wasModal = navigationController?.isModalInPresentation ?? false
            canvasRestore = { [weak self] in
                guard let self else { return }
                canvas.isScrollEnabled = wasScrolling
                navigationController?.isModalInPresentation = wasModal
            }
            // ⚠️ **A LOCK, NOT A REFUSAL.** `CarouselCollectionView` declines a
            // drag by answering false in `gestureRecognizerShouldBegin`, which
            // hands the touch to the stack's full-width pan — so refusing here
            // would page nothing and pop the screen instead. `IconSelectorBar`
            // states the same choice, and states why a `require(toFail:)` into a
            // scroll view's recogniser graph is not the tool either.
            canvas.isScrollEnabled = false
            // ⚠️ **AND THIS IS WHAT KEEPS A DOWNWARD DRAG ON THE PICTURE FROM
            // CLOSING THE SHEET.** Dismissal is velocity-dominated — measured on
            // the filter row at 139pt/~3000pt/s — so no amount of gesture
            // arbitration makes it safe; the sheet has to be told it is not
            // dismissible. Set on the NAVIGATION CONTROLLER, which is the
            // presented screen.
            navigationController?.isModalInPresentation = true
        }
        updateStackGestures()
    }

    /// Lets go of the canvas for `owner`; the canvas moves again once nobody
    /// holds it.
    func unlockCanvas(by owner: CanvasLockOwner) {
        guard canvasLocks.remove(owner) != nil else { return }
        if canvasLocks.isEmpty {
            canvasRestore?()
            canvasRestore = nil
        }
        updateStackGestures()
    }

    /// ⚠️ **ONE PREDICATE, SEVERAL OWNERS — AND WITH TWO OWNERS IT WAS A
    /// DEFECT.** `setStackGesturesEnabled` keeps a single list of suspended
    /// recognisers and refuses to suspend twice (`suspendedPans.isEmpty`), while
    /// the strip's probe announces `false` on every lift and restored them
    /// unconditionally. Enter crop mode, then brush the category strip, and the
    /// back-swipe came back alive underneath a live crop surface — a rightward
    /// drag on the picture would have taken the screen away. Asking one question
    /// with every answer in it — every canvas lock, and the strip — is what
    /// makes the single slot correct.
    func updateStackGestures() {
        setStackGesturesEnabled(canvasLocks.isEmpty && !isTouchingStrip)
    }

    var suspendedPans: [(UIGestureRecognizer, Bool)] = []

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
        pageSettled()
    }

    /// ⚠️ **A DRAG RELEASED WITH NO VELOCITY DECELERATES NOWHERE.** Neither hook
    /// below fires for it, which was survivable while only the fill/fit glyph
    /// depended on settling — it would simply be re-stated on the next event.
    /// A clip that never starts is not survivable in the same way.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        pageSettled()
    }

    /// ⚠️ **BOTH SETTLE HOOKS, NOT JUST THE DRAGGED ONE.** A canvas that arrives
    /// by `scrollToItem` announces itself here instead, and handling only the
    /// dragged case would leave the row dressed in the previous picture while the
    /// canvas shows the next one.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        pageSettled()
    }

    /// Everything a page coming to rest re-decides, for all three hooks.
    ///
    /// ⚠️ **ONE ROUTINE, BECAUSE THE HOOKS WERE THREE COPIES** — and a line
    /// added to two of them is a settle that works by drag and not by
    /// `scrollToItem`. Every mode hears it (a filter row re-dressed for the new
    /// picture, an overlay layer rebuilt for it) before the page starts playing.
    private func pageSettled() {
        showTheFitGlyph()
        let settled = currentItemID
        // ⚠️ **THE ARROWS BELONG TO THE PAGE IN FRONT, SO A SWIPE RE-DECIDES
        // THEM.** They are lit from `session.canUndo(currentItemID)`, and
        // nothing else here reads the history — so without this line the author
        // swipes to an untouched photograph and finds a live back arrow
        // offering them the PREVIOUS page's last change.
        refreshHistoryItems()
        dressCategoryStrip(for: settled)
        for mode in modes { mode.pageDidSettle(on: settled) }
        refreshTimelineTrackIfShowing()
        reopenCropIfWaiting()
        playSettledPage()
    }
}



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

// MARK: - Carrying a film between surfaces

extension MediaEditorViewController {
    /// The moment a film moving from one surface to another lands on.
    ///
    /// ⚠️ **THE SAME FILM, CARRIED ON — NOT A NEW ONE STARTED.** Asked for as
    /// "la vidéo devrait être la continuité / le même player": opening crop on
    /// a clip started it again from its first frame, which for the clip the
    /// author recorded is a black title card — so the box they were aiming at
    /// went black. The canvas and the box play different ITEMS (the box's is
    /// uncut, see `playInsideTheCropBox`), so continuity is the second item
    /// landing where the first had got to.
    ///
    /// ⚠️ **AND THE SECONDS LINE UP, WHICH IS WHAT MAKES THAT HONEST.** The two
    /// plans differ only in the crop, and a crop changes what is framed, never
    /// when: a played second of the one is the same moment of the other. Held
    /// inside the arrangement, so a clock read a hair past the end lands on the
    /// start rather than beyond the film.
    nonisolated static func continuing(
        _ seconds: Double?, in timeline: MediaTimeline, fileSeconds: Double
    ) -> Double {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
        let played = MediaTimelining.playedSeconds(of: timeline, withinSource: fileSeconds)
        guard played > 0, seconds < played else { return 0 }
        return seconds
    }
}

// MARK: - How it is left (#1144)

extension MediaEditorViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
