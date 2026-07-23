import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The sub-filter ORGANIZE sheet (the refinement row's ☰ button): a standard
/// iOS bottom sheet whose only job is arranging which refinements the
/// horizontal row carries, and in what order.
///
///   ╭──────────── grabber ────────────╮
///   │ Cancel      Following       Done│  ← discard / commit; Done is dark
///   │                                 │    until something actually changes
///   │  [ 🔍 Search              ]     │
///   │  ACTIVE FILTERS          2 of 6 │  ← what the horizontal bar shows
///   │  ⊖ Ava Moreau              ≡    │  ← always editing: remove + handle
///   │  ⊖ Kenji Tanaka            ≡    │
///   │  AVAILABLE                      │  ← …everything else on offer
///   │  ⊕ Lena Klein              ≡    │
///   ╰─────────────────────────────────╯
///
/// It does NOT apply filters. Picking which refinements are ON is the
/// horizontal row's job and only ever happens there — this sheet decides what
/// the row is made of. That split is why the rows carry no selection circle
/// and why the list is in edit mode from the first frame: there is exactly
/// one thing to do here, so there is nothing to switch into.
///
/// The two sections ARE the model: `MapSubFilterSections` owns membership,
/// capacity and order, and every gesture here is a call into it followed by a
/// snapshot. That struct is also the EDIT BUFFER — it is a value, held only by
/// this controller, and nothing leaves until the viewer commits:
///
/// - **Done** publishes the arrangement once (`onOptionsChanged`) and closes.
///   Disabled until the buffer actually differs from what the sheet opened on
///   (`hasChanges`), so the affirmative button is lit exactly when there is
///   something to affirm — and dark again if the viewer undoes their way back
///   to the original arrangement.
/// - **Cancel** closes having published nothing, so the row is still exactly
///   what it was when the sheet opened — the restore needs no undo stack
///   because no edit was ever applied outside this buffer. It is also the way
///   out of an untouched sheet, which is the point: with nothing changed,
///   leaving and committing are the same act, and only one of them should
///   look like a decision.
///
/// The one thing that does NOT ride the buffer is Mute: it is an account
/// courtesy owned by the host (`RowActions`), not part of what the row is made
/// of, so it applies immediately and survives Cancel — the same as muting from
/// anywhere else in the app.
///
/// Gestures, by section:
///
/// - **Active** — the ⊖ accessory demotes to Available.
/// - **Available** — the ⊕ accessory promotes to Active, subject to capacity.
/// - **Both** — the reorder handle drags within OR across the divide (the drag
///   equivalent of ⊖/⊕), and a long-press menu offers Profile / Mute on people
///   rows. A MENU, not swipe actions: UIKit suppresses swipe actions outright
///   while a list is editing, and this list always is.
///
/// Reordering is suppressed while a search query is active: a filtered subset
/// can't express a total order.
final class MapSubFilterSheetViewController: UIViewController {
    /// What a person row's long-press menu does. Everything here belongs to
    /// the host — the sheet knows the gesture, never the destination: routing
    /// is the shell's affair and the social graph is the repository's. Both
    /// act at once and outside the edit buffer, so both survive Cancel.
    @MainActor
    struct RowActions {
        /// Opens that person's profile (the sheet closes first, discarding).
        var openProfile: (MapFavorite) -> Void
        /// Flips the mute flag; the row re-renders from `isMuted`.
        var toggleMute: (MapFavorite) -> Void
        /// Live mute state, read when the menu is built so the title is never
        /// stale.
        var isMuted: (ProfileID) -> Bool

        static let none = RowActions(
            openProfile: { _ in }, toggleMute: { _ in }, isMuted: { _ in false }
        )
    }

    /// The EDIT BUFFER: the arrangement as the viewer is building it. A value
    /// this controller owns outright — every add, remove and drop lands here
    /// and nowhere else, which is the whole of Cancel's implementation.
    private(set) var sections: MapSubFilterSections
    /// The arrangement the sheet opened on — the baseline `hasChanges`
    /// measures against, so Done can stay dark until there is something to
    /// commit.
    private let initialActive: [MapSubFilter]
    /// The catalogue order, so a demoted row returns to its natural place in
    /// Available rather than the bottom.
    private let naturalOrder: [MapSubFilter]
    private let imagePipeline: ImagePipeline?
    private let rowActions: RowActions
    /// Fires ONCE, with the committed ACTIVE list, when the viewer taps Done —
    /// the horizontal bar then mirrors it verbatim. Cancel never calls it.
    private let onOptionsChanged: ([MapSubFilterOption]) -> Void

    private enum Section: Int, Hashable, CaseIterable {
        case active
        case available

        var title: String {
            switch self {
            case .active: "Active Filters"
            case .available: "Available"
            }
        }
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, MapSubFilter>!
    private let searchController = UISearchController(searchResultsController: nil)
    /// Commit: publish the buffer, then close. `.prominent` (iOS 26's rename
    /// of `.done`) gives it the filled accent capsule that marks the
    /// affirmative action.
    ///
    /// Spelled out, deliberately NOT `systemItem: .done` — iOS 26 draws the
    /// system Done and Cancel items as a ✓ and an ✕ glyph on a sheet like this
    /// one (verified in-sim). Two wordless marks are exactly the ambiguity
    /// this refactor set out to remove: a checkmark reads as "this row is
    /// selected", which is the one thing the sheet no longer does.
    private(set) lazy var doneItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: "Done",
            primaryAction: UIAction { [weak self] _ in self?.commitAndDismiss() }
        )
        item.style = .prominent
        return item
    }()
    /// Discard: close without publishing. Plain weight — abandoning changes
    /// should never be the more prominent of the two.
    private(set) lazy var cancelItem = UIBarButtonItem(
        title: "Cancel",
        primaryAction: UIAction { [weak self] _ in self?.cancelAndDismiss() }
    )
    /// Resolved avatars, keyed by profile — cache-hot from the pill row.
    private var avatarCache: [ProfileID: UIImage] = [:]
    private var avatarTasks: [Task<Void, Never>] = []
    private var query = ""

    /// Handles are meaningless over a filtered subset — see the type comment.
    private var isReorderable: Bool { query.isEmpty }

    /// Whether committing would actually tell the host anything new — the
    /// enabled state of Done, and the sheet's answer to "did I change
    /// something?".
    ///
    /// Measured against what Done PUBLISHES (the active list, in order),
    /// not against the whole buffer. Two consequences, both deliberate:
    ///
    /// - Rearranging within Available leaves this false. That order is never
    ///   committed and never survives a reopen (Available is rebuilt from the
    ///   catalogue every time), so lighting Done for it would promise a change
    ///   that cannot happen.
    /// - Removing a row and adding it straight back leaves this TRUE when it
    ///   lands somewhere new: `activate` appends, so a row taken from the
    ///   middle returns at the end. The list really is different, and the
    ///   viewer really would be committing that.
    ///
    /// Undo it exactly — drag it back to its old seat — and this reads false
    /// again, because the comparison is against the arrangement itself and
    /// never against a count of gestures.
    var hasChanges: Bool { sections.active.map(\.subFilter) != initialActive }

    /// The presentable form: the list wrapped in a navigation controller (the
    /// search controller and the bar items need a navigation item to dock
    /// into) configured as a standard medium/large sheet. Corner radius and
    /// dimming are left entirely to `UISheetPresentationController`.
    ///
    /// - Parameters:
    ///   - title: the primary this sheet refines ("Friends"/"Following"/"Places").
    ///   - all: every refinement the primary can offer, in repository order.
    ///   - activeSubFilters: which of them the bar shows, in bar order.
    ///   - onOptionsChanged: called once, on Done, with the committed list.
    static func makeSheet(
        title: String,
        all: [MapSubFilterOption],
        activeSubFilters: [MapSubFilter],
        imagePipeline: ImagePipeline?,
        rowActions: RowActions = .none,
        onOptionsChanged: @escaping ([MapSubFilterOption]) -> Void
    ) -> UINavigationController {
        let list = MapSubFilterSheetViewController(
            title: title, all: all, activeSubFilters: activeSubFilters,
            imagePipeline: imagePipeline, rowActions: rowActions,
            onOptionsChanged: onOptionsChanged
        )
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    init(
        title: String,
        all: [MapSubFilterOption],
        activeSubFilters: [MapSubFilter],
        imagePipeline: ImagePipeline?,
        rowActions: RowActions,
        onOptionsChanged: @escaping ([MapSubFilterOption]) -> Void
    ) {
        let sections = MapSubFilterSections(all: all, activeSubFilters: activeSubFilters)
        self.sections = sections
        // Baseline from the CONSTRUCTED sections, not the raw argument: the
        // initializer drops ids the catalogue doesn't know, and a baseline
        // holding a row the buffer can never contain would leave Done lit from
        // the first frame with nothing to commit.
        self.initialActive = sections.active.map(\.subFilter)
        self.naturalOrder = all.map(\.subFilter)
        self.imagePipeline = imagePipeline
        self.rowActions = rowActions
        self.onOptionsChanged = onOptionsChanged
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for task in avatarTasks { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureNavigationItem()
        configureCollectionView()
        // Editing is the sheet's ONLY mode — the handles and ⊖/⊕ are up from
        // the first frame, and there is no control to leave it by. Un-animated
        // because there is no "before" for the viewer to have seen.
        setEditing(true, animated: false)
        applySnapshot(animated: false)
        loadAvatars()
    }

    // MARK: - Navigation item

    private func configureNavigationItem() {
        // Discard left, title centre, commit right — the platform's own
        // arrangement for an editor you can back out of.
        navigationItem.leftBarButtonItem = cancelItem
        navigationItem.rightBarButtonItem = doneItem
        updateDoneAvailability()

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search"
        navigationItem.searchController = searchController
        // Left automatic, iOS 26 hands an iPhone sheet the NEW bottom-aligned
        // search bar; `.stacked` pins it under the title.
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    // MARK: - Collection view

    private func configureCollectionView() {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.headerMode = .supplementary
        // No swipe providers: UIKit suppresses swipe actions while a list is
        // editing, and this one always is. Remove/Add are the ⊖/⊕ accessories;
        // Profile/Mute are a long-press menu (see `contextMenuConfiguration`).
        let layout = UICollectionViewCompositionalLayout.list(using: listConfiguration)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // Nothing here is selectable. A row states what it is and offers the
        // two things you can do to it — remove/add, and drag; a highlight on
        // tap would promise a third that doesn't exist.
        collectionView.allowsSelection = false
        collectionView.pin(to: view)

        let registration = UICollectionView.CellRegistration<MapSubFilterRowCell, MapSubFilter> {
            [weak self] cell, indexPath, subFilter in
            guard let self, let option = option(for: subFilter) else { return }
            // Ask the MODEL which section this is, never `indexPath.section`:
            // once an empty section stops being appended, the remaining one
            // is index 0 and the raw value lies (Available rows came back
            // wearing the Active ⊖).
            let isActiveSection = section(of: subFilter) == .active
            cell.configure(
                option: option,
                avatar: option.favorite.flatMap { self.avatarCache[$0.profileID] },
                // Which verb this row's edit accessory carries: ⊖ for a row
                // that is in the bar, ⊕ for one that could be.
                isInActiveSection: isActiveSection,
                // Handles on BOTH sections: dragging across the divide is how
                // you add or remove without leaving edit mode, and a row you
                // can drop into a section you can't drag out of is a trap.
                isReorderable: isReorderable,
                isMuted: option.profileID.map(rowActions.isMuted) ?? false
            )
            cell.onInsertTapped = isActiveSection
                ? nil
                : { [weak self] in _ = self?.activate(subFilter) }
            cell.onDeleteTapped = isActiveSection
                ? { [weak self] in self?.deactivate(subFilter) }
                : nil
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            // Same trap as the cells: resolve the identity through the data
            // source, because a hidden section shifts every index below it.
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            var content = UIListContentConfiguration.groupedHeader()
            content.text = section?.title
            if section == .active, let self {
                // The cap is a rule the viewer is allowed to see coming.
                content.secondaryText = "\(sections.active.count) of \(sections.maxActive)"
                content.prefersSideBySideTextAndSecondaryText = true
            }
            header.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Section, MapSubFilter>(collectionView: collectionView) {
            collectionView, indexPath, subFilter in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: subFilter)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        // Any row may be dragged while editing — across the divide too, which
        // is the drag equivalent of Remove and Add.
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in
            guard let self else { return false }
            return isEditing && isReorderable
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let final = transaction.finalSnapshot
            // A section that holds nothing isn't IN the snapshot at all;
            // asking it for its items would trap.
            let present = Set(final.sectionIdentifiers)
            let items: (Section) -> [MapSubFilterOption] = { section in
                guard present.contains(section) else { return [] }
                return final.itemIdentifiers(inSection: section).compactMap { self.option(for: $0) }
            }
            let active = items(.active)
            let available = items(.available)
            // Model FIRST, view later. UIKit is still committing the move it
            // just performed, and applying a snapshot from inside this
            // callback re-enters that update — which is what crashed on every
            // cross-section drop. Adopting is pure value work and safe here;
            // everything that touches the collection view is deferred by one
            // runloop turn, once the commit has unwound.
            let accepted = sections.adopt(active: active, available: available)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Accepted: re-apply to reconfigure the moved row for the
                // section it landed in (a moved cell keeps its old
                // configuration — its ⊖/⊕ would be stale). Refused (over
                // capacity): the same apply is what puts the row back where it
                // came from. Either way the counter is now wrong.
                applySnapshot(animated: !accepted)
                reloadHeaders()
                // A drag is the one edit that can land back on the opening
                // arrangement, so this may darken Done as well as light it.
                updateDoneAvailability()
            }
        }
    }

    // MARK: - Sections

    private func option(for subFilter: MapSubFilter) -> MapSubFilterOption? {
        sections.active.first { $0.subFilter == subFilter }
            ?? sections.available.first { $0.subFilter == subFilter }
    }

    private func section(of subFilter: MapSubFilter) -> Section {
        sections.active.contains { $0.subFilter == subFilter } ? .active : .available
    }

    /// Rows on screen per section: everything, or the query's matches.
    private func visible(_ options: [MapSubFilterOption]) -> [MapSubFilter] {
        options
            .filter { query.isEmpty || $0.sheetTitle.localizedCaseInsensitiveContains(query) }
            .map(\.subFilter)
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, MapSubFilter>()
        let active = visible(sections.active)
        let available = visible(sections.available)
        // An empty section carries no information — a lone "Available" header
        // over nothing just asks the viewer what it means. Sections come and
        // go with their contents, which is why every reader below has to ask
        // whether a section exists before addressing it.
        if !active.isEmpty {
            snapshot.appendSections([.active])
            snapshot.appendItems(active, toSection: .active)
        }
        if !available.isEmpty {
            snapshot.appendSections([.available])
            snapshot.appendItems(available, toSection: .available)
        }
        // A row that CHANGES SECTION keeps its identity, so diffable moves
        // the existing cell and never re-runs the provider for it — a demoted
        // row kept the ⊕ it arrived with (caught in-sim). Reconfiguring the
        // carried-over items forces the provider to answer for the section
        // they are in now. Items new to this snapshot are excluded:
        // reconfiguring an identifier the current snapshot doesn't hold is not
        // a valid ask.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - Commit / discard

    /// Re-reads `hasChanges` into the bar. Called after EVERY buffer
    /// mutation and once at load, so Done's enabled state is derived rather
    /// than accumulated — there is no flag to leave stale, and an edit that
    /// happens to restore the opening arrangement darkens it again for free.
    private func updateDoneAvailability() {
        doneItem.isEnabled = hasChanges
    }

    /// Done: hand the host the arrangement, then close. Publishing BEFORE the
    /// dismissal starts lets the horizontal row restack underneath the sheet
    /// as it slides away, so what is revealed is already correct.
    ///
    /// Guarded rather than trusting the disabled button: `commitAndDismiss` is
    /// the whole commit path, and a no-op publish would still push the host
    /// through `adoptSubFilterOptions` — a restack, a re-render, and a
    /// preference write, all to arrive where it already was.
    func commitAndDismiss() {
        if hasChanges { onOptionsChanged(sections.active) }
        dismiss(animated: true)
    }

    /// Cancel: close, having published nothing. The buffer dies with the
    /// controller and the row never heard about any of it — which is why there
    /// is no restore path to get wrong.
    func cancelAndDismiss() {
        dismiss(animated: true)
    }

    private func reloadHeaders() {
        var snapshot = dataSource.snapshot()
        // The Active section is absent once it empties — nothing to reload.
        guard snapshot.sectionIdentifiers.contains(.active) else { return }
        snapshot.reloadSections([.active])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureVisibleRows() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Promotes an Available row into the buffer's active list. Refused (with
    /// a word about it) once the row is full — silently dropping the gesture
    /// would read as a broken button.
    @discardableResult
    func activate(_ subFilter: MapSubFilter) -> Bool {
        guard sections.activate(subFilter) else {
            let alert = UIAlertController(
                title: "Filter Row Full",
                message: "The row holds \(sections.maxActive) filters. Remove one to add another.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return false
        }
        applySnapshot(animated: true)
        reloadHeaders()
        updateDoneAvailability()
        return true
    }

    /// Demotes an Active row back to the catalogue. Nothing to unapply: this
    /// sheet never held the applied set — the bar reconciles its own selection
    /// against the committed list when Done lands.
    func deactivate(_ subFilter: MapSubFilter) {
        sections.deactivate(subFilter, naturalOrder: naturalOrder)
        applySnapshot(animated: true)
        reloadHeaders()
        updateDoneAvailability()
    }

    // MARK: - Row menu

    /// Profile / Mute on a person row. A long-press MENU rather than swipe
    /// actions: the list is permanently editing and UIKit refuses to run swipe
    /// actions in that state, so the swipes these replace were dead code the
    /// moment edit mode became the only mode. Place-category rows have no
    /// account behind them and get no menu at all.
    private func rowMenu(for subFilter: MapSubFilter) -> UIMenu? {
        guard let favorite = option(for: subFilter)?.favorite else { return nil }
        let muted = rowActions.isMuted(favorite.profileID)
        return UIMenu(children: [
            UIAction(
                title: "Profile",
                image: UIImage(systemName: "person.crop.circle"),
                handler: { [weak self] _ in self?.openProfile(favorite) }
            ),
            UIAction(
                title: muted ? "Unmute" : "Mute",
                image: UIImage(systemName: muted ? "speaker.wave.2" : "speaker.slash"),
                handler: { [weak self] _ in self?.toggleMute(favorite) }
            )
        ])
    }

    /// Opens the account. The sheet closes FIRST — the profile is a
    /// full-screen destination on the tab's stack, and leaving a half sheet
    /// standing over it would strand the viewer behind their own gesture.
    /// Deliberately WITHOUT committing: leaving for a profile is not agreeing
    /// to the edits, so this is a Cancel that happens to route somewhere.
    private func openProfile(_ favorite: MapFavorite) {
        dismiss(animated: true) { [rowActions] in rowActions.openProfile(favorite) }
    }

    /// Mute rides the HOST, not the edit buffer — it is an account courtesy
    /// rather than part of what the row is made of, so it applies at once and
    /// survives Cancel, exactly as muting does everywhere else.
    private func toggleMute(_ favorite: MapFavorite) {
        rowActions.toggleMute(favorite)
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.profile(favorite.profileID)) else { return }
        snapshot.reconfigureItems([.profile(favorite.profileID)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Edit mode

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        // The cells read `isEditing` off their configuration state, so this is
        // what raises the ⊖/⊕ and the reorder handle. Set once, at load: there
        // is no control that turns it back off.
        collectionView.isEditing = editing
    }

    // MARK: - Avatars

    private func loadAvatars() {
        guard let imagePipeline else { return }
        for option in sections.active + sections.available {
            guard let favorite = option.favorite, let url = favorite.avatarURL,
                  avatarCache[favorite.profileID] == nil else { continue }
            let subFilter = option.subFilter
            avatarTasks.append(Task { [weak self] in
                guard let image = try? await imagePipeline.image(for: url),
                      let self, !Task.isCancelled else { return }
                self.avatarCache[favorite.profileID] = image
                var snapshot = self.dataSource.snapshot()
                guard snapshot.itemIdentifiers.contains(subFilter) else { return }
                snapshot.reconfigureItems([subFilter])
                await self.dataSource.apply(snapshot, animatingDifferences: false)
            })
        }
    }
}

extension MapSubFilterSheetViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let subFilter = dataSource.itemIdentifier(for: indexPath),
              let menu = rowMenu(for: subFilter) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }
}

extension MapSubFilterSheetViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let next = (searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard next != query else { return }
        // Entering / leaving search flips whether the handles are shown.
        let reorderabilityChanged = next.isEmpty != query.isEmpty
        query = next
        applySnapshot(animated: true)
        if reorderabilityChanged {
            reconfigureVisibleRows()
        }
    }
}

/// One sheet row: a stock subtitle list cell — avatar (or glyph), display
/// name, `@handle` underneath — plus its edit accessory (⊖ to leave the bar,
/// ⊕ to join it), a mute glyph when the account is muted, and the system
/// reorder handle.
///
/// There is deliberately NO selection mark. Whether a refinement is currently
/// applied is the horizontal row's business; this cell only says what the row
/// is and what arranging it would do. Nothing appears or disappears
/// mid-session either — the list is editing from the first frame — which is
/// what keeps it from reflowing under the viewer's thumb.
final class MapSubFilterRowCell: UICollectionViewListCell {
    /// Tapping the edit-mode ⊕ on an Available row, or the ⊖ on an Active
    /// one. Both act on the spot — see `updateConfiguration`.
    var onInsertTapped: (() -> Void)?
    var onDeleteTapped: (() -> Void)?

    private var option: MapSubFilterOption?
    private var avatar: UIImage?
    private var isInActiveSection = false
    private var isReorderable = true
    private var isMuted = false

    func configure(
        option: MapSubFilterOption,
        avatar: UIImage?,
        isInActiveSection: Bool,
        isReorderable: Bool,
        isMuted: Bool
    ) {
        self.option = option
        self.avatar = avatar
        self.isInActiveSection = isInActiveSection
        self.isReorderable = isReorderable
        self.isMuted = isMuted
        setNeedsUpdateConfiguration()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        guard let option else { return }

        // Subtitle style only when there IS a subtitle: a place category
        // would otherwise sit high in a row sized for a second line that
        // never comes.
        var content = option.sheetSubtitle == nil
            ? UIListContentConfiguration.cell()
            : UIListContentConfiguration.subtitleCell()
        content.text = option.sheetTitle
        content.secondaryText = option.sheetSubtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = avatar ?? UIImage(systemName: option.content.symbolName)
        content.imageProperties.tintColor = .label
        // Reserve the avatar's slot from the first layout so a late arrival
        // can't reflow the row.
        content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
        content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
        content.imageProperties.cornerRadius = 16
        contentConfiguration = content
        backgroundConfiguration = .listGroupedCell()

        var accessories: [UICellAccessory] = []
        if state.isEditing {
            // The leading affordance states what this row's edit action DOES:
            // ⊖ removes an Active row from the bar, ⊕ adds an Available one.
            // (⊖ on an Available row was the old bug — it offered to remove a
            // row that isn't in the bar to begin with.)
            //
            // BOTH carry an explicit handler and act on the spot. A bare
            // `.delete()` only DISCLOSES the trailing swipe action, and UIKit
            // suppresses swipe actions while the list is editing — so the ⊖
            // was a button that did nothing at all (caught in-sim). Neither
            // gesture is destructive anyway: a removed row is sitting in
            // Available, one tap from coming back.
            if isInActiveSection {
                accessories.append(.delete(actionHandler: { [weak self] in
                    self?.onDeleteTapped?()
                }))
            } else {
                accessories.append(.insert(actionHandler: { [weak self] in
                    self?.onInsertTapped?()
                }))
            }
        }
        if isMuted {
            accessories.append(.customView(configuration: Self.muteBadge()))
        }
        if state.isEditing, isReorderable {
            accessories.append(.reorder(displayed: .always))
        }
        self.accessories = accessories
    }

    /// The muted marker: Mail's quiet-thread language (a struck-through
    /// speaker in secondary ink), not a badge that competes with the
    /// checkmark for meaning.
    private static func muteBadge() -> UICellAccessory.CustomViewConfiguration {
        let glyph = UIImageView(image: UIImage(systemName: "speaker.slash.fill"))
        glyph.tintColor = .secondaryLabel
        glyph.contentMode = .scaleAspectFit
        return UICellAccessory.CustomViewConfiguration(
            customView: glyph, placement: .trailing(displayed: .always)
        )
    }
}
