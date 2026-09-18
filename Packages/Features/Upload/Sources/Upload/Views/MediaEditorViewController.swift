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
    private(set) var playingID: String?
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
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
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
    private var wearsTheVideoStrip = false

    /// The strip in the bar.
    private var categoryBar: IconSelectorBar { wearsTheVideoStrip ? videoStrip : photoStrip }

    /// The list the strip in the bar is offering.
    private var categories: [Category] {
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
        bar.suppressesBackdrop = true
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

    private lazy var nextItem = UIBarButtonItem(
        title: "Next",
        primaryAction: UIAction { [weak self] _ in self?.goNext() }
    )

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
    private lazy var doneTypingItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            primaryAction: UIAction { [weak self] _ in self?.overlayMode.finishComposing() }
        )
        item.image = Self.typingGlyph(hasWords: false)
        item.accessibilityLabel = "Discard"
        return item
    }()

    /// The glyph the one typing button wears.
    ///
    /// ⚠️ **IT IS THE SAME BUTTON AND THE SAME ACTION; ONLY THE PROMISE
    /// CHANGES.** Finishing an empty field already removes the text — that is
    /// `composed(_:)`'s documented rule — so a tick over nothing would promise
    /// to keep something that is about to be thrown away. A cross says what
    /// will actually happen. Two separate bar items would re-hand the whole
    /// trailing group at each crossing; one item changing its image does not.
    private static func typingGlyph(hasWords: Bool) -> UIImage? {
        UIImage(systemName: hasWords ? "checkmark" : "xmark")
    }

    /// Whether the composer holds any words right now — see
    /// `MediaEditorHosting.typedWordsDidChange`.
    var typedWords = false {
        didSet {
            guard typedWords != oldValue else { return }
            doneTypingItem.image = Self.typingGlyph(hasWords: typedWords)
            doneTypingItem.accessibilityLabel = typedWords ? "Done" : "Discard"
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
    private func showTheTrailingItem(animated: Bool = false) {
        navigationItem.setRightBarButtonItems(
            [isTypingText ? doneTypingItem : nextItem, redoItem, undoItem], animated: animated
        )
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
    private lazy var undoItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            primaryAction: UIAction { [weak self] _ in self?.stepBack() }
        )
        item.accessibilityLabel = "Undo"
        return item
    }()

    private lazy var redoItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.forward"),
            primaryAction: UIAction { [weak self] _ in self?.stepForward() }
        )
        item.accessibilityLabel = "Redo"
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
        guard let id = currentItemID, transitionFocus == nil, !segmentFilterMode.isOpen,
              !isTypingText
        else {
            undoItem.isEnabled = false
            redoItem.isEnabled = false
            return
        }
        undoItem.isEnabled = history.canUndo(id)
        redoItem.isEnabled = history.canRedo(id)
    }

    /// One step back through this page's own changes.
    ///
    /// ⚠️ **THE WHOLE EDIT, NOT THE MODE'S PART OF IT.** The arrow that stood
    /// here used to undo "what this mode owns", so a step back meant something
    /// different depending on which tools happened to be open. A step is a
    /// change the author made; going back to it puts the page exactly where it
    /// was, whichever band they were in at the time.
    private func stepBack() {
        guard let id = currentItemID, let restored = history.undo(id, from: edits(for: id)) else { return }
        restore(restored, on: id)
    }

    private func stepForward() {
        guard let id = currentItemID, let restored = history.redo(id, from: edits(for: id)) else { return }
        restore(restored, on: id)
    }

    /// Puts a state back on the page and tells everything that draws it.
    ///
    /// ⚠️ **THE SCREEN REDRAWS, THE CLIP IS REBUILT, AND EVERY MODE RE-READS.**
    /// A restored state can differ from the one on screen in any field at all —
    /// a look, a cut, an overlay, a song — so this cannot announce one kind of
    /// change; `.film` is the widest one the screen has, and `editsWereRestored`
    /// is how a mode that is showing its own controls learns to state them
    /// again.
    private func restore(_ restored: MediaEdits, on id: String) {
        // ⚠️ **A RESTORED LOOK GOES LIVE; ANYTHING ELSE REBUILDS THE ITEM.**
        // Rebuilding for a look would work and would be wrong twice over: the
        // clip stutters where it does not have to, and the live path
        // (`setLiveLook`) stops being exercised by the arrows at all. What
        // decides is whether ANY field other than the look moved — written as a
        // comparison rather than a list, so a field added to `MediaEdits`
        // tomorrow lands on the safe side by itself.
        let showing = edits(for: id)
        var asIfOnlyTheLookMoved = showing
        asIfOnlyTheLookMoved.filter = restored.filter
        asIfOnlyTheLookMoved.adjustments = restored.adjustments
        asIfOnlyTheLookMoved.effect = restored.effect
        edits[id] = restored.isUntouched ? nil : restored
        editsDidChange(id, asIfOnlyTheLookMoved == restored ? .look : .film)
        refreshTimelineTrackIfShowing()
        for mode in modes { mode.editsWereRestored(for: id) }
        if isCropping { showCropPicture(for: id) }
        showTheFitGlyph()
        refreshHistoryItems()
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

    func edits(for id: String) -> MediaEdits { edits[id] ?? .untouched }

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

    private func remember(_ image: UIImage?, for id: String) {
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

    /// ⚠️ **NOT WHILE A SLIDER IS UNDER A FINGER** (`MediaEditorEffectsMode`):
    /// a render is always in flight during a drag, and the spinner would flash.
    private func beginRender() {
        rendersInFlight += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinnerDelay) { [weak self] in
            guard let self, rendersInFlight > 0, !effectsMode.isTracking else { return }
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

    /// ⚠️ AN ENTRY THAT SAYS NOTHING IS WORSE THAN NO ENTRY: it makes "was this
    /// picture edited?" answerable two ways. Undoing every change removes the
    /// entry rather than storing a neutral one.
    /// ⚠️ **`settling: false` IS A CHANGE STILL UNDER A FINGER.** A ruler
    /// dragged across the screen writes sixty values a second; each one is a
    /// change, and none of them is a STEP. The mode that owns the finger is the
    /// only thing that knows, so it says — everything else settles by default.
    func change(_ id: String, settling: Bool = true, _ mutate: (inout MediaEdits) -> Void) {
        let before = edits[id] ?? .untouched
        var value = before
        mutate(&value)
        edits[id] = value.isUntouched ? nil : value
        guard settling else {
            // ⚠️ **THE STATE THE FINGER LANDED ON, KEPT UNTIL IT LIFTS.** Only
            // the FIRST sample of a drag holds it; every later one would file
            // the value the sample before it wrote, and the step the author
            // gets back would be one frame of their own gesture.
            if pendingBefore?.id != id { pendingBefore = (id, before) }
            return
        }
        // ⚠️ **AND A LIFT THAT WRITES THE VALUE ALREADY ON THE PAGE IS STILL
        // THE END OF A STEP.** A ruler's last sample and its settle carry the
        // same number, so recording from `before` here would compare the value
        // to itself, find no change, and file nothing — a drag across the whole
        // screen, and a back arrow that never lit.
        let opening = pendingBefore?.id == id ? (pendingBefore?.state ?? before) : before
        pendingBefore = nil
        history.record(opening, changingTo: value, for: id)
        refreshHistoryItems()
    }

    /// What the two arrows in the header walk — see `MediaEditHistory`.
    private var history = MediaEditHistory<MediaEdits>()

    /// Where the drag under the finger began, filed by the first sample.
    ///
    /// ⚠️ **ONE SLOT, BECAUSE THERE IS ONE FINGER.** A second page cannot be
    /// dragged while this one is, and a page that changes under a held finger
    /// is not a thing this screen can do — so an id that does not match is a
    /// drag that ended without a lift, and the slot is simply taken over.
    private var pendingBefore: (id: String, state: MediaEdits)?

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
    private var modes: [any MediaEditorMode] {
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
    private func open(_ mode: any MediaEditorMode) {
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
    private let pageDots = MediaPageDotsView()

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

    #if DEBUG
    private var hasSeededDebugCuts = false

    /// `-upload-seed-cuts N` cuts the first clip the track opens on into N equal
    /// pieces, `-upload-seed-reverse` plays them back to front,
    /// `-upload-seed-transition <raw value>` puts that transition on every cut,
    /// and `-open-transitions <i>` opens the row on cut `i` — once, through the
    /// very edit path a person's taps take.
    ///
    /// ⚠️ **A SIMULATOR CANNOT SPLIT AT A CHOSEN SECOND BY HAND** — a drag loses
    /// ten points of slop before the film moves — and a transition is only worth
    /// checking on cuts that sit where the test says they do.
    private func seedDebugCuts(id: String, length: Double) {
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
        timelineTrack.configure(duration: length, timeline: timeline)
        refreshHistoryItems()
        refreshPreview()
        VideoPlaybackTrace.emit("seeded \(count) cuts, transition=\(kind?.rawValue ?? "none")")
        if let raw = Self.debugValue(after: "-open-transitions"), let seam = Int(raw) {
            openTransitions(atSeam: seam)
        }
    }

    #endif

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

    /// Opens the song tools (`MediaEditorSoundtrackMode`), and names the song
    /// once one is chosen. The same control the text-post composer uses, which
    /// is why it lives in DesignSystem.
    ///
    /// ⚠️ **CROP IS LEFT FIRST, AS CHOOSING ANY OTHER MODE LEAVES IT.** The pill
    /// stays tappable under the crop surface, and a band handed to the song
    /// tools with the surface still up would leave the canvas locked behind
    /// tools that have nothing to do with it.
    private lazy var soundPill: SoundPillView = {
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
        // ⚠️ **WHAT THE MEDIA ARRIVE WEARING, NOT A STEP.** The camera hands its
        // captures over with the look and the shape the author chose while
        // shooting; those are where the editing STARTS, so they are not in the
        // history — a step back from the first change the author makes here
        // lands on them, never behind them. Only edits that say something are
        // kept, for `edits`'s own reason: an entry that says nothing is worse
        // than none.
        self.edits = initialEdits.filter { id, edit in
            !edit.isUntouched && items.contains { $0.id == id }
        }
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
        // `history.canUndo(currentItemID)`, and `currentItemID` reads the
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
           let index = Int(raw), categories.indices.contains(index) {
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
                cell?.show(
                    image.map { self.edits(for: id).applied(to: $0, artwork: nil, includingOverlays: false) },
                    for: id
                )
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
    private func followTheBand(animated: Bool) {
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
        strip.suppressesBackdrop = true
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
    private func refreshToolbarItems(animated: Bool) {
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
        let unchanged = held.count == 4
            && held[0].customView === leading
            && held[2].customView === categoryBar
        if !unchanged {
            #if DEBUG
            debugRealHandovers += 1
            debugLastHandoverWasAnimated = animated
            #endif
            setToolbarItems(
                [
                    Self.barItem(leading, as: ItemID.leading),
                    .fixedSpace(Spacing.sm),
                    Self.barItem(categoryBar, as: ItemID.categories(categories)),
                    .flexibleSpace()
                ],
                animated: animated
            )
        }
        handedWidths = shareTheBarBetweenTheTwoStrips()
    }

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

        static func categories(_ list: [Category]) -> String {
            "upload.editor.toolbar.categories." + list.map(\.title).joined(separator: ",")
        }
    }

    private static func barItem(_ view: UIView, as identifier: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: view)
        item.identifier = identifier
        return item
    }

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
    private func shareTheBarBetweenTheTwoStrips() -> (leading: CGFloat, trailing: CGFloat)? {
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
        categoryBarWidth.constant = held.trailing
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

    /// What the bar charges around its items — measured once it has hosted
    /// two neighbours, the SE's numbers until then.
    private(set) var barGeometry = ToolbarGeometry.fallback

    #if DEBUG
    /// Internal for tests: runs just before the bar is handed its items.
    var debugOnToolbarHandover: (() -> Void)?
    /// Internal for tests: how many elements each arrival staged, in order —
    /// the choreography's DECISION, which is the half a test can see. The
    /// drawing is a presentation-layer value that only exists while a curve is
    /// actually running (`uiview-animate-from-value-trap`).
    private(set) var debugPopIns: [Int] = []
    /// Internal for tests: how many tenants were animated out.
    private(set) var debugPopOuts = 0
    /// Internal for tests: how many surfaces each arrival swept, in order.
    private(set) var debugReveals: [Int] = []
    /// Internal for tests: how many times the bar was ACTUALLY handed a new
    /// set of items — as opposed to asked to, which is `debugHandoverWidths`.
    private(set) var debugRealHandovers = 0
    /// Internal for tests: whether the last real hand-over asked UIKit to
    /// animate it.
    private(set) var debugLastHandoverWasAnimated = false
    /// Internal for tests: the items the bar is holding, by identity.
    var debugToolbarItems: [UIBarButtonItem] { toolbarItems ?? [] }
    /// Internal for tests: the toolbar's width at each hand-over, in order.
    /// Every one of them must be greater than zero — see `refreshToolbarItems`.
    private(set) var debugHandoverWidths: [CGFloat] = []
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
    var debugBarGeometry: ToolbarGeometry { barGeometry }
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
        guard let window = leading.window, categoryBar.window === window,
              let leadingPlatter = Self.platter(of: leading),
              let trailingPlatter = Self.platter(of: categoryBar),
              let measured = ToolbarGeometry.measured(
                  leading: leading.convert(leading.bounds, to: nil),
                  leadingPlatter: leadingPlatter,
                  trailing: categoryBar.convert(categoryBar.bounds, to: nil),
                  trailingPlatter: trailingPlatter
              )
        else { return }
        barGeometry = measured
    }

    /// The first ancestor wider than `view`, in window coordinates — the
    /// platter a bar item sits on.
    private static func platter(of view: UIView) -> CGRect? {
        guard let window = view.window else { return nil }
        let own = view.convert(view.bounds, to: nil)
        var node = view.superview
        while let current = node, current !== window {
            let frame = current.convert(current.bounds, to: nil)
            if frame.width > own.width + 0.5 {
                return frame.width < window.bounds.width ? frame : nil
            }
            node = current.superview
        }
        return nil
    }

    private lazy var actionBarWidth: NSLayoutConstraint =
        actionBar.widthAnchor.constraint(equalToConstant: IconActionBar.height)

    /// The pill's ceiling — see `shareTheBarBetweenTheTwoStrips`. Always on,
    /// and inert until a title is long enough to crowd the selector out.
    private lazy var soundPillCap: NSLayoutConstraint = {
        let cap = soundPill.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        cap.isActive = true
        return cap
    }()

    /// The width a strip would take on its own.
    ///
    /// ⚠️ **NOT `intrinsicContentSize` ALONE.** `IconActionBar` states one;
    /// `SoundPillView` answers `noIntrinsicMetric` (-1) because its size comes
    /// from its own subviews' constraints, and -1 read as a width gave the
    /// selector the whole bar and the pill nothing.
    private static func wantedWidth(of view: UIView) -> CGFloat {
        let stated = view.intrinsicContentSize.width
        guard stated == UIView.noIntrinsicMetric else { return stated }
        return view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
    }

    private lazy var photoStripWidth: NSLayoutConstraint =
        photoStrip.widthAnchor.constraint(equalToConstant: IconSelectorBar.height)
    private lazy var videoStripWidth: NSLayoutConstraint =
        videoStrip.widthAnchor.constraint(equalToConstant: IconSelectorBar.height)

    /// The width constraint of the strip in the bar. The other one keeps the
    /// width it left with.
    private var categoryBarWidth: NSLayoutConstraint {
        wearsTheVideoStrip ? videoStripWidth : photoStripWidth
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
    private func showAccessory(for category: String?) {
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

    /// How long the clip the track is showing actually runs.
    ///
    /// ⚠️ **THE FILE'S LENGTH, AND IT IS WHAT TURNS A SCRUB INTO A SEEK.** The
    /// track speaks in seconds of the file and the player takes a FRACTION of it;
    /// dividing by the declared duration instead would scrub to the wrong moment
    /// on exactly the clips whose declaration is wrong — the ones the reload
    /// above exists for.
    private(set) var trackSeconds: Double = 0

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

    /// Whether the track has opened on a clip and not yet been put where the
    /// player is.
    private var trackNeedsPlacement = false

    /// What the preview item is running.
    ///
    /// ⚠️ **THE SCREEN HAS TO KNOW, BECAUSE THE PLAYER'S CLOCK MEANS WHATEVER THE
    /// ITEM IS.** Played seconds of THIS arrangement, or — while a handle is held
    /// — seconds of the file as shot. Everything that reads the player or seeks
    /// it asks this first.
    private struct PreviewSubject {
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
    func resumeAfterACover(retries: Int = 0) {
        guard !isCovered else {
            guard retries > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.resumeAfterACover(retries: retries - 1) }
            return
        }
        guard let surface = playingSurface else { return }
        let paused = fingerOnTrack || pausedByAuthor
        preview.setPaused(paused, in: surface)
        timelineTrack.showPaused(paused)
    }

    private var previewSubject: PreviewSubject?
    /// Bumped for every load asked for: only the newest may land.
    private var previewLoads = 0
    /// Whether a load is on its way, during which the player's clock describes
    /// an item that is about to go.
    private var previewPending = false
    /// Whether a finger is on the track — what a load that lands decides the
    /// pause from.
    private var fingerOnTrack = false
    /// The FILE second a held handle last aimed at, so a creeping edge gets a
    /// tight seek and a flung one a loose one.
    private var lastAimedSeconds: Double?
    /// The file's real length, per clip, once asked.
    private(set) var fileLengths: [String: Double] = [:]

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
    private func loadPreview(
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
    private func activeLoop(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
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

    private var lastAnsweredNeedle: Double = .infinity

    /// What the track is waiting for before it lets the player move it again.
    private var handover: MediaTimelining.Handover = .settled

    /// Where the author last put the needle, so the handover knows what arrival
    /// to wait for. Nil when this gesture has not moved anything.
    private var lastScrubbedSeconds: Double?

    /// The surface the settled page is playing in, if it is playing at all.
    /// ⚠️ **REMEMBERED, NOT RE-DERIVED.** It used to be looked up through the
    /// canvas's cell for the playing page, which answers nil whenever the cell
    /// is not reachable — while a sheet covers the screen, for one, so the
    /// clip could not be told anything until the cell came back. It is also the
    /// only way the CROP surface can hold the clip: the film plays there while
    /// its box is aimed, and that surface belongs to no cell.
    var playingSurface: VideoRenderView? { boundSurface }

    private var boundSurface: VideoRenderView?

    /// The film moved under the needle, or a handle moved: put that moment on
    /// the canvas.
    ///
    /// ⚠️ **A SEEK, NOT A STORE.** Scrubbing changes what is on screen and
    /// nothing else; `onChange` is the channel that writes to `edits`, and it
    /// fires on release only.
    private func scrubbed(to moment: MediaTimelining.Moment) {
        guard transitionFocus == nil, let surface = playingSurface, let subject = previewSubject,
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
    private func scrubbing(_ scrubbing: Bool) {
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
    private func refreshTimelineTrackIfShowing() {
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
    private func reopenCropIfWaiting() {
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

    var currentItemID: String? {
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
    private func showCropBarItems(_ isCropping: Bool, animated: Bool) {
        navigationItem.setLeftBarButtonItems([saveDraftItem], animated: animated)
        showTheTrailingItem(animated: animated)
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
        tools.onHeightChange = { [weak self] in
            self?.followTheBand(animated: true)
        }
        tools.segmentFilters.onPick = { [weak self] filter in
            self?.chooseSegmentFilter(filter)
        }
        tools.segmentFilters.onClose = { [weak self] in
            self?.closeSegmentFilters(animated: true)
        }
        return tools
    }()

    private var timelineTrack: MediaTimelineTrackView { timelineTools.track }

    // MARK: - Choosing a cut's transition

    /// The cut whose transition is being chosen: the one after piece `seam` of
    /// clip `id`.
    ///
    /// ⚠️ **POSITIONAL, AND SAFE ONLY BECAUSE NOTHING ELSE EDITS WHILE IT IS
    /// SET.** The track takes no gesture while collapsed, the cut and rate
    /// actions and the reset arrow are disabled, and every way off the clip
    /// closes the row first.
    private struct TransitionFocus: Equatable {
        let id: String
        var seam: Int
    }

    private var transitionFocus: TransitionFocus?

    /// Whether the author had stopped the clip when the row opened. The row
    /// plays the stretch around the cut whatever it was; closing it puts the
    /// author's choice back — unless they toggled playback meanwhile (nil).
    private var pausedBeforeTransitions: Bool?

    /// The stretch to loop and the transition inside it, for the focused cut of
    /// `timeline` — nil when no row is open on this clip.
    ///
    /// ⚠️ **READ LIVE, EVERY TIME.** A load that lands after the row closed must
    /// loop nothing, and one that lands on the next cut must loop that one.
    private func rehearsal(
        in timeline: MediaTimeline, fileSeconds: Double
    ) -> (range: ClosedRange<Double>, window: ClosedRange<Double>)? {
        guard let focus = transitionFocus, focus.id == currentItemID, focus.id == playingID else {
            return nil
        }
        return MediaTimelining.rehearsal(
            atSeam: focus.seam, in: timeline, withinSource: fileSeconds,
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
    private func openTransitions(atSeam seam: Int) {
        // ⚠️ NEVER OVER A PIECE'S FILTER ROW — the two share the line.
        guard pieceFocus == nil, isTimelineShowing, let id = currentItemID, trackSeconds > 0,
              fileLengths[id] == trackSeconds, !timelineTrack.isHoldingAnEdge
        else { return }
        let timeline = edits(for: id).timeline
        let pieces = MediaTimelining.resolved(timeline, withinSource: trackSeconds)
        guard seam >= 0, seam < pieces.count - 1 else { return }
        let rehearsal = MediaTimelining.rehearsal(
            atSeam: seam, in: timeline, withinSource: trackSeconds, lead: timelineTrack.rehearsalLead
        )
        if var focus = transitionFocus {
            // Already open: only the cut changes.
            focus.seam = seam
            transitionFocus = focus
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
        transitionFocus = TransitionFocus(id: id, seam: seam)
        pausedBeforeTransitions = pausedByAuthor
        pausedByAuthor = false
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
    private func chooseTransition(_ kind: VideoTransitionKind?) {
        guard let focus = transitionFocus, focus.id == currentItemID, trackSeconds > 0 else { return }
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
        pausedByAuthor = false
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// A length was chosen for the focused cut's transition.
    ///
    /// ⚠️ **CLAMPED TO WHAT THE TWO PIECES CAN GIVE, AND STORED THROUGH
    /// `change`** — a length is an edit of the film like the kind it belongs
    /// to, so it is a step the arrows can take back, and a new item the preview
    /// lands on the stretch (charter F29b).
    private func chooseTransitionDuration(_ seconds: Double) {
        guard let focus = transitionFocus, focus.id == currentItemID, trackSeconds > 0 else { return }
        let before = edits(for: focus.id).timeline
        let after = MediaTimelining.settingTransitionDuration(
            seconds, atSeam: focus.seam, in: before, withinSource: trackSeconds
        )
        if after != before { change(focus.id) { $0.timeline = after } }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        showTheFocusedTransition(in: after)
        pausedByAuthor = false
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// States what the focused cut carries in `timeline` — its kind, its
    /// length and the longest it could have — and the stretch that shows it.
    private func showTheFocusedTransition(in timeline: MediaTimeline) {
        guard let focus = transitionFocus else { return }
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
        guard let focusID = transitionFocus?.id ?? pieceFocus?.id, focusID == currentItemID,
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
    private func closeTransitions(animated: Bool) {
        closeSegmentFilters(animated: animated)
        guard transitionFocus != nil || timelineTools.editingSeam != nil else { return }
        transitionFocus = nil
        if previewSubject?.loop != nil {
            previewSubject?.loop = nil
            if let surface = playingSurface { preview.setLoopRange(nil, in: surface) }
        }
        timelineTools.closeTransitions(animated: animated)
        let paused = pausedBeforeTransitions ?? pausedByAuthor
        pausedBeforeTransitions = nil
        pausedByAuthor = paused
        if let surface = playingSurface { preview.setPaused(paused, in: surface) }
        timelineTrack.showPaused(paused)
        refreshTrackActions()
        refreshHistoryItems()
    }

    // MARK: - Choosing a piece's filter

    /// The piece whose filter is being chosen: piece `piece` of clip `id`.
    ///
    /// ⚠️ **RECORDED BEFORE THE TRACK COLLAPSES** — collapsing puts the held
    /// piece down, and the piece is what the row is open on. Positional, and
    /// safe for the reason `TransitionFocus` is.
    private struct PieceFocus: Equatable {
        let id: String
        var piece: Int
    }

    private var pieceFocus: PieceFocus?

    /// Whether the filter row is open on a piece of this clip.
    var segmentFilterIsOpen: Bool { pieceFocus != nil }

    /// ⚠️ **ONLY WHILE A PIECE IS HELD** — asked for in those words: *"qui sera
    /// active que lorsqu'un segment sera sélectionné dans la timeline"*. While
    /// the row is open the action stays live, lit, and closes it.
    var segmentFilterActionEnabled: Bool {
        guard isTimelineShowing, let id = currentItemID, trackSeconds > 0,
              fileLengths[id] == trackSeconds, !timelineTrack.isHoldingAnEdge
        else { return false }
        return pieceFocus != nil || timelineTrack.selectedPiece != nil
    }

    /// What the preview loops while the filter row is open on this clip.
    func segmentFilterRehearsal(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
        guard let focus = pieceFocus, focus.id == currentItemID, focus.id == playingID else { return nil }
        return MediaTimelining.rehearsal(ofPiece: focus.piece, in: timeline, withinSource: fileSeconds)
    }

    /// The filter action was tapped: open the row on the held piece — or, when
    /// it is already open, put it away.
    func toggleSegmentFilters() {
        guard pieceFocus == nil else { return closeSegmentFilters(animated: true) }
        guard transitionFocus == nil, segmentFilterActionEnabled, let id = currentItemID,
              let piece = timelineTrack.selectedPiece
        else { return }
        let timeline = edits(for: id).timeline
        let pieces = MediaTimelining.resolved(timeline, withinSource: trackSeconds)
        guard pieces.indices.contains(piece) else { return }
        if timelineTools.isOfferingSpeeds { toggleTheRateChips() }
        let range = MediaTimelining.rehearsal(ofPiece: piece, in: timeline, withinSource: trackSeconds)
        pieceFocus = PieceFocus(id: id, piece: piece)
        guard timelineTools.openSegmentFilters(
            forPiece: piece, chosen: pieces[piece].filter, rehearsal: range, animated: true
        ) else {
            pieceFocus = nil
            return
        }
        actionBar.setActive(TrackAction.filter.rawValue)
        pausedBeforeTransitions = pausedByAuthor
        pausedByAuthor = false
        dressSegmentFilterCards(id: id, piece: pieces[piece])
        if !previewPending { landOnTheFocus() }
        refreshTrackActions()
        refreshHistoryItems()
    }

    /// A look was chosen for the focused piece — `nil` takes it away.
    private func chooseSegmentFilter(_ filter: MediaFilter?) {
        guard let focus = pieceFocus, focus.id == currentItemID, trackSeconds > 0 else { return }
        let before = edits(for: focus.id).timeline
        let after = MediaTimelining.settingFilter(
            filter, atPiece: focus.piece, in: before, withinSource: trackSeconds
        )
        if after != before { change(focus.id) { $0.timeline = after } }
        timelineTrack.configure(duration: trackSeconds, timeline: after)
        timelineTools.showSegmentFilter(filter)
        pausedByAuthor = false
        refreshHistoryItems()
        if !refreshPreview() { landOnTheFocus() }
    }

    /// Puts the filter row away, as `closeTransitions` puts its own.
    private func closeSegmentFilters(animated: Bool) {
        guard pieceFocus != nil || timelineTools.editingPiece != nil else { return }
        pieceFocus = nil
        pictureRequests += 1
        if previewSubject?.loop != nil {
            previewSubject?.loop = nil
            if let surface = playingSurface { preview.setLoopRange(nil, in: surface) }
        }
        timelineTools.closeSegmentFilters(animated: animated)
        actionBar.setActive(nil)
        let paused = pausedBeforeTransitions ?? pausedByAuthor
        pausedBeforeTransitions = nil
        pausedByAuthor = paused
        if let surface = playingSurface { preview.setPaused(paused, in: surface) }
        timelineTrack.showPaused(paused)
        refreshTrackActions()
        refreshHistoryItems()
    }

    /// Bumped for every set of card pictures asked for: only the newest lands.
    private var pictureRequests = 0

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
            guard pictureRequests == request, pieceFocus?.id == id else { return }
            for (choice, picture) in zip(choices, pictures) {
                row.setPicture(picture, for: choice)
            }
        }
    }

    /// Whether the band is holding the timeline.
    private var isTimelineShowing: Bool { band.content === timelineTools }

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
    private func splitAtTheNeedle() {
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
        // A cut leaves the same film on the same clock: the preview's record of
        // what it plays changes, and nothing it shows does.
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

    private func toggleTheRateChips() {
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
    private func chooseRate(_ rate: Double) {
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
        let focused = transitionFocus != nil || segmentFilterMode.isOpen
        // ⚠️ **THE PIECE FILTER'S OWN RULE IS ITS MODE'S** (a piece held, the
        // file's real length known); the transitions row still shuts it.
        actionBar.setEnabled(
            transitionFocus == nil && segmentFilterMode.actionEnabled, at: TrackAction.filter.rawValue
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
    /// is aimed at the box rather than at the film — and the guard has never had
    /// anything to do. It used to be `enterCrop` REFUSING videos that made it
    /// dead; a clip is cropped like a photograph now, and what makes it dead
    /// instead is the `stopPreview()` `enterCrop` runs on its way in. Nothing is
    /// bound while the surface is up, so `togglePreviewPlayback` finds no surface
    /// to toggle. That `stopPreview()` was itself once deleted from `enterCrop`
    /// as unreachable, for the same reason this guard was: it is back, and it is
    /// doing the work.
    @objc private func mediaTapped() {
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

    private lazy var playbackFlash = MediaPlaybackFlashView()

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
        // ⚠️ **A TOGGLE DURING THE ROW WINS.** Closing it puts back the pause the
        // author had before it opened — unless they have said something since.
        if transitionFocus != nil { pausedBeforeTransitions = nil }
        preview.setPaused(!paused, in: surface)
        timelineTrack.showPaused(!paused)
    }

    /// ⚠️ **HANDLES THAT CANNOT MOVE ARE WORSE THAN NO HANDLES.**
    /// `MediaTimelining` will not leave less than `shortestSourceSeconds` behind, so on
    /// a clip already at or below that floor every drag resolves back to where
    /// it started. The strip looked operable and was inert, which is the same
    /// shape of lie as a control that reaches nothing — it just fails one step
    /// earlier.
    private lazy var trimTooShort = BandNoticeView(
        "This clip is too short to trim."
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
    private func exitCrop(resuming: Bool = true, emptyingTheBand: Bool = true) {
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

    /// Whether the straighten dial is under a finger — see its wiring.
    private var isTurningTheDial = false

    private func cropChanged(_ crop: MediaCrop) {
        guard let id = croppingID else { return }
        change(id, settling: !isTurningTheDial) { $0.crop = crop }
        // ⚠️ ONLY THE UNDO BUTTON, NEVER THE DIAL — see `setCanReset`. Re-stating
        // the dial's angle from here would fight the finger that is turning it.
        refreshHistoryItems()
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
    private func updateStackGestures() {
        setStackGesturesEnabled(canvasLocks.isEmpty && !isTouchingStrip)
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
    func playSettledPage(from carried: Double? = nil) {
        // The crop surface holds the clip while its box is being aimed — see
        // `playInsideTheCropBox`.
        guard !isCropping else { return }
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
        boundSurface = page.videoSurface
        // ⚠️ THE CELL TELLS US WHEN IT IS TAKEN AWAY. A canvas recycles pages
        // without asking, and a surface handed to a player and then re-used for
        // another item would keep the previous clip's frames.
        page.onReuse = { [weak self] surface in
            guard let self else { return }
            if playingID == id { closeTransitions(animated: false) }
            preview.stop(surface)
            if playingID == id { playingID = nil }
        }

        // ⚠️ **THE EDIT, NOT THE FILE — IN EVERY MODE.** The canvas plays the
        // arrangement the author has made, from its start, whichever band is
        // open; the funnel re-asks everything after its awaits, since a read can
        // take a moment and the author may have swiped on while it did.
        previewSubject = nil
        loadPreview { timeline, fileSeconds in
            VideoLoadLanding(seconds: Self.continuing(carried, in: timeline, fileSeconds: fileSeconds))
        }
    }

    /// Unbinds whatever is playing and puts the page back to its poster.
    func stopPreview() {
        guard let id = playingID else { return }
        // Nothing may go on looping a stretch of a clip that is no longer playing.
        closeTransitions(animated: false)
        playingID = nil
        // Whatever is on its way belongs to a page that is no longer playing.
        previewSubject = nil
        previewLoads += 1
        previewPending = false
        // ⚠️ **WHATEVER IT WAS BOUND TO, WHICH IS NOT ALWAYS A PAGE.** The crop
        // surface holds the clip while a box is being aimed at it, and it
        // belongs to no cell.
        if let surface = boundSurface { preview.stop(surface) }
        boundSurface = nil
        cropSurface.showsVideo(false)
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
                as? MediaEditorPageCell
        else { return }
        page.onReuse = nil
        page.stopShowingVideo()
    }

    /// Plays the clip ON the crop surface, uncut, while its box is being aimed.
    ///
    /// ⚠️ **UNCUT, AND THAT IS THE WHOLE POINT.** The plan the canvas plays
    /// carries the crop, so the compositor hands back film that is already cut;
    /// aiming a box at that would crop a crop, and every rectangle the author
    /// drew would bite twice. `includingCrop: false` is why this is a load of
    /// its own rather than the canvas's.
    private func playInsideTheCropBox(for id: String) {
        guard itemsByID[id]?.isVideo == true else { return }
        // ⚠️ **READ BEFORE THE STOP, BECAUSE THE STOP IS WHAT FORGETS IT.**
        let carried = playingID == id ? playheadOfTheFilmPlayingNow() : nil
        stopPreview()
        playingID = id
        boundSurface = cropSurface.videoSurface
        cropSurface.showsVideo(true)
        previewSubject = nil
        loadPreview { timeline, fileSeconds in
            VideoLoadLanding(seconds: Self.continuing(carried, in: timeline, fileSeconds: fileSeconds))
        }
    }

    /// Where the film playing now has got to, in played seconds.
    private func playheadOfTheFilmPlayingNow() -> Double? {
        guard let surface = boundSurface else { return nil }
        return preview.playheadSeconds(in: surface)
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
        // THEM.** They are lit from `history.canUndo(currentItemID)`, and
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
    func setEditingAccessory(_ accessory: UIView?, animated: Bool = false) {
        // ⚠️ **EVERY MODE HEARS IT FIRST, WHOEVER IS ASKING.** A row, a sheet or
        // a lock a mode opened belongs to the band it opened in; this is the one
        // funnel every band change goes through, so it is the one place a mode
        // can be sure to hear it. A mode must not change the band from here.
        for mode in modes { mode.bandWillChange(to: accessory) }
        // ⚠️ **DEACTIVATE BEFORE ACTIVATING.** Both anchors pin the same edge, so
        // leaving the old one alive for even one pass gives Auto Layout a conflict
        // to arbitrate — and it may keep the one being replaced.
        // ⚠️ **THE DEPARTING TENANT IS TAKEN OUT OF THE BAND BEFORE ANYTHING
        // ELSE HAPPENS, WHATEVER IT IS ABOUT TO DO.** `band.content` is how this
        // screen answers "what is up" in ten places; a tenant left in it for the
        // length of a fade would have all ten answer for a view that is already
        // leaving. `release()` hands it back detached, which is what lets it be
        // animated without lying about the band.
        let departing = animated && band.content !== accessory ? band.release() : nil
        if let accessory {
            band.show(accessory)
            backdropFromChrome.isActive = false
            backdropFromBand.isActive = true
        } else {
            band.clear()
            backdropFromBand.isActive = false
            backdropFromChrome.isActive = true
        }
        // ⚠️ **THE CHIPS BELONG TO THE TIMELINE AND LEAVE WITH IT.** They are
        // laid out inside the tenant, so a band holding something else cannot
        // show them — but the bar's lit speedometer and the tenant's own flag
        // would come back on next time still saying "open", over a row nobody
        // asked for.
        if accessory !== timelineTools {
            closeTransitions(animated: false)
            timelineTools.isOfferingSpeeds = false
            actionBar.setActive(nil)
        }
        // The leading half of the toolbar is the mode's — see
        // `refreshToolbarItems`.
        refreshToolbarItems(animated: true)
        refreshTrackActions()
        // ⚠️ **THE ONE FUNNEL EVERY BAND CHANGE GOES THROUGH, WHICH IS WHY THE
        // FOLLOWER IS STARTED AND STOPPED HERE.** Six routes install a tenant —
        // three settle hooks, the category bar, the too-short notice and crop's
        // own exit — and a link started next to only some of them would keep
        // polling a player nobody is watching for as long as the editor is open.
        follower.isPaused = accessory !== timelineTools
        // The undo arrow's meaning changes with the band, so its enabled state
        // has to be re-decided here too.
        refreshHistoryItems()
        // ⚠️ THE BAND JUST MOVED THE INDICATOR, AND THE INDICATOR IS THE FOOT OF A
        // FITTED PICTURE'S WINDOW. Laying out first is what makes `fitWindow` true
        // rather than one band-height out of date.
        followTheBand(animated: animated)
        if let departing { popTheTenantOut(departing) }
        if animated, let accessory { popTheTenantIn(accessory) }
    }

    /// The band's arrival curve: every element the tenant names, one after
    /// another — see `BandPop`.
    ///
    /// ⚠️ **AFTER THE LAYOUT PASS, NOT BEFORE.** A scale transform is applied
    /// about a view's centre, and a view that has not been laid out yet has no
    /// centre worth scaling about: the whole row would pop from the band's
    /// top-left corner. `setEditingAccessory` lays out just above, which is what
    /// makes this the right side of the call.
    private func popTheTenantIn(_ accessory: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // ⚠️ **A TENANT THAT NAMES NOTHING STILL ARRIVES.** The soundtrack tools
        // are a waveform and two sliders, not a row of items, and a screen where
        // six bands ripple and the seventh blinks on reads as the seventh being
        // broken. Named elements give a ripple; anything else pops as one piece.
        // ⚠️ **THE RULERS START WITH THE FIRST ELEMENT, NOT AFTER THE LAST.**
        // A ruler is the readout of whatever the row chooses; arriving after the
        // row has settled it reads as a second thing happening. Its own sweep
        // runs out from the needle, so the two motions are travelling the same
        // way at the same time.
        let surfaces = (accessory as? PoppingTenant)?.revealingSurfaces ?? []
        for surface in surfaces { surface.reveal(after: 0) }
        #if DEBUG
        debugReveals.append(surfaces.count)
        #endif
        let named = (accessory as? PoppingTenant)?.poppableElements ?? []
        let elements = named.isEmpty ? [accessory] : named
        guard !elements.isEmpty else { return }
        #if DEBUG
        debugPopIns.append(elements.count)
        #endif
        for (index, element) in elements.enumerated() {
            // ⚠️ **ONE POP PER ELEMENT, UP TO THE POINT THE EAR STOPS COUNTING.**
            // The stagger is capped, so past `audibleElements` every remaining
            // element arrives at the same moment — and nine sounds fired at one
            // moment are not nine sounds, they are a click. What the ear hears
            // is the ripple, and the ripple is the part that is staggered.
            if index < BandPop.audibleElements { UISound.pop.play(after: BandPop.stagger(for: index)) }
            element.alpha = 0
            element.transform = BandPop.collapsedTransform
            UIView.animate(
                withDuration: BandPop.duration,
                delay: BandPop.stagger(for: index),
                usingSpringWithDamping: BandPop.dampingRatio,
                initialSpringVelocity: 0,
                // ⚠️ **THE ROW STAYS TAPPABLE WHILE IT ARRIVES.** Without this,
                // a finger that follows its own tap onto the first card waits
                // out the whole ripple before anything answers.
                options: [.allowUserInteraction]
            ) {
                element.alpha = 1
                element.transform = .identity
            }
        }
    }

    /// The departure curve, on a tenant the band has already let go of.
    ///
    /// ⚠️ **QUICKER THAN THE ARRIVAL, AND NOT STAGGERED.** Leaving is not an
    /// event the author is reading — they have already asked for something else
    /// — so the whole tenant goes at once and gets out of the way.
    ///
    /// ⚠️ **AND IT PUTS THE VIEW BACK AS IT FOUND IT.** Every tenant is built
    /// once and shown again; a row left at 0 alpha and three-quarter scale
    /// would come back invisible the next time it was asked for.
    private func popTheTenantOut(_ departing: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            departing.removeFromSuperview()
            return
        }
        #if DEBUG
        debugPopOuts += 1
        #endif
        UIView.animate(
            withDuration: BandPop.departure,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            departing.alpha = 0
            departing.transform = BandPop.collapsedTransform
        } completion: { _ in
            departing.alpha = 1
            departing.transform = .identity
            departing.removeFromSuperview()
        }
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
    /// Internal for tests: what the fill/fit glyph offers — it stands in the
    /// crop tools now, not in the header.
    var debugFitActionName: String? { cropTools.debugFitLabel }
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
    var debugCategoryTitles: [String] { categories.map(\.title) }
    /// Internal for tests: which category is open, nil while the strip is
    /// neutral.
    var debugSelectedCategory: String? { selectedCategory }
    /// Internal for tests: whether the picture runs under the bars.
    var debugCanvasIgnoresInsets: Bool { canvas.contentInsetAdjustmentBehavior == .never }
    /// Internal for tests: the strip in the bar, to read what it is wearing.
    var debugCategoryBar: IconSelectorBar { categoryBar }
    /// Internal for tests: chooses a category BY NAME, as the strip's `select`
    /// would. ⚠️ **NEVER BY POSITION** — a clip's list and a photograph's put
    /// the same category at different indices, and a test that picked "3"
    /// would open Stickers on one and Filters on the other.
    func debugChoose(_ title: String) {
        guard let index = categories.firstIndex(where: { $0.title == title }) else {
            preconditionFailure("\(title) is not offered here: \(categories.map(\.title))")
        }
        categoryBar.select(index)
    }
    /// Internal for tests: taps a category BY NAME, the way a finger would —
    /// a tap on the chosen one is a reselect.
    func debugTapCategory(_ title: String) {
        guard let index = categories.firstIndex(where: { $0.title == title }) else {
            preconditionFailure("\(title) is not offered here: \(categories.map(\.title))")
        }
        categoryBar.debugTap(index)
    }
    /// Internal for tests: the momentary bar the timeline mode puts opposite it.
    var debugActionBar: IconActionBar { actionBar }
    /// Internal for tests: the pill that holds the leading slot the rest of the
    /// time.
    var debugSoundPill: UIView { soundPill }
    /// Internal for tests: the width each strip is being held to, or nil where
    /// the rule is not being applied.
    var debugStripWidths: (leading: CGFloat, trailing: CGFloat)? {
        guard categoryBarWidth.isActive else { return nil }
        let leading = isTimelineShowing
            ? actionBarWidth.constant
            : Self.wantedWidth(of: soundPill)
        return (leading, categoryBarWidth.constant)
    }

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
    /// Internal for tests: whether a load is on its way to the preview.
    var debugPreviewIsPending: Bool { previewPending }
    /// Internal for tests: whether the preview is showing the file as shot for a
    /// held handle.
    var debugPreviewIsAiming: Bool { previewSubject?.aiming ?? false }
    /// Internal for tests: the arrangement the screen believes the preview plays.
    var debugPreviewTimeline: MediaTimeline? { previewSubject?.timeline }
    /// Internal for tests: the cut whose transition is being chosen.
    var debugTransitionSeam: Int? { transitionFocus?.seam }
    /// Internal for tests: the stretch the screen believes the item loops.
    var debugPreviewLoop: ClosedRange<Double>? { previewSubject?.loop }
    /// Internal for tests: a tap on the picture, through the routine the
    /// recogniser calls.
    func debugTapTheMedia() { mediaTapped() }
    /// Internal for tests: the play/pause glyph, and every state it flashed.
    var debugPlaybackFlashes: [Bool] { playbackFlash.debugFlashes }
    /// Internal for tests: the path "Next" takes, without a bar to tap.
    func debugTapNext() { goNext() }
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
    /// Internal for tests: the scissors, through the routine the bar calls.
    func debugSplitAtTheNeedle() { splitAtTheNeedle() }
    /// Internal for tests: the undo arrow, through the routine it actually calls.
    func debugTapUndo() { stepBack() }
    func debugTapRedo() { stepForward() }
    /// Internal for tests: the two arrows, to read what they offer.
    var debugUndoItem: UIBarButtonItem { undoItem }
    var debugRedoItem: UIBarButtonItem { redoItem }
    /// Internal for tests: whether the screen is holding the current page's
    /// picture — which is the poster the track borrows.
    var debugHasSourcePicture: Bool { lastSource != nil }

    /// Internal for tests: whether the screen is in crop mode.
    var debugIsCropping: Bool { isCropping }
    /// Internal for tests: the editing surface, to drive a drag without a finger.
    var debugCropSurface: MediaCropSurfaceView { cropSurface }
    /// Internal for tests: the tools in the band, to turn the dial without one.
    var debugCropTools: MediaCropToolsView { cropTools }
    /// Internal for tests: the band seam a mode would use, so a test can put
    /// something in the band that is not one of this screen's own tenants.
    func debugShowInBand(_ accessory: UIView?) { showInBand(accessory) }
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
    /// Internal for tests: whether the picture of `id` is travelling to a new
    /// place rather than standing in it — a curve is on its layer.
    func debugPictureIsMoving(for id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaEditorPageCell
        else { return false }
        return page.debugPictureIsMoving
    }

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

    /// Internal for tests: the path the crop's own reset takes, without a
    /// control to tap. It is the crop tools' now — the header walks the
    /// author's history instead.
    func debugTapResetCrop() { resetCrop() }
    /// Internal for tests: whether a display link is still scheduled.
    var debugFollowerIsScheduled: Bool { followerProxy.link != nil }
    /// Internal for tests: whether the bar is offering the two arrows, and on
    /// which side.
    var debugBarOffersTheArrows: Bool {
        let items = navigationItem.rightBarButtonItems ?? []
        return items.contains { $0 === undoItem } && items.contains { $0 === redoItem }
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
