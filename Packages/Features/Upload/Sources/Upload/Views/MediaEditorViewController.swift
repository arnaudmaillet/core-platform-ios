import DesignSystem
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
/// ⚠️ **A VIDEO DRAWS ITS POSTER FRAME, NOT PLAYBACK.** `MediaLibraryReading`
/// vends images, and no player is injected into this package — so a chosen video
/// shows the same frame the grid showed it by. No play glyph is laid over it, on
/// purpose: a button that promises playback and does nothing is worse than a
/// still that promises nothing.
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
    }


    /// What the strip at the foot of the screen offers. Editing itself is not
    /// built, so this is the list the design asks for and nothing more.
    static let categories = ["Effects", "Text", "Stickers", "Filters"]

    private let items: [MediaLibraryItem]
    private let itemsByID: [String: MediaLibraryItem]
    private let library: any MediaLibraryReading
    /// What "Next" hands the media to. The step that writes a caption and
    /// publishes is still a stand-in, so the builder passes a screen saying so.
    /// ⚠️ CARRIES THE FIT CHOICES AND THE LOOKS TOO. The step after this one
    /// draws the same pictures as thumbnails — a picture the author chose to show
    /// WHOLE must not reappear cropped — and it is where a look is baked into the
    /// full-resolution image that is uploaded.
    private let onNext: ([MediaLibraryItem], [String: ContentFit], [String: MediaFilter]) -> UIViewController

    /// ⚠️ A `CarouselCollectionView`, NOT A PLAIN ONE: on its first page it
    /// declines a rightward drag so the stack's back-swipe can carry the screen
    /// back. See `CarouselBackSwipe`.
    private var canvas: CarouselCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let categoryBar = PagedTabBar(
        titles: MediaEditorViewController.categories, style: .navigationTitle
    )

    private lazy var nextItem = UIBarButtonItem(
        title: "Next",
        primaryAction: UIAction { [weak self] _ in self?.goNext() }
    )

    /// ⚠️ **PER ITEM, NOT PER SCREEN.** "Fill or fit the current media" is a
    /// decision about one picture: a portrait shot and a landscape one in the
    /// same carousel want opposite answers, and a single screen-wide flag would
    /// make choosing for one of them undo the choice for the other. Absent means
    /// `.fill`, which is what the canvas has always done.
    private var fits: [String: ContentFit] = [:]

    /// Which look each picture is being shown in. Per item for the same reason
    /// `fits` is: a carousel holds several pictures and a screen-wide choice
    /// would make dressing one of them undress another. Absent means
    /// `.original`, which is the picture untouched.
    ///
    /// ⚠️ **CARRIED TO THE PUBLISH PATH, AND BAKED THERE.** `onNext` hands these
    /// on with the fits, and the finalisation screen applies the look to the
    /// FULL-RESOLUTION picture it uploads — not to the preview. A look chosen
    /// here is therefore in the post, which is why nothing may quietly drop it.
    private var filters: [String: MediaFilter] = [:]

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
    /// `MediaEditorBandView`. Empty today: this round reserves the room, it does
    /// not fill it.
    private let band = MediaEditorBandView()

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
    private lazy var saveDraftItem = UIBarButtonItem(
        title: "Save draft", style: .plain, target: nil, action: nil
    )

    init(
        items: [MediaLibraryItem],
        library: any MediaLibraryReading,
        onNext: @escaping ([MediaLibraryItem], [String: ContentFit], [String: MediaFilter]) -> UIViewController
    ) {
        self.items = items
        self.itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.library = library
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
        // A media canvas is black. The picture is the subject, and a light ground
        // around a portrait photo reads as a letterbox nobody asked for.
        view.backgroundColor = .black
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreToolbar?()
        restoreToolbar = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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

        // The canvas reports its own paging, so the bar glyph and the dots can
        // follow whichever picture the viewer has swiped to.
        canvas.delegate = self

        let cell = UICollectionView.CellRegistration<MediaEditorPageCell, String> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.prepare(for: item)
            // ⚠️ RE-STATED ON EVERY REGISTRATION, because a cell is recycled and
            // would otherwise arrive wearing the previous picture's choice.
            cell.setContentMode((fits[id] ?? .fill).mode, animated: false)
            let size = canvasSize
            // ⚠️ AND THE LOOK IS RE-APPLIED FOR THE SAME REASON, on the same
            // beat. A filtered page that scrolls off and comes back would
            // otherwise return undressed — the recycled cell knows nothing of
            // what was chosen for the picture it now carries.
            let look = filters[id] ?? .original
            Task { [weak cell] in
                let image = await self.library.thumbnail(for: id, size: size)
                let shown = image.flatMap { MediaFilterRenderer.apply(look, to: $0) } ?? image
                cell?.show(shown, for: id)
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
        navigationItem.leftBarButtonItems = [saveDraftItem]
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
        categoryBar.addAction(
            UIAction { [weak self] _ in self?.categoryChanged() }, for: .valueChanged
        )
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
    private func categoryChanged() {
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.categoryBar.setProgress(CGFloat(self.categoryBar.selectedIndex))
        }
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
        return Self.categories.indices.contains(index) ? Self.categories[index] : nil
    }

    private func showAccessory(for category: String?) {
        guard category == "Filters" else {
            setEditingAccessory(nil)
            return
        }
        setEditingAccessory(filterRow)
        refreshFilterRow()
    }

    /// Feeds the row the picture it is choosing a look for, and restores the
    /// look this item already carries.
    ///
    /// ⚠️ **ONE FETCH, NOT NINE.** The row filters locally from a single source;
    /// the library seam caches nothing, so nine thumbnail requests would be nine
    /// `PHImageManager` round trips for one photograph.
    private func refreshFilterRow() {
        guard let id = currentItemID else { return }
        filterRow.setSelected(filters[id] ?? .original)
        // ⚠️ THE THUMBNAIL'S SIDE, NOT THE ROW'S HEIGHT. The row is taller than
        // its pictures by a caption, and asking for that size would fetch a
        // picture bigger than anything shown.
        let side = MediaFilterRowView.thumbnailSide
        Task { [weak self] in
            guard let self else { return }
            let source = await self.library.thumbnail(for: id, size: CGSize(width: side, height: side))
            guard self.currentItemID == id else { return }
            self.filterRow.show(source)
        }
    }

    /// ⚠️ **SILENT WHEN THE BAND IS SHUT, AND THAT IS THE POINT.** Both settle
    /// hooks call this on every swipe; without the guard each one would run a
    /// full `PHImageManager` request — iCloud access allowed — to dress a row
    /// nobody is looking at.
    private func refreshFilterRowIfShowing() {
        guard band.content === filterRow else { return }
        refreshFilterRow()
    }

    /// Applies a look to the picture on screen.
    ///
    /// ⚠️ **A SECOND RENDER, AT CANVAS SIZE.** The thumbnail the look was chosen
    /// from is 56pt; pushing that onto the page would show a blurred picture. The
    /// canvas asks the library for its own size and filters that.
    private func applyFilter(_ filter: MediaFilter, to id: String) {
        filters[id] = filter
        let size = canvasSize
        Task { [weak self] in
            guard let self else { return }
            let source = await self.library.thumbnail(for: id, size: size)
            guard self.filters[id] == filter else { return }
            let shown = source.flatMap { MediaFilterRenderer.apply(filter, to: $0) } ?? source
            let page = self.canvas.cellForItem(at: IndexPath(item: self.currentIndex, section: 0))
            (page as? MediaEditorPageCell)?.show(shown, for: id)
        }
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
        currentItemID.flatMap { fits[$0] } ?? .fill
    }

    private func toggleFit() {
        guard let id = currentItemID else { return }
        let next = (fits[id] ?? .fill).toggled
        fits[id] = next
        let page = canvas.cellForItem(at: IndexPath(item: currentIndex, section: 0))
        (page as? MediaEditorPageCell)?.setContentMode(next.mode, animated: true)
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
        let fit = currentFit
        guard fit != shownFit else { return }
        shownFit = fit
        navigationItem.setRightBarButtonItems([nextItem, makeFitItem(for: fit)], animated: animated)
    }

    private func goNext() {
        navigationController?.pushViewController(onNext(items, fits, filters), animated: true)
    }

    // MARK: - The strip wins its own touches

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`. The
    /// picker skips this because it is the only screen in its stack; this screen
    /// is pushed, so a sideways drag on the strip is a drag the back-swipe wants
    /// for itself.
    private lazy var touchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.setStackGesturesEnabled(!isTouching)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.pin(to: contentView)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        picture.image = nil
    }

    func prepare(for item: MediaLibraryItem) {
        representedID = item.id
        accessibilityLabel = item.isVideo ? "Video" : "Photo"
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

    /// Internal for tests: whether a picture has actually landed.
    var debugHasPicture: Bool { picture.image != nil }
    /// Internal for tests: how the picture is currently laid in its page.
    var debugContentMode: UIView.ContentMode { picture.contentMode }
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
    }

    /// ⚠️ **BOTH SETTLE HOOKS, NOT JUST THE DRAGGED ONE.** A canvas that arrives
    /// by `scrollToItem` announces itself here instead, and handling only the
    /// dragged case would leave the row dressed in the previous picture while the
    /// canvas shows the next one.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateFitItem(animated: true)
        refreshFilterRowIfShowing()
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
        if let accessory {
            band.show(accessory)
        } else {
            band.clear()
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
    var debugFitActionName: String? {
        navigationItem.rightBarButtonItems?.last?.accessibilityLabel
    }
    /// Internal for tests: the fit chosen for an item, defaulting as the screen does.
    func debugFit(for id: String) -> ContentFit { fits[id] ?? .fill }
    /// Internal for tests: the path the fill/fit button takes, without a bar to tap.
    func debugTapFit() { toggleFit() }

    /// Internal for tests: the band itself, to measure where it put things.
    var debugBand: MediaEditorBandView { band }

    /// Internal for tests: the indicator, whose position is what the band moves.
    var debugPageDots: UIView { pageDots }

    /// Internal for tests: the categories the strip spells.
    var debugCategoryTitles: [String] { categoryBar.currentTitles }
    /// Internal for tests: whether the picture runs under the bars.
    var debugCanvasIgnoresInsets: Bool { canvas.contentInsetAdjustmentBehavior == .never }
    /// Internal for tests: the strip itself, to read what it is wearing.
    var debugCategoryBar: PagedTabBar { categoryBar }
    /// Internal for tests: the path "Next" takes, without a bar to tap.
    func debugTapNext() { goNext() }
}
#endif
