// `AVURLAsset` — the trim is resolved against the FILE's length, not the item's
// declared one. See the note in `post()`.
import AVFoundation
import MediaPlayback
import CoreModels
import StickerKit
import DesignSystem
import UIKit

/// The last step of posting media: what was chosen, what it is called, and how
/// the author wants it to behave once it is out.
///
/// ```
/// ┌──────────────────────────┐
/// │ ‹ Save draft        Post │
/// │  ▣▣▣  the chosen media   │  ← full width, no card
/// │  ⧉ Change cover          │
/// ├──────────────────────────┤
/// │ Add a title              │
/// │ Write a caption…         │
/// ├──────────────────────────┤
/// │ Disclose as AI      [ ]  │
/// │ Comments          On ⌄   │
/// │ Hide points         [ ]  │
/// │ Hide reposts        [ ]  │
/// │ Hide bookmarks      [ ]  │
/// │ Allow downloads     [x]  │
/// └──────────────────────────┘
/// ```
///
/// ## ⚠️ What this screen can and cannot do
///
/// **The media and the caption are real. Nearly everything else is local.**
/// `post.v1.CreatePostRequest` carries `profileID`, `kind`, `caption`,
/// `attachments`, `parentID`, `rootID`, `audioRef` and `location` — and nothing
/// else. So:
///
/// - **The cover WORKS.** There is no cover field, but the FIRST attachment is
///   what every grid and feed shows a post by, and array order is carousel
///   order — so choosing a cover reorders what is published. This is the one
///   control here that genuinely reaches the server.
/// - **The title is drawn and NOT sent** (`dev/BACKEND_GAPS.md` §21). Folding it
///   into the caption was rejected: it would publish a composite string no
///   reader could split apart again.
/// - **The six settings are honoured by this screen and by nothing else**
///   (§22). They are operable, they hold their state for the length of the
///   compose, and they are deliberately NOT persisted anywhere — a preference
///   that outlived this screen would imply a setting the fleet has never heard
///   of. The footer says so in plain words, which is the privacy screen's rule
///   (§13a): a local honour-system control is acceptable only while it admits it.
///
/// ⚠️ **A VIDEO CARRIES ITS EDITS NOW, ALL OF THEM.** `MediaLibraryReading`
/// grew `videoFile(for:)` and a chosen clip uploads, leads the carousel if it is
/// the cover, and carries a poster frame. Everything the editor let the author
/// decide travels with it in one `VideoExportPlan` (`MediaEdits.exportPlan`) —
/// the pieces they kept and their rates, the crop and straighten, the look, the
/// overlays and the song — and `VideoExporter`'s compositor burns them into the
/// file (`dev/IOS_VIDEO_CAPTURE_UPLOAD.md` §5 P4). It is the mapping the
/// editor's canvas plays — asked here WITH the overlays, which the canvas draws
/// as views instead — so what was watched is what is published.
final class NewPostViewController: UIViewController {
    /// ⚠️ **THE SETTINGS ARE THREE SECTIONS, NOT ONE LIST.** Six switches in a
    /// single card is a wall: nothing in it tells the reader that hiding a
    /// count and disclosing AI are different kinds of decision. Grouped, each
    /// card asks one question — what the post says about itself, how people may
    /// engage with it, and what they may take away.
    private enum Section: Int, CaseIterable {
        case media
        case text
        case engagement
        case sharing
        case disclosure
        /// What happens on the author's own phone — the one card here whose
        /// choice this screen can honour completely, so it is kept apart from
        /// the three the server has never heard of (§22).
        case device
    }

    private enum Row: Hashable {
        case media
        case cover
        case title
        case caption
        case aiDisclosure
        case comments
        case points
        case reposts
        case bookmarks
        case downloads
        case saveToPhotos
    }

    /// Everything the author decides about the post, beyond its content.
    ///
    /// ⚠️ **A PLAIN VALUE OWNED BY THE SCREEN, WITH NO STORE BEHIND IT.** Not
    /// `UserDefaults`, not `CoreStorage`, nothing app-wide: none of these
    /// choices can be transmitted (§22), so persisting one would turn a known
    /// gap into a setting the viewer believes they have.
    struct Settings: Equatable {
        enum Comments: CaseIterable {
            case enabled, hidden, disabled

            var name: String {
                switch self {
                case .enabled: "On"
                case .hidden: "Hidden"
                case .disabled: "Off"
                }
            }

            var explanation: String {
                switch self {
                case .enabled: "Anyone can reply to this post."
                case .hidden: "Replies are collected but not shown."
                case .disabled: "Nobody can reply to this post."
                }
            }
        }

        var comments: Comments = .enabled
        // ⚠️ **SHOW, NOT HIDE — AND ON BY DEFAULT.** Phrased as "Hide points"
        // these read as opt-in restrictions and default OFF, which means the
        // switch's resting position is the opposite of the behaviour: nothing
        // is hidden, yet every switch sits dark. Stated positively, the resting
        // position IS the behaviour, and a viewer skimming the section sees the
        // post's actual state rather than a list of things not done.
        var showsPoints = true
        var showsReposts = true
        var showsBookmarks = true
        var allowsDownloads = true
        // ⚠️ DELIBERATELY NOT DEFAULTED ON. This one lives in Disclosure, not
        // Engagement: switching it on by default would have every post claim it
        // was made with AI, which is a false statement rather than a permissive
        // default.
        var disclosesAI = false
        // ⚠️ **OFF BY DEFAULT — ASKED FOR IN THOSE WORDS.** A capture is not
        // kept in the author's library by itself (*"non seulement dans le
        // post"*); keeping one is a choice made here, for this post
        // (*"une option pour sauvegarder … le ou les médias"*).
        var savesToPhotos = false
    }

    /// The size a full-bleed thumbnail is asked for. Generous, because the
    /// published image comes from this same seam.
    private static let publishPixels = CGSize(width: 1080, height: 1080)

    /// Names this screen's own keyboard-dismiss tap, so it can be found among
    /// the recognisers the collection view installs for itself.
    static let dismissTapName = "newPost.dismissKeyboard"

    private let items: [MediaLibraryItem]
    /// How the author left each picture in the editor — see `MediaEdits`. Absent
    /// means untouched. The crop and the look are baked into what is uploaded
    /// (see `post()`); the fit is honoured by the screens that draw the picture.
    private let edits: [String: MediaEdits]
    private let library: any MediaLibraryReading
    /// What plays the cover's clip in the strip — the editor's seam, unchanged.
    /// See `playCover` for why there is exactly one of these on this screen.
    private let preview: any MediaVideoPreviewing
    private let composer: any PostComposing
    /// Where a copy of what is published goes, when the author asks for one.
    private let photoLibrary: any PhotoLibrarySaving
    /// Where a published post hands back to — the flow's own dismissal.
    private let onPublished: (FeedEntry) -> Void

    /// What the author has already written, carried across a step back to the
    /// editor and forward again. Owned by the flow, not by this screen — this one
    /// is rebuilt on every "Next".
    private let draft: PostDraft

    #if DEBUG
    private var hasRunTheDebugScript = false
    /// Internal for tests: who was asked to end the flow — the sheet's
    /// presenter, never this screen.
    private(set) weak var debugFlowEndedBy: UIViewController?
    #endif

    private var postTitle = ""
    private var caption = ""
    private var settings = Settings()
    private var isPublishing = false

    /// Which chosen item leads the carousel — a photo or a video.
    private var coverID: String?

    /// The clip the strip is currently playing, and the surface it plays in.
    /// Both nil while nothing plays, which is every selection whose cover is a
    /// photograph.
    /// What each clip tile is doing, by item id — see
    /// `NewPostMediaCell.ClipState` and `clipTileTapped`.
    ///
    /// ⚠️ **THE SCREEN OWNS THIS, NOT THE CELL.** A list cell is rebuilt and
    /// recycled without asking, and a state kept inside one would reset itself
    /// every time the author changed a switch three rows down.
    private var clipStates: [String: NewPostMediaCell.ClipState] = [:]

    /// The frames each clip's sheet cycles, once they have been sampled.
    ///
    /// ⚠️ **SIX FRAMES AT THE TILE'S OWN HEIGHT IS 0.6MB A CLIP**, and the
    /// selection is capped at twenty: twelve megabytes in the worst case, held
    /// for a screen the author is looking at and freed with it. Sampling them at
    /// the tile's PIXEL size would be four times that for detail nobody reads
    /// in a moving 117pt thumbnail.
    private var clipSheets: [String: [UIImage]] = [:]

    /// The sampling in flight for each clip.
    ///
    /// ⚠️ **PER CLIP, NOT ONE COUNTER FOR THE STRIP.** `previewLoads` is global
    /// because there is one player and a second load abandons the first; these
    /// are independent reads of different files, and a shared counter made each
    /// one cancel the last. Measured: with three clips only the final tile ever
    /// got its frames, and the two before it sat on a still that looked exactly
    /// like a sheet waiting to arrive.
    private var sheetSamples: [String: Int] = [:]

    private var playingCoverID: String?
    private var coverSurface: VideoRenderView?
    /// Bumped on every start and every stop, so a load that was overtaken while
    /// it read a file abandons itself rather than binding to a cover the author
    /// has since moved off. The editor's `previewLoads` is the same counter.
    private var previewLoads = 0
    /// Whether the screen is actually being looked at. A load that lands after
    /// the screen has gone must not start anything.
    private var isOnScreen = false

    /// Whether the strip has made its entrance — see `bringTheStripIn`.
    private var stripHasArrived = false
    /// Whether motion is unwanted — `UIAccessibility`'s answer unless a test
    /// says otherwise. See `NewPostMediaCell.reducesMotion`.
    private let reducesMotion: () -> Bool

    private var list: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    private lazy var postItem = UIBarButtonItem(
        title: "Post",
        primaryAction: UIAction { [weak self] _ in self?.post() }
    )

    /// ⚠️ DRAWN AND INERT, like the editor's. Media drafts do not exist —
    /// `MediaDraftsViewController` is an empty list waiting for the notion — and
    /// `PostDraftStore` holds text only.
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


    /// What will actually be published, in order: the cover first, then the rest
    /// as they were chosen. The strip shows this, so changing the cover visibly
    /// moves it to the front.
    private var publishOrder: [MediaLibraryItem] {
        guard let coverID, let cover = items.first(where: { $0.id == coverID }) else { return items }
        return [cover] + items.filter { $0.id != coverID }
    }

    init(
        items: [MediaLibraryItem],
        edits: [String: MediaEdits] = [:],
        library: any MediaLibraryReading,
        composer: any PostComposing,
        preview: any MediaVideoPreviewing = MediaPreviewPlayer(),
        draft: PostDraft = PostDraft(),
        photoLibrary: any PhotoLibrarySaving = PhotoLibrarySaver(),
        reducesMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        onPublished: @escaping (FeedEntry) -> Void
    ) {
        self.photoLibrary = photoLibrary
        self.items = items
        self.edits = edits
        self.library = library
        self.preview = preview
        self.composer = composer
        self.draft = draft
        self.reducesMotion = reducesMotion
        self.onPublished = onPublished
        // ⚠️ **RESTORED BEFORE THE FIRST LAYOUT, NOT AFTER.** This screen is
        // rebuilt from scratch every time "Next" is pressed, so stepping back to
        // the editor and forward again used to hand the author an empty form.
        self.postTitle = draft.title
        self.caption = draft.caption
        self.settings = draft.settings
        // ⚠️ AN EXPLICIT PICK WINS OVER THE DEFAULT; NOTHING PICKED FALLS BACK.
        // The default below is computed, so storing it in the draft would make a
        // real choice indistinguishable from never having chosen.
        // ⚠️ **THE FIRST ITEM, NOT THE FIRST PHOTO.** This skipped videos while
        // they could not be published; keeping that would silently reorder a
        // selection that leads with a clip, handing the post a face its author
        // did not put first.
        self.coverID = draft.coverID ?? items.first?.id
        super.init(nibName: nil, bundle: nil)
        // ⚠️ THE TOP BAR BELONGS TO THE SCREEN, NOT TO ITS VIEW — a navigation
        // controller reads `navigationItem` on the way in. The picker and the
        // editor carry the same note.
        configureBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ NO TITLE, DELIBERATELY. The bar is `[‹][Save draft] ——— [Post]` and
        // nothing else: a centred title here competes with the two words either
        // side of it on a phone, and the screen's subject is the media directly
        // underneath.
        view.backgroundColor = .systemGroupedBackground
        configureList()
        applyRows()
    }

    /// ⚠️ **THE STRIP'S ENTRANCE STARTS HERE, AS THE PUSH BEGINS — NOT WHEN
    /// THE SCREEN HAS LANDED.** Asked for as *"déclencher avant, peut-être dès
    /// le tap sur Next"*. Measured on the iOS 27 simulator, pushes from the
    /// editor's "Next", in milliseconds after `viewWillAppear` — two untouched,
    /// then the list's layout forced here, root view alone and root then list:
    ///
    /// ```
    ///                          untouched     forced here
    ///                        run 1  run 2   root  root+list
    ///   viewIsAppearing        +17    +32     +6     +9
    ///   strip cell dequeued    +47    +86    +17    +34
    ///   list's first layout   +249   +420   +133   +255
    ///   viewDidAppear         +825  +1010   +692   +811
    /// ```
    ///
    /// The ripple used to start at `viewDidAppear`; it now starts at the end of
    /// the list's first layout — the last column, +255 against +811. The
    /// coordinator says the slide is 0.35s, but `viewDidAppear` waits for the
    /// whole transition to settle: a ripple started there began most of a
    /// second after the tap, on a screen that had stopped moving. Started here
    /// it begins about 0.55s sooner, while the push is still under way.
    ///
    /// ⚠️ **`viewIsAppearing`, NOT `viewWillAppear` — MEASURED, TOO.** At
    /// `viewWillAppear` the view is not in a window yet: forcing the list's
    /// layout there built eight rows outside any window, and the list laid
    /// itself out again as seven once it was in one — the work done twice, the
    /// first time wrong. At `viewIsAppearing` the view is in the window at its
    /// final size (402 wide on this simulator, the width the strip was dequeued
    /// at in every run), and the one forced layout below is the very pass the
    /// transition runs a few milliseconds later: the strip comes out at 402 and
    /// is not laid out again at any other width.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        bringTheStripIn()
    }

    /// ⚠️ **`viewDidAppear`, NOT `viewDidLoad` — THE TILE HAS TO EXIST FIRST.**
    /// The surface is laid over a tile inside the strip's cell, and at load time
    /// the collection view has dequeued nothing: `cellForItem` answers nil and
    /// the cover would silently never start. This is also the moment a pop back
    /// from anywhere lands on, which is what restarts the clip.
    ///
    /// The entrance is asked for again here only as a net: it has already run
    /// from `viewIsAppearing`, and runs once.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        bringTheStripIn()
        playCover()
        #if DEBUG
        runTheDebugScript()
        #endif
    }

    #if DEBUG
    /// ⚠️ **A PUBLISH HAD NO SCRIPTED WAY IN, AND THE PHOTOS PATH NEEDS ONE.**
    /// Keeping a copy runs a change block on Photos' own queue, and a block
    /// that inherited this screen's isolation compiles and traps the moment
    /// Photos calls it (`photos-handler-isolation-trap`) — no test host can
    /// answer the permission prompt that path needs, so only a running app can
    /// show it does not. `-upload-save-to-photos` switches the copy on and
    /// `-upload-publish` presses Post, after a beat; both once per screen.
    private func runTheDebugScript() {
        guard !hasRunTheDebugScript else { return }
        hasRunTheDebugScript = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-upload-save-to-photos"), !settings.savesToPhotos {
            setToggle(true, for: .saveToPhotos)
            reconfigure([.saveToPhotos])
        }
        if arguments.contains("-upload-publish") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.post() }
        }
    }
    #endif

    /// The strip's entrance: its tiles, held invisible since they were built,
    /// ripple in as the screen slides in — see `NewPostMediaCell.popTilesIn`.
    ///
    /// ⚠️ **ONCE PER SCREEN, AND A REBUILD DOES NOT REPLAY IT.** Changing the
    /// cover reorders the strip, and the reorder rebuilds every tile — but the
    /// author has made one small edit, and watching the whole row vanish and
    /// ripple back from the first tile reads as the screen RELOADING, which is
    /// the one thing it must not look like while the rest of their form sits
    /// still. The new order simply appears. A step back to the editor and
    /// "Next" again is a new screen (`UploadFeatureBuilder` builds one per
    /// push), so that entrance does ripple, as it should.
    ///
    /// ⚠️ **LAID OUT BEFORE THE FLAG IS SET, NOT AFTER** — and at
    /// `viewIsAppearing` the list has not even been given its frame yet
    /// (measured: 0×0, no rows). The root view's layout gives the list its
    /// size; only the list's own layout then dequeues the strip — measured,
    /// the first alone left it at zero rows. A strip built with the flag
    /// already up would never be held, and the entrance would quietly never
    /// happen.
    private func bringTheStripIn() {
        guard !stripHasArrived else { return }
        view.layoutIfNeeded()
        list.layoutIfNeeded()
        stripHasArrived = true
        strip?.popTilesIn()
    }

    /// ⚠️ **`viewWillDisappear` COVERS A PUSH AS WELL AS A POP, AND THAT IS WHY
    /// IT IS THIS ONE.** `viewDidDisappear` guarded on `isMovingFromParent`
    /// would leave the cover running underneath a screen pushed on top of it —
    /// a player decoding for a rectangle nobody can see, which is
    /// `profile-gallery-player-leak` told from the other end. The editor stops
    /// its preview from exactly here.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
        stopCover()
    }

    // MARK: - Bars

    private func configureBars() {
        // ⚠️ **UIKit'S OWN BACK BUTTON, BECAUSE THE BACK-SWIPE COMES WITH IT** —
        // see the editor's note for the measurement. A custom leading item
        // replaces the back button and silently takes the interactive pop with
        // it; `leftItemsSupplementBackButton` is what makes the item sit BESIDE
        // the chevron instead of in its place.
        navigationItem.leftBarButtonItems = [saveDraftItem]
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.rightBarButtonItems = [postItem]
        postItem.style = .done
    }

    // MARK: - The list

    /// ⚠️ **TWO APPEARANCES IN ONE LAYOUT, AND THAT IS THE POINT.** The media is
    /// the subject of this screen, not a row in a settings list: its section is
    /// drawn PLAIN with a clear background so the strip runs the full width with
    /// no white card behind it. Everything below is `.insetGrouped`, the shape
    /// every settings surface in this app already wears.
    private func configureList() {
        list = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        list.backgroundColor = .clear
        list.keyboardDismissMode = .interactive
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        list.prefersClearTopEdge()
        // ⚠️ **DISMISSING A KEYBOARD IS NOT THE SAME AS MAKING ROOM FOR ONE.**
        // This screen had the dismiss mode and a dismiss tap and nothing else,
        // so the field being typed into simply sat under the keyboard.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        // ⚠️ NOTHING ON THIS SCREEN IS SELECTABLE. Every control is a switch, a
        // menu button or a text field — so a row that greys itself under a
        // finger is announcing a selection that does not exist.
        list.allowsSelection = false
        list.pin(to: view)

        // ⚠️ NON-CANCELLING, OR IT EATS THE CONTROLS. The switches, the
        // Comments menu and "Change cover" must see every touch unchanged; this
        // only retires the keyboard, and is a no-op when nothing is editing.
        // PostDetail's stream tap sets the precedent.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        // ⚠️ NAMED, so a test can ask about THIS tap. A collection view installs
        // tap recognisers of its own and those DO cancel touches — an assertion
        // over "every tap on the list" fails on UIKit's rather than on ours, as
        // the first version of that test duly did.
        dismissTap.name = Self.dismissTapName
        list.addGestureRecognizer(dismissTap)

        let media = UICollectionView.CellRegistration<NewPostMediaCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.reducesMotion = reducesMotion
            cell.show(
                publishOrder, coverID: coverID, edits: edits,
                // Held only until the screen starts to appear — see
                // `bringTheStripIn`.
                holdsForArrival: !stripHasArrived
            ) { [weak self] id, size in
                await self?.library.thumbnail(for: id, size: size)
            }
            cell.onTileTapped = { [weak self] id in self?.clipTileTapped(id) }
            // ⚠️ **AFTER EVERY BUILD, BECAUSE A BUILD FORGETS** — `show` tears
            // every tile down and puts new ones up, so the state each clip was
            // in, and the frames it had, live here rather than in the cell.
            //
            // ⚠️ **AND WITH THE CELL IN HAND, NOT LOOKED UP.** Inside its own
            // registration block the cell is not yet answerable by
            // `cellForItem(at:)` — the `strip` accessor returns nil there, so a
            // lookup silently skipped the dressing on every build and every
            // tile came up in whatever state the cell was born in.
            dressTheClipTiles(on: cell)
        }
        let cover = UICollectionView.CellRegistration<NewPostButtonCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.backgroundConfiguration = .clear()
            cell.configure(
                title: "Change cover",
                symbolName: "square.on.square",
                menu: coverMenu(),
                // One photo is no choice, and none at all is not a cover.
                isEnabled: items.count > 1
            )
        }
        let title = UICollectionView.CellRegistration<NewPostTitleCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            // ⚠️ WRITTEN TO BOTH, AT THE SAME MOMENT. The draft is not a snapshot
            // taken on the way out — this screen can be torn down without a clean
            // transition, which is exactly the path that used to lose the text.
            cell.configure(text: postTitle) { [weak self] text in
                self?.postTitle = text
                self?.draft.title = text
            }
        }
        let caption = UICollectionView.CellRegistration<NewPostCaptionCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(text: self.caption) { [weak self] text in
                self?.caption = text
                self?.draft.caption = text
            }
        }
        let comments = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Comments"
            content.secondaryText = settings.comments.explanation
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            var configuration = UIButton.Configuration.gray()
            configuration.title = settings.comments.name
            configuration.image = UIImage(systemName: "chevron.up.chevron.down")
            configuration.imagePlacement = .trailing
            configuration.imagePadding = Spacing.xs
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            let button = UIButton(configuration: configuration)
            button.showsMenuAsPrimaryAction = true
            button.menu = self.commentsMenu()
            button.accessibilityLabel = "Comments, \(settings.comments.name)"
            cell.accessories = [.customView(configuration: .init(
                customView: button, placement: .trailing(displayed: .always)
            ))]
        }
        // ⚠️ A `UISwitch` IN THE ACCESSORY, so the whole row is not selectable —
        // the switch is the only control, and a row-wide tap target that toggles
        // nothing reads as broken. Profile's privacy screen sets this precedent.
        let toggle = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self, let spec = toggleSpec(for: row) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = spec.title
            content.secondaryText = spec.subtitle
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            let control = UISwitch()
            control.isOn = spec.isOn
            control.addAction(
                UIAction { [weak self] action in
                    guard let control = action.sender as? UISwitch else { return }
                    self?.setToggle(control.isOn, for: row)
                },
                for: .valueChanged
            )
            cell.accessories = [.customView(configuration: .init(
                customView: control, placement: .trailing(displayed: .always)
            ))]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { view, indexPath, row in
            switch row {
            case .media: view.dequeueConfiguredReusableCell(using: media, for: indexPath, item: row)
            case .cover: view.dequeueConfiguredReusableCell(using: cover, for: indexPath, item: row)
            case .title: view.dequeueConfiguredReusableCell(using: title, for: indexPath, item: row)
            case .caption: view.dequeueConfiguredReusableCell(using: caption, for: indexPath, item: row)
            case .comments: view.dequeueConfiguredReusableCell(using: comments, for: indexPath, item: row)
            case .aiDisclosure, .points, .reposts, .bookmarks, .downloads, .saveToPhotos:
                view.dequeueConfiguredReusableCell(using: toggle, for: indexPath, item: row)
            }
        }

        // The footer is where the screen admits what it cannot do.
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, indexPath in
            guard let self, let section = Section(rawValue: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedFooter()
            content.text = footerText(for: section)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            guard let self, let section = Section(rawValue: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = headerText(for: section)
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : view.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = Section(rawValue: index) else { return nil }
            var configuration: UICollectionLayoutListConfiguration
            switch section {
            case .media:
                configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.backgroundColor = .clear
                configuration.showsSeparators = false
            case .text, .disclosure, .engagement, .sharing, .device:
                configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            }
            // Asked for only where there is something to say: an empty header or
            // footer still takes a band of space.
            configuration.headerMode = headerText(for: section) == nil ? .none : .supplementary
            configuration.footerMode = footerText(for: section) == nil ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func headerText(for section: Section) -> String? {
        switch section {
        case .media, .text: nil
        case .disclosure: "Disclosure"
        case .engagement: "Engagement"
        case .sharing: "Sharing"
        case .device: "On this device"
        }
    }

    private func footerText(for section: Section) -> String? {
        switch section {
        case .media:
            nil
        case .text:
            "Titles aren't carried by the server yet, so only the caption is published."
        case .engagement, .sharing:
            nil
        case .disclosure:
            // ⚠️ ONE ADMISSION, ON THE LAST OF THE THREE CARDS — which is now
            // Disclosure. Repeating it under every settings section would nag;
            // leaving it out entirely would let six working controls imply a
            // promise the server never made.
            """
            These choices apply while you're composing. They aren't sent with the \
            post yet — comments stay on, counts stay visible, and every post is \
            public.
            """
        case .device:
            nil
        }
    }

    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.media, .cover], toSection: .media)
        snapshot.appendItems([.title, .caption], toSection: .text)
        snapshot.appendItems([.comments, .points, .reposts, .bookmarks], toSection: .engagement)
        snapshot.appendItems([.downloads], toSection: .sharing)
        snapshot.appendItems([.aiDisclosure], toSection: .disclosure)
        snapshot.appendItems([.saveToPhotos], toSection: .device)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Re-runs the registration for rows whose value changed under them.
    private func reconfigure(_ rows: [Row]) {
        var snapshot = dataSource.snapshot()
        let present = rows.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Gives the list up exactly as much room as the keyboard takes, and brings
    /// whatever is being edited into what is left.
    ///
    /// ⚠️ **THE FRAME IS CONVERTED, NEVER USED RAW.** The notification carries
    /// the keyboard in SCREEN coordinates, and this screen is a sheet — its view
    /// and the screen do not share an origin, so a raw frame over-insets by the
    /// sheet's own offset and pushes the content further than the keyboard ever
    /// covered.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let inView = view.convert(end, from: nil)
        // The safe-area inset is already room the list was never using, so it is
        // taken off — otherwise the home-indicator band is paid for twice.
        let overlap = max(0, view.bounds.maxY - inView.minY - view.safeAreaInsets.bottom)
        list.contentInset.bottom = overlap
        list.verticalScrollIndicatorInsets.bottom = overlap
        // Only on the way IN. On dismissal the overlap is zero and scrolling
        // then would jerk the list for no reason.
        guard overlap > 0 else { return }
        revealEditingField()
    }

    private func revealEditingField() {
        guard let editing = firstResponder(in: view) else { return }
        let frame = list.convert(editing.bounds, from: editing)
        // A little air above and below, so the caret never sits on the seam
        // between the field and the keyboard.
        list.scrollRectToVisible(frame.insetBy(dx: 0, dy: -12), animated: true)
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = firstResponder(in: sub) { return found }
        }
        return nil
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - The cover

    /// ⚠️ **EVERY ITEM, PHOTOS AND VIDEOS ALIKE — AND THE OLD REASON FOR
    /// EXCLUDING VIDEOS HAS EXPIRED.** This read "photos only", because a video
    /// could not be published and offering one would have promised a face the
    /// post never wore. A video now publishes and carries a poster frame, so it
    /// can lead the carousel like anything else.
    ///
    /// The number is the item's place in the selection, not its place among its
    /// own kind: "Video 2" is the second thing chosen, so the label answers
    /// "which one" rather than "which video".
    private func coverMenu() -> UIMenu {
        UIMenu(children: items.enumerated().map { index, item in
            UIAction(
                title: "\(item.isVideo ? "Video" : "Photo") \(index + 1)",
                state: item.id == coverID ? .on : .off
            ) { [weak self] _ in
                self?.setCover(item.id)
            }
        })
    }

    private func setCover(_ id: String) {
        guard coverID != id else { return }
        coverID = id
        // ⚠️ ONLY AN EXPLICIT PICK IS RECORDED. The initialiser computes a default
        // cover, so storing that would make "the author chose the first photo"
        // and "the author chose nothing" the same state on the way back.
        draft.coverID = id
        // ⚠️ **STOPPED BEFORE THE STRIP IS REDRAWN, STARTED AFTER.** Changing the
        // cover changes `publishOrder`, which changes the strip's signature,
        // which rebuilds every tile — including the one a player is bound to.
        // Stopping first is not belt and braces: the cell's `onSurfaceLost`
        // would fire from inside the redraw, and a stop asked for there arrives
        // while the row is half torn down.
        stopCover()
        // ⚠️ **A NEW COVER RESETS EVERY CLIP TILE TO ITS DEFAULT.** The cover is
        // the tile that rests, so changing which one it is changes what two
        // tiles should be doing — and keeping the old answers would leave the
        // former cover resting for no reason anyone could see. The author has
        // just changed what the post IS; the strip re-deriving its own resting
        // state is the least surprising thing it can do.
        clipStates.removeAll()
        reconfigure([.media, .cover])
        playCover()
    }

    // MARK: - The cover, moving

    /// Which clip tile holds the player, and what every other one is doing.
    ///
    /// ⚠️ **EVERY CLIP TILE IS INTERACTIVE; EXACTLY ONE OF THEM CAN MOVE.**
    /// Asked for as "if the thumbnail is a video, make it interactive, the video
    /// plays by default, a tap shows the spritesheet, another tap restarts it
    /// from the beginning" — and for the COVER, "the spritesheet state by
    /// default, and the Cover badge only in that state".
    ///
    /// The one player is why the default cannot be taken literally for every
    /// tile at once: each clip is a full `VideoExportPlan` built into an
    /// `AVComposition`, `MediaPreviewPlayer`'s pool is sized ONE, and asking it
    /// for a second surface evicts the first. So the rule is "the first clip
    /// that wants to play, gets to" — which IS every clip in the case that
    /// actually happens (one), and degrades to the sheet for the rest rather
    /// than to a frozen frame. That fallback is the reason the sheet is
    /// installed UNDER the surface and not instead of it.
    private func defaultClipState(for id: String) -> NewPostMediaCell.ClipState {
        // ⚠️ **THE COVER RESTS.** It is the tile wearing the word "Cover", and
        // the word is what the author is on this screen to check; a badge over
        // moving film is the noise the editor keeps its own chrome off the
        // picture to avoid.
        id == coverID ? .sheet : .playing
    }

    /// A tap on a clip's tile: the film, or its frames.
    private func clipTileTapped(_ id: String) {
        let wants: NewPostMediaCell.ClipState = clipStates[id] == .playing ? .sheet : .playing
        clipStates[id] = wants
        if wants == .playing {
            // ⚠️ **ONE AT A TIME, SO THE OTHERS YIELD.** Not a courtesy: the
            // seam has one surface, and a tile left claiming `.playing` would
            // keep asking for a player that is no longer its.
            for other in clipStates.keys where other != id { clipStates[other] = .sheet }
        }
        dressTheClipTiles()
        // ⚠️ **FROM THE BEGINNING, WHICH IS WHAT `stopCover` BUYS.** Asked for
        // in those words. A tap that only un-paused would resume wherever the
        // film happened to be, and the author who taps a thumbnail twice is
        // asking to watch it again, not to carry on.
        stopCover()
        playCover()
    }

    /// States every clip tile, and samples the frames the ones at rest need.
    private func dressTheClipTiles() {
        guard let strip else { return }
        dressTheClipTiles(on: strip)
    }

    private func dressTheClipTiles(on strip: NewPostMediaCell) {
        for item in publishOrder where item.isVideo {
            let state = clipStates[item.id] ?? defaultClipState(for: item.id)
            clipStates[item.id] = state
            if let frames = clipSheets[item.id] {
                strip.showSheet(frames, for: item.id)
            } else {
                sampleSheet(for: item.id)
            }
            strip.setClipState(state, for: item.id)
        }
    }

    /// Reads a handful of frames across the clip and hands them to its tile.
    ///
    /// ⚠️ **SAMPLED ONCE PER CLIP AND KEPT.** `frames(of:atSourceSeconds:…)` is
    /// the expensive call on this path — the timeline's own strip is built from
    /// it — and a sheet re-read on every state change would pay for it on every
    /// tap.
    ///
    /// ⚠️ **AND THE FRAMES WEAR THE AUTHOR'S LOOK.** A sheet in colour under a
    /// clip the author made mono is the same defect this strip already shipped
    /// once for its stills.
    private func sampleSheet(for id: String) {
        guard clipSheets[id] == nil else { return }
        let sample = (sheetSamples[id] ?? 0) + 1
        sheetSamples[id] = sample
        let declared: Double
        if case .video(let seconds) = items.first(where: { $0.id == id })?.kind {
            declared = seconds
        } else {
            declared = 0
        }
        let look = (edits[id] ?? .untouched).look
        Task { [weak self] in
            guard let self, let file = await library.videoFile(for: id) else { return }
            let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? declared
            let length = real.isFinite && real > 0 ? real : declared
            guard length > 0 else { return }
            // Evenly across the film, skipping its very first and last moments:
            // a clip's opening frame is the one that is routinely black.
            let count = Self.sheetFrameCount
            let moments = (0..<count).map { index in
                length * (Double(index) + 0.5) / Double(count)
            }
            let sampled = await preview.frames(
                of: file, atSourceSeconds: moments, height: Self.sheetFrameHeight, spacing: 0
            )
            guard sheetSamples[id] == sample, !sampled.isEmpty else { return }
            let ordered = moments.compactMap { sampled[$0] }
            guard !ordered.isEmpty else { return }
            let dressed = await Task.detached(priority: .utility) {
                ordered.compactMap { frame -> UIImage? in
                    guard let source = CIImage(image: frame) else { return frame }
                    let looked = FrameLookRenderer.apply(look, to: source, time: 0)
                    guard let cg = EditingRenderContext.shared.createCGImage(looked, from: source.extent)
                    else { return frame }
                    return UIImage(cgImage: cg, scale: frame.scale, orientation: frame.imageOrientation)
                }
            }.value
            guard sheetSamples[id] == sample, !dressed.isEmpty else { return }
            clipSheets[id] = dressed
            strip?.showSheet(dressed, for: id)
            strip?.setClipState(clipStates[id] ?? defaultClipState(for: id), for: id)
        }
    }

    /// ⚠️ **SIX, AND AT THE TILE'S POINT HEIGHT.** See `clipSheets` for the
    /// arithmetic: this is the number that keeps a twenty-clip selection inside
    /// twelve megabytes of decoded frames.
    private static let sheetFrameCount = 6
    private static let sheetFrameHeight: CGFloat = 208

    /// Plays the clip whose tile is the one holding the player.
    ///
    /// ⚠️ **ONE PLAYER, ON THE COVER, AND ONLY WHEN THE COVER IS A CLIP.** The
    /// obvious reading of "the thumbnails show a still for a video" is that
    /// every video tile should move. It should not. The selection is capped at
    /// twenty and each clip here is a full `VideoExportPlan` — pieces, rates,
    /// crop, look and a song, built into an `AVComposition` per player — so a
    /// strip of twenty moving thumbnails is twenty compositions decoding at once
    /// behind a settings form. `profile-gallery-player-leak` is this repository's
    /// record of what accumulating players does, and
    /// `MediaPreviewPlayer`'s pool is sized ONE for the same reason one level
    /// down: asking it for a second surface would evict the first anyway, so
    /// "play them all" is not even expressible through this seam.
    ///
    /// The cover is the frame the post will actually show — the first
    /// attachment is what every grid and feed draws a post by (see this
    /// screen's own note above) — so it is the one worth spending the player on.
    /// A photograph cover plays nothing and every tile stays a still, which is
    /// the correct picture of a post that will not move either.
    ///
    /// ⚠️ **THE OVERLAYS DO NOT REACH THE PLAYING PICTURE, AND THAT IS THE
    /// PREVIEW PATH, NOT THIS CALL.** `exportPlan` is asked the way the editor
    /// asks it — without overlays and without artwork — because
    /// `VideoPlaybackController.load` hands its compositor
    /// `FrameFinish(crop:look:)` and nothing else: overlays are dropped whatever
    /// this passes. So a clip carrying text shows it on the still and loses it
    /// the moment it starts. The editor does not have this gap because its
    /// canvas draws overlays as views over the surface; a 117pt tile does not,
    /// and giving it one would be a second feature.
    private func playCover() {
        guard isOnScreen else { return }
        // ⚠️ **PUBLISH ORDER DECIDES, SO THE ANSWER IS STABLE.** `clipStates` is
        // a dictionary and its order is not; picking "a clip that wants to
        // play" from it would hand the player to a different tile on different
        // runs, and the author would see a different thumbnail moving each time
        // they came back to the screen.
        let wanting = publishOrder.first {
            $0.isVideo && (clipStates[$0.id] ?? defaultClipState(for: $0.id)) == .playing
        }
        guard let id = wanting?.id else { return stopCover() }
        // ⚠️ **LAID OUT FIRST, OR THERE IS NO TILE TO PLAY ON.** `viewDidAppear`
        // can run before the list has dequeued its first cell — the strip is a
        // cell like any other — and `cellForItem` answers nil for a row that has
        // not been laid out. Asking for the layout is what makes the rectangle
        // exist; without it the cover starts on the second appearance and never
        // on the first.
        list.layoutIfNeeded()
        guard let strip, let surface = strip.videoSurface(over: id) else { return }
        // Already playing this clip, in this very rectangle: a second appearance
        // or a reload that changed nothing must not mint a second item.
        guard playingCoverID != id || coverSurface !== surface else { return }
        stopCover()
        playingCoverID = id
        coverSurface = surface
        // ⚠️ THE CELL TELLS US WHEN THE RECTANGLE GOES. A strip redrawn under a
        // bound surface — a cover change, a recycled cell — would otherwise
        // leave the player decoding into a view with no superview.
        strip.onSurfaceLost = { [weak self] lost in
            guard let self, coverSurface === lost else { return }
            stopCover()
        }
        loadCover(id, into: surface)
    }

    /// Reads the clip and hands the seam the arrangement the author made of it.
    ///
    /// ⚠️ **MUTED AFTER THE LOAD, NOT BEFORE, AND NOT LEFT TO THE SEAM.**
    /// `MediaPreviewPlayer.load` ends with
    /// `setMuted(!carriesSoundtrack(in:))` — a clip the author put a song under
    /// therefore arrives UNMUTED, which is right on the editor's canvas and
    /// wrong here: this is a form with a title field and six switches on it, and
    /// a thumbnail that starts singing while somebody writes a caption is a
    /// defect. Asked after the item is in, because that is when the seam makes
    /// its own decision.
    ///
    /// ⚠️ **THE LANDING IS WHAT MAKES IT LOOP, AND `setLoopRange` IS NOT CALLED.**
    /// A landing naming no range settles the player on `.wholeItem`
    /// (`VideoPlaybackController.load`), so the arrangement runs to its end and
    /// starts again — which is the whole of what a thumbnail wants.
    /// `setLoopRange` exists for rehearsing a few seconds around a cut, a notion
    /// this screen does not have; asked with nil straight after a fresh landing
    /// it would write `.wholeItem` over `.wholeItem`, and a line that does
    /// nothing is worse than none.
    private func loadCover(_ id: String, into surface: VideoRenderView) {
        previewLoads += 1
        let load = previewLoads
        let declared: Double
        if case .video(let seconds) = items.first(where: { $0.id == id })?.kind {
            declared = seconds
        } else {
            declared = 0
        }
        Task { [weak self] in
            guard let self else { return }
            guard let file = await library.videoFile(for: id) else { return }
            // ⚠️ AGAINST THE FILE'S OWN LENGTH, NOT THE ITEM'S DECLARED ONE —
            // the same read `post()` makes, for the same reason: a declaration
            // can outlive the bytes it describes, and pieces resolved past the
            // end play nothing.
            let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? declared
            let length = real.isFinite && real > 0 ? real : declared
            guard previewLoads == load else { return }
            let edited = edits[id] ?? .untouched
            await preview.load(
                edited.exportPlan(
                    sourceURL: file, fileSeconds: length, artwork: nil, includingOverlays: false
                ),
                in: surface
            ) { [weak self] in
                // ⚠️ RE-ASKED AS THE ITEM GOES IN. Reading the file takes a
                // moment and the author may have changed the cover, pressed Post
                // or left the screen; nil is how a load abandons itself.
                guard let self, previewLoads == load, playingCoverID == id else { return nil }
                return VideoLoadLanding(seconds: 0)
            }
            guard previewLoads == load, playingCoverID == id else { return }
            preview.setMuted(true, in: surface)
        }
    }

    /// Gives the player back and puts the cover's tile back to its still.
    /// Idempotent: everything below is already true when nothing is playing.
    private func stopCover() {
        // Whatever is on its way belongs to a cover that is no longer playing.
        previewLoads += 1
        playingCoverID = nil
        guard let surface = coverSurface else { return }
        coverSurface = nil
        preview.stop(surface)
        strip?.onSurfaceLost = nil
        strip?.hideVideoSurface()
    }

    /// The strip's cell, while the list is showing one.
    private var strip: NewPostMediaCell? {
        dataSource.indexPath(for: .media).flatMap { list.cellForItem(at: $0) } as? NewPostMediaCell
    }

    // MARK: - The settings

    private func toggleSpec(for row: Row) -> (title: String, subtitle: String, isOn: Bool)? {
        switch row {
        case .aiDisclosure:
            ("Disclose as AI-generated", "Tell viewers this post was made with AI.", settings.disclosesAI)
        case .points:
            ("Show points", "Anyone can see how many points this post has.", settings.showsPoints)
        case .reposts:
            ("Show reposts", "Anyone can see how often it has been reposted.", settings.showsReposts)
        case .bookmarks:
            ("Show bookmarks", "Anyone can see how often it has been saved.", settings.showsBookmarks)
        case .downloads:
            ("Allow downloads", "Let anyone save this post to their device.", settings.allowsDownloads)
        case .saveToPhotos:
            (
                "Save to Photos",
                "Keep a copy of the edited photos and videos in your library when you post.",
                settings.savesToPhotos
            )
        default:
            nil
        }
    }

    /// Written through immediately rather than behind a Save button: these are
    /// switches, and a switch that needs confirming is one the viewer will
    /// assume already took effect.
    private func setToggle(_ isOn: Bool, for row: Row) {
        switch row {
        case .aiDisclosure: settings.disclosesAI = isOn
        case .points: settings.showsPoints = isOn
        case .reposts: settings.showsReposts = isOn
        case .bookmarks: settings.showsBookmarks = isOn
        case .downloads: settings.allowsDownloads = isOn
        case .saveToPhotos:
            settings.savesToPhotos = isOn
            if isOn { confirmLibraryAccess() }
        // ⚠️ `Row` CARRIES ELEVEN CASES AND ONLY SIX ARE SWITCHES. The rest —
        // media, cover, title, caption, comments — never reach here, so leaving
        // early is both the exhaustiveness the compiler wants and a refusal to
        // rewrite the draft for a row that changed nothing.
        default: return
        }
        // ⚠️ THE SETTINGS TRAVEL TOO. The request was the creation PROCESS, not
        // the text field: a switch flipped before stepping back to the editor
        // would otherwise come back to its default.
        draft.settings = settings
    }

    private func commentsMenu() -> UIMenu {
        UIMenu(children: Settings.Comments.allCases.map { choice in
            UIAction(
                title: choice.name,
                state: settings.comments == choice ? .on : .off
            ) { [weak self] _ in
                self?.setComments(choice)
            }
        })
    }

    private func setComments(_ choice: Settings.Comments) {
        guard settings.comments != choice else { return }
        settings.comments = choice
        // The comments choice has its own write site, separate from the toggles —
        // missing it would carry four settings across the step back and drop one.
        draft.settings = settings
        reconfigure([.comments])
    }

    // MARK: - Publishing

    /// ⚠️ **IN THE ORDER THEY WILL APPEAR.** The array's order is the carousel's
    /// order — `post.v1` has no per-attachment index — so the media are fetched
    /// one at a time rather than through a task group that would return them in
    /// whatever order the library answered. The cover leads because
    /// `publishOrder` puts it there.
    ///
    /// Photos and videos take different routes out of the library and meet again
    /// as `ComposeMedia`: a photo is read at publish size and baked with its
    /// edits here, a video is read as a file and handed over as the plan the
    /// exporter draws. Both consult `edits`: a photograph takes the crop, the
    /// look and the overlays, a clip takes those and its pieces and its song as
    /// well. What differs is WHERE the pixels are made —
    /// `MediaEdits.applied(to:artwork:)` on this screen for a picture,
    /// `VideoCompositor` inside the export for a clip.
    ///
    /// The title and the six settings are NOT sent: nothing in the contract
    /// carries them (§21, §22).
    private func post() {
        guard !isPublishing else { return }
        isPublishing = true
        postItem.isEnabled = false
        // ⚠️ **THE FORM FREEZES WHILE THE POST GOES OUT.** A clip's export and
        // upload take seconds, and a switch flipped meanwhile — Save to Photos
        // above all, whose refusal presents an alert — changed a post that was
        // already on its way, and could leave an alert standing where the
        // sheet's own dismissal would land.
        if isViewLoaded { list.isUserInteractionEnabled = false }
        // ⚠️ **THE COVER STOPS BEFORE THE EXPORT STARTS.** Publishing a clip
        // builds an `AVAssetExportSession` over the very file the strip is
        // playing; leaving a composition decoding beside it buys the author
        // nothing — the screen is on its way out — and takes decode bandwidth
        // off the one piece of work they are waiting for. It also removes a
        // race: the loop below reads `videoFile(for:)` for the same id.
        stopCover()

        Task { [weak self] in
            guard let self else { return }
            do {
                var media: [ComposeMedia] = []
                for item in publishOrder {
                    if item.isVideo {
                        // ⚠️ **A VIDEO THAT CANNOT BE READ STOPS THE POST; A
                        // PHOTO THAT CANNOT BE READ IS SKIPPED. THE ASYMMETRY IS
                        // DELIBERATE.** The grid has already drawn every photo,
                        // so `thumbnail` here is a second successful read of
                        // something that was on screen a moment ago. This is the
                        // FIRST time a video's actual bytes are touched — the
                        // grid only ever had its poster — and the usual reason
                        // it fails is an iCloud download that did not finish.
                        // That is worth telling the author about; publishing a
                        // shorter carousel than they assembled is not. Dropping
                        // videos in silence is the whole defect this screen is
                        // being fixed of.
                        guard let file = await library.videoFile(for: item.id) else {
                            throw ComposeError.media(
                                "Couldn't read one of the videos. It may still be downloading from iCloud."
                            )
                        }
                        // ⚠️ **RESOLVED HERE, AGAINST THE DECLARED DURATION.**
                        // A stored trim is two numbers that can outlive the clip
                        // they were made for; what crosses to the composer is
                        // the answer, already brought inside a real length.
                        // `cuts` rather than `!isWhole`: a range covering the
                        // whole clip is the same instruction as no range at all,
                        // and only nil takes the exporter's passthrough.
                        // ⚠️ **AGAINST THE FILE'S OWN LENGTH, NOT THE ITEM'S
                        // DECLARED ONE.** The declaration is whatever vended the
                        // item said, and it can disagree with the bytes — under
                        // `-rich-media` a fixture whose download failed falls
                        // back to a synthetic clip, so an item can truthfully
                        // say 52 seconds over a file of two and a half.
                        // Resolving against the declaration would hand the
                        // exporter a range past the end and publish nothing.
                        // The editor's track asks the same question of the same
                        // asset, so the two cannot drift apart.
                        let declared: Double
                        if case .video(let seconds) = item.kind { declared = seconds } else { declared = 0 }
                        let real = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? declared
                        let length = real.isFinite && real > 0 ? real : declared
                        let edited = edits[item.id] ?? .untouched
                        // ⚠️ **EVERY PIECE, AND THIS LINE USED TO TAKE ONLY THE
                        // FIRST.** `PickedVideo` carried a single range and the
                        // exporter a single `insertTimeRange`, so a timeline of
                        // several pieces published its opening one and dropped
                        // the rest — silently, because what came out was a
                        // perfectly good video. The mapping is shared with the
                        // editor's preview, so what is published is what was
                        // watched.
                        //
                        // ⚠️ **AND THE WHOLE EDIT, NOT ONLY THE PIECES** — the
                        // one mapping the preview uses, overlays included here
                        // because the editor draws them as views.
                        let art = await Self.stickerArt(for: edited, motion: .loop)
                        let plan = edited.exportPlan(
                            sourceURL: file, fileSeconds: length, artwork: art, includingOverlays: true
                        )
                        media.append(.video(PickedVideo(
                            sourceURL: file, keptPieces: plan.segments,
                            finish: plan.finish, soundtrack: plan.soundtrack, artwork: plan.artwork
                        )))
                        continue
                    }
                    guard let image = await library.thumbnail(for: item.id, size: Self.publishPixels) else {
                        continue
                    }
                    // ⚠️ **BAKED HERE, ON THE FULL-RESOLUTION PICTURE.** The editor
                    // showed the crop and the look on a canvas-sized render and on a
                    // 56pt chip; neither of those is what gets uploaded. Both are
                    // applied to the publish-sized image and BEFORE `MediaEncoder`,
                    // which downscales and compresses — rendering after that would
                    // work on pixels the viewer never approved.
                    //
                    // ⚠️ THE ORDER IS CUT THEN DRESS, and it lives in one place:
                    // `MediaEdits.applied(to:artwork:)`, which four render paths
                    // share so they cannot drift apart.
                    //
                    // ⚠️ A FAILED RENDER PUBLISHES THE ORIGINAL RATHER THAN NOTHING.
                    // Dropping the picture because a crop or a filter could not be
                    // rasterised would lose the author's photograph over a
                    // decoration. `applied(to:artwork:)` carries that rule.
                    //
                    // ⚠️ STICKERS ARE BAKED FIRST, AS STILLS: a photograph has no
                    // time, and the render reads the frames off any thread.
                    let edited = edits[item.id] ?? .untouched
                    let stills = await Self.stickerArt(for: edited, motion: .still)
                    let baked = edited.applied(to: image, artwork: stills)
                    media.append(.image(PickedImage(baked)))
                }
                let entry = try await composer.publish(media: media, caption: caption, as: nil)
                onPublished(entry)
                // ⚠️ **AFTER THE POST IS UP, NEVER INSTEAD OF IT.** A copy that
                // cannot be kept costs the author the copy, not the post — so it
                // is tried once the post exists, and a failure is said before
                // the sheet goes rather than swallowed with it.
                if settings.savesToPhotos, !(await keepACopy(of: media, published: entry)) {
                    present(Self.copyFailureAlert { [weak self] in self?.endTheFlow() }, animated: true)
                    return
                }
                endTheFlow()
            } catch {
                isPublishing = false
                postItem.isEnabled = true
                if isViewLoaded { list.isUserInteractionEnabled = true }
                present(Self.failureAlert(error), animated: true)
            }
        }
    }

    /// The baked frames of the stickers an edit lays over its picture — nil
    /// when it lays none, so nothing is baked for a post without stickers.
    private static func stickerArt(
        for edited: MediaEdits, motion: StickerFrameBaker.Motion
    ) async -> (any OverlayArtwork)? {
        let ids = edited.overlays.compactMap { overlay -> String? in
            if case .sticker(let id) = overlay.content { return id }
            return nil
        }
        guard !ids.isEmpty else { return nil }
        return await StickerFrameBaker.shared.artwork(
            for: ids, side: StickerFrameBaker.exportSide, motion: motion
        )
    }

    // MARK: - A copy in the library

    /// Switching the copy on is when the library is asked — not at publish,
    /// where a prompt would stand between the author and a post that is
    /// already on its way.
    ///
    /// ⚠️ **REFUSED, THE SWITCH GOES BACK OFF AND SAYS WHY.** Left on, it would
    /// promise a copy the library had already declined to take.
    private func confirmLibraryAccess() {
        Task { [weak self] in
            guard let self, await !photoLibrary.requestAccess(), settings.savesToPhotos else { return }
            settings.savesToPhotos = false
            draft.settings = settings
            reconfigure([.saveToPhotos])
            // ⚠️ NOT OVER A POST ON ITS WAY OUT: the sheet is about to go, and
            // the switch going back off already says it.
            guard !isPublishing else { return }
            present(Self.accessRefusedAlert(), animated: true)
        }
    }

    /// The flow ends: the whole sheet goes, not just this screen.
    ///
    /// ⚠️ **ASKED OF THE SHEET'S PRESENTER, NOT OF THIS SCREEN.** `dismiss` on
    /// a screen that is itself presenting something — an alert — dismisses
    /// THAT, and the sheet stayed up over a post that was already live, with
    /// its Post button dead for good.
    private func endTheFlow() {
        let presenter = presentingViewController
        presenter?.dismiss(animated: true)
        #if DEBUG
        debugFlowEndedBy = presenter
        #endif
    }

    /// Adds what was just published to the library. False when nothing, or
    /// not everything, could be kept.
    private func keepACopy(of media: [ComposeMedia], published entry: FeedEntry) async -> Bool {
        let copies = Self.libraryCopies(of: media, published: entry.post.attachments)
        guard copies.count == media.count else { return false }
        do {
            try await photoLibrary.save(copies)
            return true
        } catch {
            return false
        }
    }

    /// What goes into the library for each piece of the post, in its order.
    ///
    /// ⚠️ **A CLIP'S COPY IS THE EXPORTED FILE, FOUND ON THE ENTRY.** The
    /// export happens inside the composer, and the entry it hands back plays a
    /// clip from that local file (`PostComposer.uploadVideo`) — the one file
    /// with every edit burned in. An attachment that is not a local file has
    /// no copy to give, and is left out rather than replaced by the unedited
    /// original, so the count tells `keepACopy` that something was missed.
    static func libraryCopies(of media: [ComposeMedia], published attachments: [MediaAttachment]) -> [PhotoLibraryCopy] {
        media.enumerated().compactMap { index, piece in
            switch piece {
            case .image(let picked):
                return picked.image.jpegData(compressionQuality: 0.95).map(PhotoLibraryCopy.photo)
            case .video:
                guard attachments.indices.contains(index), let file = attachments[index].url, file.isFileURL
                else { return nil }
                return .video(file)
            }
        }
    }

    private static func accessRefusedAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Photos access is off",
            message: "Allow adding to Photos in Settings to keep a copy of your posts.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        return alert
    }

    private static func copyFailureAlert(then done: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(
            title: "Posted",
            message: "Your post is up, but a copy couldn't be saved to Photos.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        return alert
    }

    private static func failureAlert(_ error: Error) -> UIAlertController {
        let alert = UIAlertController(
            title: "Couldn't post",
            message: (error as? ComposeError).map(message(for:)) ?? "Something went wrong. Try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    private static func message(for error: ComposeError) -> String {
        switch error {
        case .emptyPost: "Add a photo or write something first."
        case .notAuthenticated, .noViewerProfile: "Sign in again to post."
        case .media(let why): why
        case .transport(let why): why
        }
    }
}

#if DEBUG
extension NewPostViewController {
    /// Internal for tests: the rows the screen is showing, in order.
    var debugRowCount: Int { dataSource.snapshot().numberOfItems }
    /// Internal for tests: what the caption holds.
    var debugCaption: String { caption }
    /// Internal for tests: what the title holds — which is never published.
    var debugTitle: String { postTitle }
    /// Internal for tests: the choices the author has made.
    var debugSettings: Settings { settings }
    /// Internal for tests: which photo leads the carousel.
    var debugCoverID: String? { coverID }
    /// Internal for tests: what would actually be published, in order.
    var debugPublishOrder: [String] { publishOrder.map(\.id) }
    /// Internal for tests: whether the screen has landed — `viewDidAppear` has
    /// run — as opposed to being on its way in.
    var debugHasLanded: Bool { isOnScreen }
    /// Internal for tests: the footer a section is wearing, if any.
    func debugFooterText(forSection index: Int) -> String? {
        Section(rawValue: index).flatMap(footerText(for:))
    }
    /// Internal for tests: whether a row can be selected at all.
    ///
    /// ⚠️ PINNED AS A PROPERTY, NOT AS A SCREENSHOT. A selection highlight
    /// exists only while a finger is down and clears on release, so a capture
    /// taken after the tap shows the resting state whether selection is on or
    /// off — it cannot tell the two apart. This can.
    var debugAllowsSelection: Bool { list.allowsSelection }

    /// Internal for tests: whether THIS screen's dismiss tap swallows the touch.
    /// Nil when it is not installed at all.
    ///
    /// ⚠️ **ASKED OF OUR TAP BY NAME.** A `UICollectionView` installs tap
    /// recognisers of its own and they DO cancel touches, so "no tap on the list
    /// cancels" is false for reasons that have nothing to do with this screen.
    /// The first version of this accessor returned every tap and the test failed
    /// on UIKit's, not on ours.
    var debugDismissTapCancelsTouches: Bool? {
        (list.gestureRecognizers ?? [])
            .first { $0.name == Self.dismissTapName }?
            .cancelsTouchesInView
    }

    /// Internal for tests: the header a section is wearing, if any.
    func debugHeaderText(forSection index: Int) -> String? {
        Section(rawValue: index).flatMap(headerText(for:))
    }
    /// Internal for tests: how many sections the screen draws, and how many
    /// rows sit in each.
    var debugSectionCount: Int { dataSource.snapshot().numberOfSections }
    func debugRowCount(inSection index: Int) -> Int {
        guard let section = Section(rawValue: index) else { return 0 }
        return dataSource.snapshot().numberOfItems(inSection: section)
    }
    /// Internal for tests: the cover menu, without a button to press.
    func debugCoverMenu() -> UIMenu { coverMenu() }
    /// Internal for tests: choosing a cover, without a menu to open.
    func debugSetCover(_ id: String) { setCover(id) }
    /// Internal for tests: moving one switch, without a bar to reach it.
    func debugSetComments(_ choice: Settings.Comments) { setComments(choice) }
    /// Internal for tests: typing, without a keyboard. These write where the
    /// cells write, so what `post()` reads afterwards is what a viewer's typing
    /// would have left there.
    func debugType(title: String) { postTitle = title }
    func debugType(caption: String) { self.caption = caption }
    /// Internal for tests: the path "Post" takes, without a bar to tap.
    func debugTapPost() { post() }
    /// Internal for tests: flipping a switch, through the routine the switch
    /// itself calls.
    func debugFlip(saveToPhotos isOn: Bool) { setToggle(isOn, for: .saveToPhotos) }
    /// Internal for tests: what the switch says.
    var debugSavesToPhotos: Bool { settings.savesToPhotos }
    /// Internal for tests: whether the form takes touches.
    var debugFormIsLive: Bool { list.isUserInteractionEnabled }
}
#endif
