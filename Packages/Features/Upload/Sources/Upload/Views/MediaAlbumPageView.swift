import DesignSystem
import UIKit

/// One album, as a page of the picker's pager: a three-column grid of what it
/// holds, and nothing else.
///
/// **Why a view rather than a child view controller.** The relationship lists
/// put a whole screen on each page — its own view model, its own loading phases
/// — and pay for child-controller bookkeeping to get it. A page here is a grid
/// over a list of identifiers: the selection, the cap, the tray and the library
/// all belong to the picker, which owns every page. `HorizontalPagerView` takes
/// plain `UIView`s, so wrapping would buy nothing.
///
/// ⚠️ **NO PAGE MASKS ITSELF ANY MORE.** Each one used to fade its last row out
/// as it travelled under the chosen-media strip, with a gradient on its own
/// grid's layer — one mask per page, a layer mask not being shareable. Since
/// 2026-09-12 the album runs on at full strength to the foot of the screen and
/// the dissolve belongs to the picker: a `ProgressiveBlurView` hung from the
/// strip's top edge. A mask here as well would take the pixels away before the
/// blur could work on them.
///
/// ⚠️ **THE GEOMETRY LIVES HERE AND ONLY HERE.** The tile side, the gutter and
/// the column count were the picker's before the album became pages, and a copy
/// on each side is a copy that drifts. The picker's debug accessors forward to
/// these, so a test and the screen cannot disagree about what they measure.
final class MediaAlbumPageView: UIView {
    /// ⚠️ ONE NUMBER FOR BOTH GAPS. The space around the grid and the space
    /// between two tiles are the same measurement, so a tile is never closer to
    /// its neighbour than it is to the edge — which is what makes a grid read as
    /// a grid rather than as a block that has been nudged.
    /// ⚠️ **DELIBERATELY TINY.** At `Spacing.sm` the grid read as a set of
    /// separated cards; a library is a contact sheet, and the pictures are the
    /// subject, not the spaces between them. Because this ONE number is both the
    /// margin and the gutter, shrinking it closes the screen edges by exactly as
    /// much as it closes the gaps — which is what keeps it uniform.
    static let gutter: CGFloat = 2
    static let columns: CGFloat = 3

    /// Three tiles and FOUR gaps: one at each edge and one between each pair.
    static func tileSide(forWidth width: CGFloat) -> CGFloat {
        let gaps = gutter * (columns + 1)
        return max(((width - gaps) / columns).rounded(.down), 60)
    }

    /// What a tile needs to draw itself, answered by the picker because the
    /// selection is the picker's.
    struct Tile {
        let item: MediaLibraryItem
        let order: Int?
        let isSelectable: Bool
    }

    /// Asked for every tile the grid is about to show.
    var tile: ((String) -> Tile?)?
    /// A tile was tapped. The page never changes the selection itself.
    var onTap: ((String) -> Void)?
    /// ⚠️ `@MainActor` STATED ON THE CLOSURE. `MediaLibraryReading` is main-actor
    /// isolated and not `Sendable`, so a plainly-typed closure cannot carry a
    /// call to it out of this file — the tray's thumbnail provider wears the
    /// same annotation for the same reason.
    var thumbnail: (@MainActor (String, CGSize) async -> UIImage?)?
    /// The grid is about to reach these, or has given up on them.
    var onPrefetch: (([String], CGSize) -> Void)?
    var onCancelPrefetch: (([String], CGSize) -> Void)?

    private(set) var items: [MediaLibraryItem] = []
    /// Whether this album has been asked for at all. A page that has never
    /// loaded shows nothing rather than "this album is empty", which would be a
    /// claim it cannot yet make.
    private(set) var hasLoaded = false

    private var grid: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let emptyState = EmptyStateView()

    /// This page has been filled but its tiles have not sprung in yet. Consumed
    /// by `playReveal()`, which the picker calls once the page is genuinely on
    /// screen — see the note on `Reveal`.
    private(set) var awaitingReveal = false

    /// ⚠️ **STAGED ONCE PER ALBUM, PER SESSION — AND THE FIRST CUT OF THIS WAS
    /// A SINGLE `Bool`, WHICH WAS A BUG.** With one flag for the whole process,
    /// Recents consumed it and EVERY OTHER TAB was suppressed for good: the
    /// animation looked like a Recents-only feature. Keyed by album id, each
    /// tab still gets its own arrival the first time it loads, while reopening
    /// the sheet finds those same ids already staged and stays quiet — which is
    /// the behaviour that made the flag static in the first place.
    ///
    /// Measured with the `[reveal]` probe before the fix, opening → editor →
    /// back → reopening: `arms=2, plays=2, no-ops=1`. The pop-back was already a
    /// no-op; the REOPEN was the symptom.
    ///
    /// Per process, so relaunching the app shows the arrival again — right,
    /// because that IS a first load.
    private static var stagedAlbums: Set<String> = []

    #if DEBUG
    /// ⚠️ **TESTS RUN IN PARALLEL ACROSS SUITES.** Any test that opens a picker
    /// loads an album and would flip the session flag underneath a test
    /// asserting on `awaitingReveal`, making the pair order-dependent. An
    /// explicit per-page answer keeps them independent of each other.
    var debugStagesArrival: Bool?

    /// How many cells the last `playReveal()` actually animated.
    ///
    /// ⚠️ **THE DEBT FLAG CANNOT ANSWER THIS, AND FILM PROVED IT MATTERS.** A
    /// guard that passes over an EMPTY `visibleCells` un-hides the grid, spends
    /// `awaitingReveal` and animates nothing — indistinguishable, to every test
    /// we had, from a reveal that played. On device that is a pop.
    private(set) var debugRevealedCells = 0

    /// Internal for tests: the room the access banner claims at the top of this
    /// page. Reading the inset is how "the first row is not hidden under the
    /// notice" gets checked without measuring pixels.
    var debugNoticeReserve: CGFloat { grid.contentInset.top }
    #endif

    /// Which album this page is currently showing, so the session can remember
    /// that THIS one has had its arrival.
    private var albumID: String?

    /// Whether an arrival may be staged at all, session included.
    private var maySpringIn: Bool {
        #if DEBUG
        // ⚠️ **THE BASELINE HALF OF THE BENCH.** `-upload-no-reveal` runs the
        // identical album walk — same loading, same layout, same thumbnails —
        // with no arrival animation at all: the debt is never armed, so
        // `setItems` un-hides the grid at once and `playReveal` leaves on its
        // guard. The difference between the two runs is the animation's share
        // and nothing else, which is the number to have BEFORE optimising it.
        if ProcessInfo.processInfo.arguments.contains("-upload-no-reveal") { return false }
        if let debugStagesArrival { return debugStagesArrival }
        #endif
        guard let albumID else { return false }
        return !Self.stagedAlbums.contains(albumID)
    }

    /// How the album arrives.
    ///
    /// ⚠️ **THE STAGGER IS A DISTANCE, NOT AN INDEX.** Ordering the delay by
    /// item number is what produced the sweep from the top-left corner to the
    /// bottom-right that this replaced: the grid is filled in index order, so an
    /// index-based delay simply re-draws that diagonal. Measuring each tile from
    /// the VISIBLE CENTRE makes the album open outwards from the middle
    /// regardless of how many columns there are or where the viewer is scrolled.
    ///
    /// ⚠️ **AND IT IS PLAYED ON DEMAND, NOT FROM `willDisplay`. FILMED, TWICE.**
    /// Hanging the spring off `willDisplay` put it in a race it always lost. The
    /// cells are realised inside `setItems` — `configure` draws the tile, its
    /// ring and its duration synchronously, and only the thumbnail arrives later
    /// — and `setItems` runs as the album loads, while the sheet is still
    /// presenting the picker. At 30fps the tiles crossed from bare tile to
    /// finished thumbnail in a SINGLE frame, with no ramp anywhere in the
    /// window: the springs had been committed with nothing on screen to carry
    /// them. Correcting *when the disarm fired* could not help, because the
    /// animation was already being swallowed before the disarm mattered.
    /// `playReveal()` runs at the one moment the page provably has a rectangle.
    ///
    /// ⚠️ **AMENDMENT (2026-09-12): THAT SYMPTOM HAS A SECOND, CONFIRMED CAUSE,
    /// SO DO NOT READ A FLAT TRACE AS PROOF OF *WHERE* AN ANIMATION WAS LOST.**
    /// "A single frame with no ramp anywhere in the window" is also exactly what
    /// a wrong from-value produces — see `Reveal.fadeDuration`, where the fade
    /// carried `.beginFromCurrentState` and animated 1 → 1. The reading above was
    /// taken on a different code state and is not disproven. But measured here,
    /// `playReveal` ran with `window=true`, `bounds=(402, 812)`, 18 cells and
    /// `animationsEnabled=true` — provably on screen — and the tiles STILL landed
    /// in one frame. Four hypotheses died on that flat trace before the
    /// presentation layer separated them in a single run. Sample
    /// `layer.presentation()` before concluding anything about placement.
    private enum Reveal {
        static let scale: CGFloat = 0.86
        static let duration: TimeInterval = 0.42
        static let damping: CGFloat = 0.7
        /// The furthest tile waits this long; everything nearer is a fraction of
        /// it. Short enough that the album still feels immediate.
        static let stagger: TimeInterval = 0.22

        /// The opacity eases on its own, slower curve, so the growth and the
        /// arrival read as two gestures rather than one.
        ///
        /// ⚠️ **WHY THE FADE ONCE LOOKED ABSENT IS NOT WHAT THIS COMMENT USED TO
        /// SAY.** It claimed the opacity was hidden by sharing the transform's
        /// spring. Measured, that was wrong — the fade was not running at all.
        /// Sampled from the PRESENTATION layer at +0ms after staging:
        /// `scaleX=0.86` (the spring starting correctly from its staged value)
        /// while `opacity=1.00`, when 73ms into a 0.52s ease-out it should read
        /// about 0.3. The fade carried `.beginFromCurrentState`, which sources
        /// the from-value from the presentation layer, and that layer still read
        /// 1 because `alpha = 0` had been set in the same turn with no frame yet
        /// rendered. So it animated 1 → 1: attached, enabled, unstripped, and
        /// invisible by construction. Dropping that one option fixed it.
        ///
        /// Filmed after, at 48fps: each tile ramps 0.333-0.375s, which is exactly
        /// 10→90% of a 0.52s ease-out (that window spans ~67% of the duration —
        /// do not expect the full 0.52s from a threshold measurement).
        static let fadeDuration: TimeInterval = 0.52
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureGrid()
        emptyState.isHidden = true
        emptyState.isUserInteractionEnabled = false
        emptyState.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - What it shows

    func setItems(_ items: [MediaLibraryItem], albumID: String = "") {
        let wasEmpty = self.items.isEmpty
        self.items = items
        self.albumID = albumID
        hasLoaded = true
        #if DEBUG
        logReveal("setItems count=\(items.count) wasEmpty=\(wasEmpty)")
        #endif
        emptyState.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyState.configure(
                symbolName: "photo.on.rectangle.angled",
                title: "This album is empty"
            )
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        // The tiles are NOT sprung in from here: this runs while the album is
        // loading, which is before the sheet has finished presenting. The page
        // only records that it owes a reveal; the picker calls it in.
        //
        // ⚠️ **ONLY WHEN THE GRID GOES FROM NOTHING TO SOMETHING, AND ONLY ONCE
        // PER SESSION.** The spring is an arrival: a page that already holds its
        // cells must not replay it, and neither must a REOPENED sheet, where the
        // viewer has seen the library already. See `hasStagedArrivalThisSession`
        // for why the second half cannot be answered from this instance.
        awaitingReveal = wasEmpty && !items.isEmpty && maySpringIn
        // ⚠️ **HIDDEN UNTIL THE WHOLE GRID IS READY.** Revealing per cell as
        // each was realised is what made the effect read as "bizarre": tiles
        // arrived at slightly different moments, and any realised after the
        // reveal had already run appeared plainly, so the grid assembled itself
        // in visible stages. The grid now shows nothing until `playReveal()`
        // brings all of its cells in together — the individual THUMBNAILS may
        // still be loading, which is fine; it is the set of CELLS that must be
        // complete.
        grid.alpha = awaitingReveal ? 0 : 1
        dataSource.apply(snapshot, animatingDifferences: false)
        // ⚠️ THE OFFSET IS READ AFTER A LAYOUT PASS, NOT BEFORE ONE.
        // `adjustedContentInset` is only final once the grid has been laid out
        // inside the bars above and below it. Read on the way in it is short by
        // the navigation bar, and the album opens a few points too high — a
        // sliver of the first row showing above the top of the grid.
        grid.layoutIfNeeded()
        grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
    }

    /// Springs the tiles that are on screen in, from the middle outwards.
    ///
    /// Called by the picker when this page is genuinely visible: the sheet has
    /// finished presenting, or the pager has settled on it. Does nothing unless
    /// the page owes a reveal AND is in a window with a rectangle to animate in
    /// — an animation committed outside one is not slow, it is instant.
    func playReveal() {
        #if DEBUG
        logReveal("playReveal owed=\(awaitingReveal) window=\(window != nil) bounds=\(bounds.size)")
        #endif
        guard awaitingReveal, window != nil, !bounds.isEmpty else { return }
        awaitingReveal = false
        // Recorded only when the arrival ACTUALLY plays, and against THIS album:
        // a page that owed one but never got a rectangle has shown the viewer
        // nothing, so its album still deserves one.
        if let albumID { Self.stagedAlbums.insert(albumID) }

        // ⚠️ THE LAYOUT PASS COMES FIRST, so every cell the viewport holds is
        // realised before any of them is animated. Without it the ones realised
        // late would arrive plainly, which is the staged assembly this replaces.
        grid.layoutIfNeeded()
        grid.alpha = 1
        let centre = CGPoint(
            x: grid.contentOffset.x + grid.bounds.width / 2,
            y: grid.contentOffset.y + grid.bounds.height / 2
        )
        let halfWidth = grid.bounds.width / 2
        let halfHeight = grid.bounds.height / 2
        let reach = max(1, (halfWidth * halfWidth + halfHeight * halfHeight).squareRoot())

        let revealing = grid.visibleCells
        #if DEBUG
        // ⚠️ **THE COUNT IS THE WHOLE POINT.** A guard that passes over an EMPTY
        // set un-hides the grid and animates nothing, which on film is
        // indistinguishable from a guard that never passed: both are a pop. The
        // probe has to separate them or a run comes back unreadable.
        debugRevealedCells = revealing.count
        // ⚠️ `areAnimationsEnabled` IS IN THIS LINE DELIBERATELY. Eighteen
        // committed animations that reach film as a single-frame pop were either
        // disabled wholesale at commit time or undone immediately afterwards,
        // and those want opposite fixes.
        logReveal("playReveal animating cells=\(revealing.count) animationsEnabled=\(UIView.areAnimationsEnabled)")
        #endif
        for cell in revealing {
            guard let indexPath = grid.indexPath(for: cell),
                  let attributes = grid.layoutAttributesForItem(at: indexPath)
            else { continue }
            let dx = attributes.center.x - centre.x
            let dy = attributes.center.y - centre.y
            let distance = (dx * dx + dy * dy).squareRoot()
            let delay = Reveal.stagger * TimeInterval(min(1, distance / reach))

            // Set the from-values and animate in the SAME turn, so the render
            // server never gets to show the settled state first.
            cell.transform = CGAffineTransform(scaleX: Reveal.scale, y: Reveal.scale)
            cell.alpha = 0
            // The SHAPE springs …
            UIView.animate(
                withDuration: Reveal.duration,
                delay: delay,
                usingSpringWithDamping: Reveal.damping,
                initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                cell.transform = .identity
            }
            // … and the OPACITY eases, on a separate and slower curve. Sharing
            // the spring is what made the fade invisible — see `fadeDuration`.
            // ⚠️ **NO `.beginFromCurrentState` ON THE FADE — MEASURED, NOT
            // GUESSED.** Sampled from the PRESENTATION layer at +0ms after
            // staging: `scaleX=0.86` (the spring starts from its staged value,
            // correctly) while `opacity=1.00`, when 73ms into a 0.52s ease-out
            // it should read about 0.3. `.beginFromCurrentState` takes the
            // from-value from the presentation layer, and that layer still read
            // 1 because `cell.alpha = 0` was set in this same turn and no frame
            // had rendered it yet. So the fade ran 1 → 1: attached (anims=2),
            // enabled, unstripped, and invisible by construction. The spring
            // escapes it because `usingSpringWithDamping` carries an explicit
            // from-value — which is exactly why scale showed and fade never did.
            UIView.animate(
                withDuration: Reveal.fadeDuration,
                delay: delay,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                cell.alpha = 1
            }
        }
    }

    #if DEBUG
    /// Counts every arm and every play, behind `-upload-log-sheet`.
    ///
    /// ⚠️ The reported symptom — the spring replaying on every opening — does
    /// not match the code as read: `awaitingReveal` is armed only here and is
    /// consumed by the first `playReveal()`, so a pop-back should no-op. Either
    /// something re-fills the page, or the complaint is about a fresh screen.
    /// Those want different fixes, so this counts rather than assumes.
    /// ⚠️ **CACHED FLAG AND AN `@autoclosure` MESSAGE — BOTH FOR ONE REASON.**
    /// `playReveal()` logs BEFORE its guard, and `onProgress` calls it on every
    /// frame of a drag between albums. So the old form rebuilt
    /// `ProcessInfo.arguments` — an array of strings — and eagerly interpolated
    /// the message sixty times a second, only to throw both away whenever the
    /// flag is absent, which is every run that is not a probe. The flag cannot
    /// change during a process, so it is read once.
    private static let isLoggingReveal =
        ProcessInfo.processInfo.arguments.contains("-upload-log-sheet")

    private func logReveal(_ what: @autoclosure () -> String) {
        guard Self.isLoggingReveal else { return }
        // ⚠️ **stderr, NOT `print` — AND THIS COST TWO FILMED RUNS.** Redirected
        // to a file, stdout is BLOCK-buffered: the lines sit in a 4KB buffer
        // inside an app that never exits, so the sink reads as a silent probe
        // while the probe is in fact firing. Measured: a run wrote 0 stdout
        // lines while stderr carried 645 bytes of runtime noise. stderr is
        // unbuffered and lands at once.
        // ⚠️ STAMPED, so a log line can be laid against a film frame. "When did
        // the reveal run relative to the grid becoming visible" is unanswerable
        // without a clock, and the grid's arrival has already moved between runs
        // (t=6.67s, then t=3.50s).
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[reveal] t=\(stamp) \(what())\n".utf8))
    }
    #endif

    /// The room the tray takes, given back as inset rather than as height: the
    /// tiles under the tray stay where they are, and the last row can still be
    /// scrolled clear of it.
    func setTrayReserve(_ reserved: CGFloat) {
        grid.contentInset.bottom = reserved
        grid.verticalScrollIndicatorInsets.bottom = reserved
    }

    /// The room the access notice takes at the top, given back as inset for the
    /// same reason the tray's is: the banner is laid OVER the grid, so without
    /// this the first row would sit under it permanently and the notice would
    /// hide the very photos it is talking about.
    func setNoticeReserve(_ reserved: CGFloat) {
        grid.contentInset.top = reserved
        grid.verticalScrollIndicatorInsets.top = reserved
    }

    /// Re-runs the cell registration for these identifiers, for the tiles whose
    /// number or availability changed without the finger being on them.
    func reconfigure(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        let present = Set(snapshot.itemIdentifiers)
        let stale = ids.filter { present.contains($0) }
        guard !stale.isEmpty else { return }
        snapshot.reconfigureItems(stale)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// ⚠️ THE TILE THAT WAS TAPPED IS UPDATED IN PLACE. A reconfigure re-runs
    /// the registration, which cannot animate the one tile a finger is on — so
    /// that tile is configured directly and the rest follow through the
    /// snapshot. Answers whether it was on screen to update.
    @discardableResult
    func updateTile(_ id: String, animated: Bool) -> Bool {
        guard let indexPath = dataSource.indexPath(for: id),
              let cell = grid.cellForItem(at: indexPath) as? MediaPickerGridCell,
              let tile = tile?(id)
        else { return false }
        cell.configure(
            item: tile.item, order: tile.order, isSelectable: tile.isSelectable, animated: animated
        )
        return true
    }

    // MARK: - The grid

    private var tileSide: CGFloat { Self.tileSide(forWidth: bounds.width) }

    private func configureGrid() {
        grid = UICollectionView(frame: .zero, collectionViewLayout: Self.gridLayout())
        grid.backgroundColor = .systemBackground
        grid.alwaysBounceVertical = true
        // ⚠️ NOT `prefersSoftTopEdge()`, unlike every other list under a header.
        // The album runs crisp under the picker's bar on iOS 26.5 and on iOS 27
        // alike, with no line to remove; `.soft` would ADD a blur on iOS 27 that
        // this screen has never had. The picker's pager says the same, and why.
        grid.delegate = self
        grid.prefetchDataSource = self
        // ⚠️ **NO MASK ON THIS GRID, DELIBERATELY.** The album used to fade its
        // last row out as it passed under the chosen-media strip. It now runs on
        // at full strength all the way to the foot of the screen, and the
        // DISSOLVE IS THE PICKER'S — a progressive blur hung from the strip's
        // top edge (`ProgressiveBlurView`). A mask here as well would take the
        // pixels away before the blur ever got to work on them.
        grid.pin(to: self)

        let cell = UICollectionView.CellRegistration<MediaPickerGridCell, String> { [weak self] cell, _, id in
            guard let self, let tile = tile?(id) else { return }
            cell.configure(item: tile.item, order: tile.order, isSelectable: tile.isSelectable)
            let size = CGSize(width: tileSide, height: tileSide)
            Task { [weak cell] in
                let image = await self.thumbnail?(id, size)
                cell?.showThumbnail(image, for: id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: grid) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
    }

    /// ⚠️ THE TILE IS MEASURED FROM THE LAYOUT ENVIRONMENT, not from `bounds`. A
    /// page is laid out at one width and re-laid at another as the sheet or the
    /// device turns, and a layout built against a stale width leaves a column
    /// hanging over the edge.
    private static func gridLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout(
            sectionProvider: { _, environment in
                let side = tileSide(forWidth: environment.container.effectiveContentSize.width)
                let size = NSCollectionLayoutSize(
                    widthDimension: .absolute(side), heightDimension: .absolute(side)
                )
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)
                    ),
                    repeatingSubitem: item,
                    count: Int(columns)
                )
                group.interItemSpacing = .fixed(gutter)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = gutter
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: gutter, leading: gutter, bottom: gutter, trailing: gutter
                )
                return section
            }
        )
    }

}

// MARK: - Delegates

extension MediaAlbumPageView: UICollectionViewDelegate {
    /// ⚠️ **EVERY CELL ARRIVES AT IDENTITY.** The reveal is played by
    /// `playReveal()` over the cells that are already on screen; a cell realised
    /// afterwards — a scroll, a reconfigure, a reused cell caught mid-spring —
    /// must not ride a stale transform back in on the recycled view. Two
    /// assignments are cheaper than the class of bug they close.
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        cell.transform = .identity
        cell.alpha = 1
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        onTap?(id)
    }
}

extension MediaAlbumPageView: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let side = tileSide
        onPrefetch?(ids(at: indexPaths), CGSize(width: side, height: side))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let side = tileSide
        onCancelPrefetch?(ids(at: indexPaths), CGSize(width: side, height: side))
    }

    private func ids(at indexPaths: [IndexPath]) -> [String] {
        indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
    }
}
