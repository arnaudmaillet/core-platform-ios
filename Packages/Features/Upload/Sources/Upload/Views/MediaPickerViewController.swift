import DesignSystem
import UIKit

/// The first step of posting media: the viewer's own library, and what they
/// have picked out of it — in a sheet that opens to the top and stays there.
///
/// ```
/// ┌──────────────────────┐
/// │ Cancel   Drafts Next │
/// ├──────────────────────┤
/// │ ▦ ▦ ▦    one album   │
/// │ ▦ ▦ ▦    per page,   │
/// │ ▦ ▦ ▦    swiped      │
/// │ ▦ ▦ ▦    sideways    │
/// │ ░ 1 2 3 ░░░░░░░░░░░░ │
/// ├──────────────────────┤
/// │ Recents 99+  Videos 8│
/// └──────────────────────┘
/// ```
///
/// **The albums are TABS, and the strip is their selector.** Each album is a
/// page of a `HorizontalPagerView`; the strip and the pages drive each other
/// through the container contract every other tabbed screen here follows — a tap
/// pages, a swipe moves the pill, and the pill itself can be dragged to scrub
/// the pages under it. See `configurePager`.
///
/// ⚠️ **THAT CONTRACT IS ALSO WHAT MAKES THE PILL MOVE AT ALL.** `PagedTabBar`
/// answers a tap by setting `selectedIndex` and announcing `.valueChanged`; the
/// pill is placed only by `setProgress`. Before the pages existed this screen had
/// nothing to drive that and stated the position by hand — a tap changed the
/// album under a pill that never moved. The pager now reports its own scroll and
/// the hand-written call is gone.
///
/// **One height, one axis.** The sheet has a single detent and each album is a
/// vertical three-column grid. This screen used to rest at one album row and turn
/// the grid sideways to suit, on a custom detent measured from the bars; that,
/// its resolver, the axis swap and the re-resolve guards are all gone.
///
/// **The count rides in the pill's BADGE**, in blue rather than the unread pill's
/// red — an album's count is how many photographs it holds, not how many things
/// are demanding an answer. `BadgeView` stops at "99+", so a large library's
/// exact size is not on screen; that ceiling is the shared component's.
///
/// ⚠️ **A BADGE DOES NOT SURVIVE `setTitles`.** Segments are rebuilt by a retitle
/// and a badge belongs to its segment, so `showAlbums` re-applies them every time.
final class MediaPickerViewController: UIViewController {
    private enum Metrics {
        /// Air between the album's last row and the strip of chosen thumbnails.
        /// Without it the two read as one block with a seam down the middle.
        static let trayGap = Spacing.lg
    }

    private let library: any MediaLibraryReading
    /// What "Next" hands the selection to.
    private let onNext: ([MediaLibraryItem]) -> UIViewController

    private var albums: [MediaLibraryAlbum] = []
    /// Every item this screen has seen, across every album it has opened —
    /// merged, never replaced, because a selection made in one album keeps its
    /// thumbnails in the tray after the viewer moves to another.
    private var itemsByID: [String: MediaLibraryItem] = [:]
    private var selection = MediaPickerSelection()

    /// One page per album, in `albums` order. Built when the albums land,
    /// because `HorizontalPagerView` takes its pages at construction.
    private var pages: [MediaAlbumPageView] = []
    private var pager: HorizontalPagerView?
    /// Which albums have been fetched. A page is filled when it is first
    /// settled on, so opening the picker reads one album rather than all of them.
    private var loadedAlbumIDs: Set<String> = []
    /// The sheet has finished presenting. Until it has, a page has no on-screen
    /// rectangle to animate into, so the album's reveal waits for it.
    private var hasAppeared = false

    /// Shown from the moment the screen opens until the library has answered —
    /// including while the system is asking the viewer for permission.
    private let spinner = UIActivityIndicatorView(style: .large)
    /// Built once the albums are known: a strip with no segments has nothing to
    /// lay out, and the toolbar stays down until there is something to show.
    private var albumBar: PagedTabBar?
    /// The screen's own empty state — no access, or no albums at all. An album
    /// that is merely empty says so on its own page.
    private let emptyState = EmptyStateView()

    /// The band that takes the album's definition away as it passes under the
    /// strip — see `configureTray` for why it replaced a mask on the grid.
    private let trayBlur = ProgressiveBlurView()

    /// Says the library is only partly shared, ABOVE the grid rather than instead
    /// of it.
    ///
    /// ⚠️ **ONLY FOR `.limited`.** `.denied` and `.undetermined` are the empty
    /// state's business — `load()` already turns them into a full "No access to
    /// your photos" screen with its own Settings button, and a banner as well
    /// would say the same thing twice. `.granted` hides it outright.
    private let accessNotice = MediaAccessNoticeView()

    private lazy var tray = SelectedMediaTrayView { [weak self] id, size in
        guard let self else { return nil }
        return await library.thumbnail(for: id, size: size)
    }

    /// The tray rides on this: `0` has it sitting on the toolbar, its own height
    /// has it parked below the screen.
    private var trayBottom: NSLayoutConstraint!

    private lazy var nextItem = UIBarButtonItem(
        title: "Next",
        primaryAction: UIAction { [weak self] _ in self?.goNext() }
    )

    init(
        library: any MediaLibraryReading,
        onNext: @escaping ([MediaLibraryItem]) -> UIViewController
    ) {
        self.library = library
        self.onNext = onNext
        super.init(nibName: nil, bundle: nil)
        // ⚠️ THE BARS BELONG TO THE SCREEN, NOT TO ITS VIEW. Built in
        // `viewDidLoad` they exist only once something has asked for the view,
        // and a navigation controller reads `navigationItem` on the way in —
        // so a screen that has been made but not yet shown would hand back a
        // bar with nothing in it.
        configureBars()
        updateNextItem()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureTray()
        emptyState.isHidden = true
        emptyState.pin(to: view)

        // ⚠️ **THE WAIT IS NOT ALWAYS SHORT, AND IT IS NOT ALWAYS OURS.**
        // Reading the library takes a moment on a full device, and when the
        // system's own permission sheet is up this screen sits behind it —
        // blank, with nothing to say it is about to do anything. Centred in the
        // SAFE area, not the view: the album is full-bleed behind its bars, so
        // the view's middle is not the middle of what the viewer can see.
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerYAnchor)
        }

        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The album strip lives in the navigation controller's toolbar, and a
        // toolbar's VISIBILITY belongs to the stack rather than to the screen's
        // `toolbarItems` — so the screen raises it itself, exactly as the
        // relationship lists do. It stays down until there is a strip to carry.
        navigationController?.setToolbarHidden(albumBar == nil, animated: animated)
    }

    /// ⚠️ **THE ALBUM'S REVEAL BELONGS HERE, NOT TO THE GRID.** `viewDidAppear`
    /// is the first moment a page has a rectangle on screen: the album loads
    /// while the sheet is still travelling, and a spring committed then is
    /// committed instantly. The two can finish in either order, so whichever is
    /// last plays it — this, or `loadAlbum` — and `playReveal()` is a no-op for
    /// whichever was first.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        revealActivePage()
        #if DEBUG
        // ⚠️ **A PROBE, BECAUSE FOUR HYPOTHESES ARE ALREADY DEAD.** Returning
        // from the editor leaves the album pills WHITE on a light bar and the
        // badges desaturated — two different visual properties degrading
        // together, which points at one shared input. Ruled out by reading:
        // partial appearance restore (all three slots are captured and put
        // back), colours resolved once (they are `.label`/`.secondaryLabel`,
        // live), any interface-style override in Upload (there is none), and
        // Feed's toolbar override (this sheet builds its OWN nav controller).
        // So measure the state instead of theorising a fifth time: a
        // transparent background that never came back, a dark resolved trait,
        // and a wrong tint are three different fixes.
        logBarState("didAppear")
        logBubbleMetrics()
        #endif
    }

    #if DEBUG
    /// ⚠️ **ASK UIKIT, DO NOT MEASURE PIXELS.** Matching the notice to the bar's
    /// bubbles needs two numbers UIKit owns and the repo never writes down — bar
    /// items are system-laid-out. Four attempts to read them off a screenshot all
    /// failed for the same structural reason: a white pill on a white sheet has
    /// no usable contrast, and the notice is translucent glass over coloured
    /// tiles. The last run returned a height that moved between 37.7pt and 28.0pt
    /// depending on the threshold — a number that depends on the threshold is not
    /// a measurement. The view hierarchy answers exactly.
    private func logBubbleMetrics() {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet"),
              let bar = navigationController?.navigationBar
        else { return }
        // ⚠️ **THE LAYOUT PASS BELONGS INSIDE THE GUARD, NOT BEFORE IT.** These
        // two lines first sat in `viewDidAppear`, which forced two layout passes
        // on every appearance of this screen in every DEBUG build — a permanent
        // cost for an occasional instrument. They cannot simply be dropped
        // either: without them the frames below read zero, and a probe that
        // reports zero is indistinguishable from a probe that never ran.
        view.layoutIfNeeded()
        bar.layoutIfNeeded()

        // ⚠️ **THE FIRST CUT FOUND THE LABEL'S WRAPPER, NOT THE CAPSULE.** It
        // took "the view whose child is a label" and reported `leading=0
        // trailing=0` — a label filling its parent edge to edge, which is
        // precisely what a bubble is NOT. The plausibility guard passed anyway,
        // because a wrong number can sit comfortably inside a plausible range.
        // So do not guess which ancestor is the capsule: print the chain and let
        // the one that is genuinely larger than its label identify itself.
        func walk(_ view: UIView) {
            for child in view.subviews {
                if let label = child as? UILabel, let text = label.text, !text.isEmpty {
                    var chain: [String] = []
                    var node: UIView? = label
                    var depth = 0
                    while let current = node, current !== bar, depth < 5 {
                        let kind = String(describing: type(of: current))
                        chain.append(String(
                            format: "%@ %.1fx%.1f", kind, current.bounds.width, current.bounds.height
                        ))
                        node = current.superview
                        depth += 1
                    }
                    write("[bubble] bar \"\(text)\" chain: " + chain.joined(separator: " < "))
                }
                walk(child)
            }
        }
        walk(bar)

        // The notice, measured the same way: its own box, and where its label
        // sits inside it. Comparing heights without comparing the padding would
        // answer half the question.
        let pill = accessNotice.bounds
        let inner = accessNotice.debugLabelFrame
        write(
            "[bubble] notice box=\(pill.width)x\(pill.height)"
            + " label=\(inner.minX),\(inner.minY) \(inner.width)x\(inner.height)"
            + " leading=\(inner.minX) top=\(inner.minY)"
            + " bottom=\(pill.height - inner.maxY) hidden=\(accessNotice.isHidden)"
        )
    }

    private func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func logBarState(_ when: String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet"),
              let bar = navigationController?.toolbar
        else { return }
        let standard = bar.standardAppearance
        let line = "[bars] \(when)"
            + " forced=\(bar.overrideUserInterfaceStyle.rawValue)"
            + " resolved=\(bar.traitCollection.userInterfaceStyle.rawValue)"
            + " albumBarResolved=\(albumBar?.traitCollection.userInterfaceStyle.rawValue ?? -1)"
            + " tint=\(bar.tintColor.map { "\($0)" } ?? "nil")"
            + " bgEffect=\(standard.backgroundEffect.map { "\($0)" } ?? "nil")"
            + " bgColor=\(standard.backgroundColor.map { "\($0)" } ?? "nil")"
            + " barStyle=\(bar.barStyle.rawValue)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    #endif

    /// Plays the pending reveal on whichever page the viewer is looking at.
    private func revealActivePage() {
        guard let index = pager?.activeIndex else { return }
        revealPage(at: index)
    }

    /// Plays the pending arrival on one page, if it owes one and the screen is
    /// up. Safe to call every frame of a drag: `playReveal()` spends the debt
    /// once and is a no-op thereafter.
    private func revealPage(at index: Int) {
        guard hasAppeared, pages.indices.contains(index) else { return }
        pages[index].playReveal()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateTrayReserve()
        // The notice's own height is not fixed — its line wraps at larger text
        // sizes — so the room it claims is recomputed on the same beat as the
        // tray's rather than measured once and trusted.
        updateNoticeReserve()
    }

    // MARK: - Bars

    private func configureBars() {
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                title: "Cancel",
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        ]
        // The chevron the EDITOR wears. This screen has no title to lend it, so
        // it already draws bare — `.minimal` keeps it that way if one is ever
        // added. Nothing here affects this screen's own leading group: the picker
        // is the stack's root and shows no back button at all.
        navigationItem.backButtonDisplayMode = .minimal
        // Right-to-left: the first item is the RIGHTMOST, so "Next" sits at the
        // edge and "Drafts" beside it, which is the order the layout asks for.
        navigationItem.rightBarButtonItems = [
            nextItem,
            UIBarButtonItem(
                title: "Drafts",
                primaryAction: UIAction { [weak self] _ in self?.openDrafts() }
            )
        ]
        nextItem.style = .done
    }

    /// "Next" alone says nothing about what is going; "Next (3)" says what the
    /// step after this one will be handed.
    private func updateNextItem() {
        nextItem.title = selection.isEmpty ? "Next" : "Next (\(selection.count))"
        nextItem.isEnabled = !selection.isEmpty
    }

    private func openDrafts() {
        navigationController?.pushViewController(MediaDraftsViewController(), animated: true)
    }

    private func goNext() {
        let chosen = selection.ids.compactMap { itemsByID[$0] }
        guard !chosen.isEmpty else { return }
        navigationController?.pushViewController(onNext(chosen), animated: true)
    }

    // MARK: - The albums, as tabs

    /// The album strip, at the foot of the screen, and the pages it selects.
    ///
    /// No `SelectorTouchProbe` here, and that is not an oversight: the probe
    /// suspends a stack's back-swipe while a finger is on the strip, and this
    /// screen is the only one in its stack.
    private func showAlbums(_ albums: [MediaLibraryAlbum]) {
        self.albums = albums
        guard !albums.isEmpty else { return }
        let bar = albumBar ?? PagedTabBar(titles: albums.map(\.title), style: .navigationTitle)
        if albumBar == nil {
            // ⚠️ **THE TOOLBAR ALREADY SUPPLIES A CAPSULE.** iOS composites every
            // bar item through its own neutral glass, so a strip that also
            // carries its backdrop renders as a bubble inside a bubble — which
            // is exactly what shipped in the first cut of this screen. The
            // search results screen sets this for the same reason.
            bar.suppressesBackdrop = true
            // ⚠️ NOT NOTIFICATION RED. The default is the unread pill's colour,
            // which is right for the two hosts it was written for and wrong
            // here: an album's count is how many photographs are in it, not how
            // many things are demanding an answer. A library is not an alarm.
            bar.badgeTint = .systemBlue
            albumBar = bar
            toolbarItems = [UIBarButtonItem(customView: bar), .flexibleSpace()]
            navigationController?.setToolbarHidden(false, animated: true)
            configurePager(for: albums, bar: bar)
        } else {
            bar.setTitles(albums.map(\.title))
        }
        // ⚠️ AFTER THE TITLES, ALWAYS, AND ON BOTH PATHS. A badge belongs to the
        // segment that carries it and `setTitles` rebuilds the segments, so a
        // count stamped before a retitle leaves with the segment that held it.
        for (index, album) in albums.enumerated() {
            bar.setBadge(album.count, at: index)
        }
    }

    /// The container contract, the same one the relationship lists and the inbox
    /// follow: four wires, and between them the strip and the pages can never
    /// disagree about which album is on screen.
    ///
    /// 1. tap on a segment → page, animated, so the pill rides the same progress
    ///    stream a finger would produce rather than jumping;
    /// 2. drag ON the pill → `scrub`, every frame of the finger, and the release
    ///    hands the pager a velocity so it lands itself;
    /// 3. swipe on the pages → fractional progress → the pill follows;
    /// 4. a settled page → that album is fetched, if it never has been.
    ///
    /// ⚠️ **THE PAGER IS BUILT HERE AND NOT IN `viewDidLoad`.**
    /// `HorizontalPagerView` takes its pages at construction and the albums are
    /// read asynchronously, so there is nothing to build until they land. It goes
    /// in at index 0 so the tray, the empty state and the spinner stay above it.
    private func configurePager(for albums: [MediaLibraryAlbum], bar: PagedTabBar) {
        pages = albums.map { _ in makePage() }
        // The album runs up to Cancel / Drafts / Next with nothing drawn between
        // them — the same bare header as every other screen. (It never had a
        // fade here on either system; asked for `.soft`, iOS 27 laid a heavy
        // blur over the top rows, which is why this pager once opted out of the
        // style. Hidden, there is nothing to opt out of.)
        let pager = HorizontalPagerView(pages: pages, initialIndex: 0)
        self.pager = pager
        // ⚠️ **`pin(to:)` WOULD UNDO THE LINE ABOVE IT.** That helper calls
        // `parent.addSubview(self)` unconditionally, and `addSubview` MOVES a
        // view that is already in the hierarchy to the TOP of its siblings — so
        // inserting the pager at 0 and then pinning it put the album back over
        // the chosen-media strip, its blur and the spinner, and the strip stopped
        // being drawn at all.
        //
        // Measured rather than reasoned: the strip reported `idx=1`, which is
        // only possible if the pager had been re-parented above it — at index 0
        // it would have been 2. Explicit constraints keep the pager where it was
        // put.
        view.insertSubview(pager, at: 0)
        pager.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // ⚠️ **ABOVE THE PAGER, BELOW THE TRAY — AND NOT WITH `pin(to:)`.** That
        // helper calls `addSubview` unconditionally, which MOVES a view to the
        // top of its siblings; doing it to the pager once put the album over the
        // chosen-media strip and stopped the strip drawing at all. Anchoring
        // above the pager by name keeps the tray, its blur, the spinner and the
        // empty state where they were put.
        view.insertSubview(accessNotice, aboveSubview: pager)
        accessNotice.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // ⚠️ **THE BAR'S MARGIN, INHERITED RATHER THAN COPIED.** This used to
            // be the safe area plus `Spacing.sm` (8pt), which is not what the
            // navigation bar uses for its own items — so the banner sat a few
            // points inboard of "Cancel" and the two edges disagreed. Anchoring
            // to `layoutMarginsGuide` takes the same margin the bar takes, so it
            // cannot drift out of step with a number written in two places.
            // `ToastView` and `SectionHeaderPillButton` align this way already.
            accessNotice.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            accessNotice.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            accessNotice.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm
            )
        ])
        accessNotice.onSelectMore = { [weak self] in
            guard let self else { return }
            library.presentLimitedPicker(from: self)
        }
        accessNotice.onOpenSettings = {
            guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settings)
        }
        // ⚠️ **ACCESS IS READ ONCE AND BOTH WAYS OUT LEAVE THE APP.** `load()`
        // consults the library exactly once, so a viewer who widens their
        // permission and comes back would be met by a banner still claiming they
        // had shared only some photos. Registered here because this runs once.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessMayHaveChanged),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        refreshAccessNotice()

        bar.addAction(
            UIAction { [weak self] _ in self?.albumChanged() }, for: .valueChanged
        )
        bar.onScrub = { [weak self] progress in self?.pager?.scrub(to: progress) }
        bar.onScrubEnd = { [weak self] velocity in
            self?.pager?.settleAfterScrub(velocityInPages: velocity)
        }
        pager.onProgress = { [weak self] progress in
            guard let self else { return }
            albumBar?.setProgress(progress)
            // ⚠️ **THE PAGE BEING SWIPED TO IS WOKEN MID-DRAG, NOT AT SETTLE.**
            // A page that owes an arrival is HIDDEN until it plays, so waiting
            // for `onSettled` would drag a blank rectangle across the screen and
            // only fill it once the finger let go. `onProgress` fires every
            // frame with a fractional page, so the neighbour is revealed as soon
            // as it is genuinely coming.
            revealPage(at: Int(progress.rounded()))
        }
        pager.onSettled = { [weak self] index in
            guard let self, albums.indices.contains(index) else { return }
            Task {
                await self.loadAlbum(at: index)
                // An album filled while it was a page away still owes its
                // reveal until the viewer has actually been brought to it.
                self.revealActivePage()
            }
        }
        updateTrayReserve()
    }

    private func makePage() -> MediaAlbumPageView {
        let page = MediaAlbumPageView()
        page.tile = { [weak self] id in
            guard let self, let item = itemsByID[id] else { return nil }
            return MediaAlbumPageView.Tile(
                item: item, order: selection.order(of: id), isSelectable: canChoose(id)
            )
        }
        page.onTap = { [weak self] id in self?.toggle(id) }
        page.thumbnail = { [weak self] id, size in
            guard let self else { return nil }
            return await library.thumbnail(for: id, size: size)
        }
        page.onPrefetch = { [weak self] ids, size in self?.library.startCaching(ids, size: size) }
        page.onCancelPrefetch = { [weak self] ids, size in self?.library.stopCaching(ids, size: size) }
        return page
    }

    /// A segment was chosen. The page is what moves; the pill follows it back
    /// through `onProgress`, which is why nothing here touches the bar.
    private func albumChanged() {
        guard let bar = albumBar, albums.indices.contains(bar.selectedIndex) else { return }
        pager?.setActivePage(bar.selectedIndex, animated: true)
    }
}

// MARK: - The library

private extension MediaPickerViewController {
    func load() async {
        var access = library.access
        if access == .undetermined {
            access = await library.requestAccess()
        }
        guard access == .granted || access == .limited else {
            showEmptyState(
                symbolName: "lock.fill",
                title: "No access to your photos",
                subtitle: "Allow photo access in Settings to pick something to post.",
                actionTitle: "Open Settings"
            ) {
                guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settings)
            }
            return
        }

        let albums = await library.albums()
        guard !albums.isEmpty else {
            showEmptyState(
                symbolName: "photo.on.rectangle.angled",
                title: "Nothing to post yet",
                subtitle: "Photos and videos you take will show up here."
            )
            return
        }
        showAlbums(albums)
        await loadAlbum(at: 0)
        #if DEBUG
        runDebugHooks()
        #endif
    }

    /// Fills one page, once. Every album after the first arrives this way, from
    /// the pager settling on it.
    func loadAlbum(at index: Int) async {
        guard albums.indices.contains(index), pages.indices.contains(index) else { return }
        let album = albums[index]
        guard !loadedAlbumIDs.contains(album.id) else { return }
        loadedAlbumIDs.insert(album.id)

        let loaded = await library.items(in: album.id)
        // ⚠️ AND THE PAGES COME BACK. `showEmptyState` hides them, and an earlier
        // refusal followed by a grant would otherwise leave the album loaded,
        // correct, and invisible.
        pager?.isHidden = false
        spinner.stopAnimating()
        // Merged, never replaced — the tray and the step after this one are both
        // handed items the visible album may no longer be showing.
        for item in loaded { itemsByID[item.id] = item }
        pages[index].setItems(loaded, albumID: album.id)
        updateTrayReserve()
        // The album can land after the sheet has settled, in which case nothing
        // else is coming along to play its reveal.
        revealActivePage()
    }

    func showEmptyState(
        symbolName: String,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        emptyState.configure(
            symbolName: symbolName,
            title: title,
            subtitle: subtitle,
            actionTitle: actionTitle,
            actionHandler: action
        )
        emptyState.isHidden = false
        pager?.isHidden = true
        spinner.stopAnimating()
    }
}

// MARK: - The selection

private extension MediaPickerViewController {
    /// An unchosen tile stops offering itself once the cap is reached; a chosen
    /// one can always be given back.
    func canChoose(_ id: String) -> Bool {
        selection.order(of: id) != nil || !selection.isFull
    }

    func configureTray() {
        tray.onRemove = { [weak self] id in self?.drop(id) }
        tray.onReorder = { [weak self] order in self?.reorder(order) }

        // ⚠️ **NO PLATE BEHIND THE STRIP — A PROGRESSIVE BLUR INSTEAD.** An
        // opaque backdrop was tried here once and rejected: the album has to be
        // SEEN through the strip's band. It used to lose opacity on its way
        // under, by a mask on each page's own grid; since 2026-09-12 the album
        // runs on at full strength to the foot of the screen and this blur is
        // what takes its definition away — clear where it begins, full material
        // at the bottom.
        //
        // ⚠️ **HUNG FROM THE STRIP'S TOP EDGE, AND NEVER HIDDEN.** It travels
        // with the strip, so parking the strip below the screen shortens the
        // band by exactly the strip's height and leaves the toolbar's own band
        // blurred — which is the behaviour asked for, and it animates for free
        // because the strip's constraint already moves inside `settle`'s
        // animation. An earlier cut set `isHidden` instead and took the whole
        // band away with it; height is the dial here, not visibility.
        //
        // It goes in BEFORE the tray, so the thumbnails sit on top of it.
        trayBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(trayBlur)
        tray.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tray)
        NSLayoutConstraint.activate([
            trayBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trayBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trayBlur.topAnchor.constraint(equalTo: tray.topAnchor),
            trayBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        trayBottom = tray.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: SelectedMediaTrayView.height
        )
        NSLayoutConstraint.activate([
            tray.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tray.heightAnchor.constraint(equalToConstant: SelectedMediaTrayView.height),
            trayBottom
        ])
    }

    /// The room the tray takes, told to every page — a page the viewer has not
    /// reached yet must already know, or its first row sits under the strip for
    /// one frame after they swipe to it.
    func updateTrayReserve() {
        let reserved = selection.isEmpty ? 0 : SelectedMediaTrayView.height + Metrics.trayGap
        for page in pages { page.setTrayReserve(reserved) }
    }

    /// Shows the notice only for `.limited`, and gives every page the room it
    /// takes.
    ///
    /// ⚠️ **`.denied` IS NOT THIS VIEW'S BUSINESS.** `load()` already turns a
    /// refusal into a full empty state carrying its own Settings button; a banner
    /// as well would say the same thing twice, in two visual languages, on one
    /// screen.
    func refreshAccessNotice() {
        accessNotice.isHidden = library.access != .limited
        updateNoticeReserve()
    }

    /// The room the notice takes at the top, told to every page — the same
    /// contract `updateTrayReserve` keeps at the bottom, and for the same reason:
    /// a page the viewer has not swiped to yet must already know, or its first
    /// row sits under the banner for a frame once they arrive.
    func updateNoticeReserve() {
        let reserved: CGFloat
        if accessNotice.isHidden {
            reserved = 0
        } else {
            // ⚠️ MEASURED, NOT READ FROM `bounds`. This runs from
            // `configurePager`, before the notice has ever been laid out, so
            // `bounds.height` would be 0 and the first album would open with its
            // top row under the banner.
            let width = view.bounds.width - Spacing.sm * 2
            reserved = accessNotice.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height + Metrics.trayGap
        }
        for page in pages { page.setNoticeReserve(reserved) }
    }

    /// ⚠️ **THE BANNER IS REFRESHED, THE LIBRARY IS NOT — AND THAT IS A REAL
    /// GAP, NOT AN OVERSIGHT I AM HIDING.** Both ways out of the notice leave the
    /// app, so coming back is exactly when the permission may have widened. This
    /// re-reads the access and hides the banner accordingly, but `loadedAlbumIDs`
    /// still blocks any album from being fetched a second time, so newly shared
    /// photos will not appear until the sheet is reopened. Fixing that means
    /// invalidating those ids and re-running `load()`, which is a larger change
    /// than this notice.
    @objc private func accessMayHaveChanged() {
        refreshAccessNotice()
    }

    func toggle(_ id: String) {
        let wasFull = selection.isFull
        switch selection.toggle(id) {
        case .refused:
            refuse()
        case .added, .removed:
            settle(changed: id, capChanged: wasFull != selection.isFull, animated: true)
        }
    }

    func drop(_ id: String) {
        let wasFull = selection.isFull
        selection.remove(id)
        settle(changed: id, capChanged: wasFull != selection.isFull, animated: true)
    }

    /// ⚠️ **NOTHING IS APPLIED FROM INSIDE THIS CALL, AND THE APP DIED LEARNING
    /// IT.** This arrives from the tray data source's own `didReorder`, which
    /// runs UNDERNEATH the snapshot apply that performed the move. Answering it
    /// by re-applying a snapshot — which `settle` did, through
    /// `tray.setItems` — is `NSInternalInconsistencyException`: "attempted to
    /// apply a snapshot to diffable data source while it was already applying a
    /// snapshot". The work is handed to the next turn of the run loop instead.
    ///
    /// On the accepted path the tray is deliberately NOT told: it already shows
    /// this order, being the thing that moved. Only the grids' numbers, which
    /// belong to different data sources, have to catch up.
    func reorder(_ order: [String]) {
        let accepted = selection.setOrder(order)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if accepted {
                refreshTiles(changed: nil, capChanged: false, animated: false)
            } else {
                // A report that is not a permutation of what is held is
                // refused, and the tray is put back to what the model says.
                tray.setItems(selection.ids, animated: false)
            }
        }
    }

    /// Everything a change to the selection touches, in one place: the strip,
    /// the numbers on the tiles, the room the pages give up, and the word on the
    /// button that carries it all forward.
    func settle(changed: String?, capChanged: Bool, animated: Bool) {
        let hadTray = trayBottom.constant == 0
        tray.setItems(selection.ids, animated: animated)
        updateNextItem()
        updateTrayReserve()
        refreshTiles(changed: changed, capChanged: capChanged, animated: animated)

        let wantsTray = !selection.isEmpty
        guard wantsTray != hadTray else {
            if wantsTray, animated { tray.scrollToEnd() }
            return
        }
        trayBottom.constant = wantsTray ? 0 : SelectedMediaTrayView.height
        let settleLayout = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
                settleLayout()
            }
        } else {
            settleLayout()
        }
        #if DEBUG
        logTray("settle")
        #endif
    }

    /// ⚠️ **EVERY PAGE, NOT JUST THE ONE ON SCREEN.** The same photograph can
    /// appear in Recents and in Favourites, and a number that was only corrected
    /// on the visible page would be wrong the moment the viewer swiped. The
    /// tapped tile is updated in place — a reconfigure cannot animate the tile a
    /// finger is on — and the rest follow through each page's snapshot.
    func refreshTiles(changed: String?, capChanged: Bool, animated: Bool) {
        for page in pages {
            if let changed { page.updateTile(changed, animated: animated) }
            let present = Set(page.items.map(\.id))
            // The cap crossing is the one case where every unchosen tile
            // changes, because they all stop — or start — offering themselves.
            var stale = capChanged ? present : Set(selection.ids).intersection(present)
            if let changed { stale.remove(changed) }
            page.reconfigure(Array(stale))
        }
    }

    /// The cap, said once and briefly. A selection that cannot grow is not an
    /// error the viewer made.
    func refuse() {
        let alert = UIAlertController(
            title: "That's the limit",
            message: "You can post up to \(MediaPickerSelection.limit) photos and videos at a time.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Debug

#if DEBUG
extension MediaPickerViewController {
    /// Internal for tests: what the screen currently holds, in order.
    var debugSelection: [String] { selection.ids }
    /// Internal for tests: the pills as the strip spells them.
    var debugAlbumTitles: [String] { albumBar?.currentTitles ?? [] }
    /// Internal for tests: whether the tray is up.
    var debugTrayIsShowing: Bool { trayBottom?.constant == 0 }
    /// Internal for tests: whether the limited-access banner is up. The screen
    /// offers no other way to ask, and "is it conditional" cannot be answered by
    /// a test that can only see it in one state.
    var debugAccessNoticeIsHidden: Bool { accessNotice.isHidden }
    /// Internal for tests: the room the banner claims from each page, so the
    /// reserve can be checked without measuring pixels.
    var debugNoticeReserve: CGFloat { pages.first?.debugNoticeReserve ?? 0 }
    /// Internal for tests: the items the album ON SCREEN is showing.
    var debugItems: [MediaLibraryItem] { debugActivePage?.items ?? [] }
    /// Internal for tests: whether the screen is still saying it is working.
    var debugIsLoading: Bool { spinner.isAnimating }
    /// Internal for tests: the pager, so a test can assert the strip and the
    /// pages stay in step — which is the whole contract of this screen's chrome.
    var debugPager: HorizontalPagerView? { pager }
    /// Internal for tests: one page per album.
    var debugPageCount: Int { pages.count }
    /// Where the strip and its blur actually ARE, behind `-upload-log-sheet`.
    ///
    /// ⚠️ MEASURED, NOT DEDUCED. The strip stopped drawing when the blur arrived,
    /// and three readings of the source each cleared a suspect without finding
    /// the cause: `settle` still raises it, the blur goes in BELOW it, and its
    /// height is a sane 80pt. `theTrayStaysDownUntilSomethingIsChosen` passes in
    /// a hosted window, so the model is right and it is the live hierarchy that
    /// differs — which source cannot answer and a frame can.
    ///
    /// ⚠️ `NSLog`, NOT `print`: stdout is discarded by `simctl launch` unless it
    /// is handed a pty, and killing that pty takes the app with it.
    func logTray(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") else { return }
        view.layoutIfNeeded()
        NSLog(
            "[tray] %@ frame=%@ hidden=%@ alpha=%.2f super=%@ idx=%@ blur=%@ blurHidden=%@ safeBottom=%.1f",
            moment,
            "\(tray.frame)",
            tray.isHidden ? "yes" : "no",
            tray.alpha,
            tray.superview.map { String(describing: type(of: $0)) } ?? "nil",
            "\(tray.superview?.subviews.firstIndex(of: tray) ?? -1)",
            "\(trayBlur.frame)",
            trayBlur.isHidden ? "yes" : "no",
            view.safeAreaInsets.bottom
        )
    }

    /// Internal for tests: the one gap that is both margin and gutter.
    static var debugGutter: CGFloat { MediaAlbumPageView.gutter }

    /// Internal for tests: the tile a page would cut at this width.
    static func debugTileSide(forWidth width: CGFloat) -> CGFloat {
        MediaAlbumPageView.tileSide(forWidth: width)
    }

    private var debugActivePage: MediaAlbumPageView? {
        guard let index = pager?.activeIndex, pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    /// Internal for tests: the path a tap takes, without a window to hit-test in.
    func debugTapItem(at index: Int) {
        guard let items = debugActivePage?.items, items.indices.contains(index) else { return }
        toggle(items[index].id)
    }

    /// Internal for tests: what a finished drag reports.
    func debugReorder(_ order: [String]) {
        reorder(order)
    }

    /// `-upload-album <index>` opens on that album, `-upload-pick 0,2,5` chooses
    /// those tiles, and `-upload-edit` goes straight on to the editor — the
    /// simulator cannot tap a grid or press a bar item, and a screenshot of an
    /// empty selection shows neither the numbering nor the tray.
    func runDebugHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = Self.debugArgument("-upload-album", in: arguments),
           let index = Int(raw), albums.indices.contains(index) {
            albumBar?.select(index)
            pager?.setActivePage(index, animated: false)
            Task { await loadAlbum(at: index) }
        }
        if let picks = Self.debugArgument("-upload-pick", in: arguments) {
            for index in picks.split(separator: ",").compactMap({ Int($0) }) {
                debugTapItem(at: index)
            }
        }
        // Last, so it carries the picks made above with it. Without this the
        // editor is unreachable on a simulator: the grid cannot be tapped and
        // neither can "Next".
        if arguments.contains("-upload-edit") { goNext() }
        // ⚠️ **A ROUND TRIP, NOT A COORDINATE TAP.** The bar-state probe fires on
        // the picker's `viewDidAppear`, so the defect only shows after going to
        // the editor AND COMING BACK — and this has to be replayable identically
        // before and after a fix. A tap on the chevron is not an instrument: it
        // has already, on this branch, hit the wrong simulator once and landed a
        // zero-distance gesture on the navigation bar another time.
        if arguments.contains("-upload-edit-return") {
            goNext()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }
        }
        if arguments.contains("-upload-bench-slides") { runSlideBench() }
        if arguments.contains("-upload-bench-drag") { runDragBench() }
    }

    private static func debugArgument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    /// ⚠️ **A BENCH, NOT A DEMO.** Walks every album once at a fixed cadence —
    /// which is what the viewer does sliding across the strip, and the case
    /// reported as costly — and stamps the window on stderr so the host can
    /// bracket its sampling on the app's own clock.
    ///
    /// ⚠️ **ONE LAP, AND THE STAGING RULE IS WHY.** The arrival is armed once per
    /// album (`stagedAlbums`) and `setItems` only re-arms when a page goes from
    /// empty to filled, so a second lap would animate NOTHING and quietly halve
    /// whatever the run appeared to measure. One visit per album is also exactly
    /// what a real session does.
    ///
    /// Paired with `-upload-no-reveal`, the identical walk runs without the
    /// animation: the difference between the two is the animation's share, which
    /// is the number worth having before optimising anything.
    private func runSlideBench() {
        let count = albums.count
        let step: TimeInterval = 0.9
        // ⚠️ **FRAME TIMES, NOT CUMULATIVE CPU — THE FIRST INSTRUMENT WAS BLIND.**
        // Measuring app CPU and render-server CPU across this same walk found
        // nothing: medians of 1.82s with the animation against 2.04s without,
        // inside a run-to-run spread of 1.41-2.84s, and 0.35s of render server
        // either way. That cannot see this cost — group opacity, path-less
        // shadows and squircle masks are GPU work, and on a simulator that lands
        // on the Mac's GPU, where neither counter looks. A long frame is a long
        // frame whichever unit produced it.
        BenchFrameTimer.shared.start()
        benchStamp("start albums=\(count) step=\(step)")
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) { [weak self] in
                guard let self else { return }
                albumBar?.select(index)
                pager?.setActivePage(index, animated: true)
                Task { await self.loadAlbum(at: index) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(count) + 0.8) { [weak self] in
            self?.benchStamp("done " + BenchFrameTimer.shared.stop())
        }
    }

    /// ⚠️ **THE FINGER'S PATH, NOT THE PROGRAMMATIC ONE — AND THAT DIFFERENCE IS
    /// THE WHOLE POINT.** `-upload-bench-slides` turns pages with
    /// `setActivePage`, which never drives `onProgress`. A drag does, every
    /// frame, and `onProgress` calls `revealPage` → `playReveal()` — so the one
    /// code path the viewer described as costly is INVISIBLE to that bench,
    /// which is a fair reading of why two instruments came back null.
    ///
    /// This scrubs across each boundary in 1/60 steps and then lets go, which is
    /// what a thumb does. Same `[bench] start`/`done` markers, so the host
    /// harness reads it unchanged.
    private func runDragBench() {
        let count = albums.count
        guard count > 1 else { benchStamp("done VOID-one-album"); return }
        let perPage: TimeInterval = 0.35
        let steps = 21
        let settle: TimeInterval = 0.55
        BenchFrameTimer.shared.start()
        benchStamp("start drag albums=\(count) perPage=\(perPage)")

        var clock: TimeInterval = 0
        for page in 0..<(count - 1) {
            let base = clock
            for step in 0...steps {
                let progress = CGFloat(page) + CGFloat(step) / CGFloat(steps)
                let at = base + perPage * Double(step) / Double(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    self?.pager?.scrub(to: progress)
                }
            }
            clock = base + perPage
            DispatchQueue.main.asyncAfter(deadline: .now() + clock) { [weak self] in
                self?.pager?.settleAfterScrub(velocityInPages: 0)
            }
            clock += settle
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + clock + 0.6) { [weak self] in
            self?.benchStamp("done " + BenchFrameTimer.shared.stop())
        }
    }

    /// stderr, unbuffered. stdout is BLOCK-buffered into a file sink in an app
    /// that never exits, so a `print` here would sit in a 4KB buffer and the run
    /// would read as a silent harness — which has already cost this branch two
    /// filmed takes.
    private func benchStamp(_ what: String) {
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[bench] t=\(stamp) \(what)\n".utf8))
    }
}

/// Per-frame intervals across a benched window.
///
/// ⚠️ **THIS EXISTS BECAUSE CUMULATIVE CPU MEASURED NOTHING.** App CPU and
/// render-server CPU over the identical album walk came back 1.82s with the
/// arrival animation against 2.04s without — the animated run LOWER — inside a
/// run-to-run spread of 1.41-2.84s. The effect under investigation is GPU work
/// (group opacity forcing an offscreen composite, path-less shadows, squircle
/// masks), and on a simulator that lands on the Mac's GPU where those counters
/// do not look. Frame duration is agnostic: a long frame is a long frame
/// whichever unit produced it.
///
/// `NSObject` because `#selector` requires it; `@MainActor` because a
/// `static let shared` of a non-Sendable class is an error under strict
/// concurrency — and a display link's callbacks belong on the main run loop.
@MainActor
final class BenchFrameTimer: NSObject {
    static let shared = BenchFrameTimer()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var deltas: [Double] = []

    func start() {
        link?.invalidate()
        deltas.removeAll(keepingCapacity: true)
        deltas.reserveCapacity(4096)
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { deltas.append(link.timestamp - last) }
        last = link.timestamp
    }

    /// ⚠️ **THE DENOMINATOR IS IN THE LINE.** `frames=0` is a display link that
    /// never ticked — a broken instrument — not a run with nothing to draw, and
    /// the two must never read alike. An empty instrument has already passed for
    /// a clean result four times on this branch.
    func stop() -> String {
        link?.invalidate()
        link = nil
        guard deltas.count > 1 else { return "frames=\(deltas.count) VOID-no-ticks" }
        let sorted = deltas.sorted()
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let nominal = 1.0 / 60.0
        let long = deltas.filter { $0 > nominal * 1.5 }.count
        return String(
            format: "frames=%ld mean=%.2fms p95=%.2fms max=%.2fms long=%ld",
            deltas.count, mean * 1000, p95 * 1000, sorted[sorted.count - 1] * 1000, long
        )
    }
}
#endif
