import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The sub-filter full-list sheet (the refinement row's trailing bubble): a
/// standard iOS bottom sheet holding the whole refinement catalogue for the
/// active primary, in two sections.
///
///   ╭──────────── grabber ────────────╮
///   │ Edit        Following       Done│  ← validates and closes
///   │  [ 🔍 Search              ]     │
///   │  ACTIVE FILTERS          2 of 6 │  ← what the horizontal bar shows
///   │  ◉ Ava Moreau               ✔︎  │  ← circles are always here…
///   │  ◉ Kenji Tanaka             ◯  │
///   │  AVAILABLE                      │  ← …everything else on offer
///   │  ◉ Lena Klein                   │
///   ╰─────────────────────────────────╯
///
/// The two sections ARE the model: `MapSubFilterSections` owns membership,
/// capacity and order, and every gesture here is a call into it followed by a
/// snapshot. Moving a row between sections is therefore the same operation as
/// adding or removing a pill from the horizontal bar — one publish
/// (`onOptionsChanged`) keeps them in step, live, while the sheet is open.
///
/// Gestures, by section:
///
/// - **Active** — trailing swipe Remove (destructive) demotes to Available;
///   edit mode adds the reorder handle and the delete accessory (same demote).
/// - **Available** — trailing swipe Add promotes to Active, subject to
///   capacity.
/// - **Both** — leading swipe Profile, trailing swipe Mute (people rows only).
///
/// Selection has no modes. Every Active row carries a selection circle at all
/// times, a tap toggles it, and the map re-queries the union as you go — so
/// building "Lena and Marcus" is two taps with nothing to switch on first.
/// Tapping an Available row promotes it and turns it on in the same gesture:
/// you cannot filter by something the bar doesn't carry. Done in the top
/// right validates the result and closes; the sheet also publishes each tap
/// live, so closing by swipe or by tapping outside keeps exactly what you
/// built.
///
/// Reordering is suppressed while a search query is active: a filtered subset
/// can't express a total order.
final class MapSubFilterSheetViewController: UIViewController {
    /// What a person row's swipe actions do. Everything here belongs to the
    /// host — the sheet knows the gesture, never the destination: routing is
    /// the shell's affair and the social graph is the repository's.
    @MainActor
    struct RowActions {
        /// Opens that person's profile (the sheet closes first).
        var openProfile: (MapFavorite) -> Void
        /// Flips the mute flag; the row re-renders from `isMuted`.
        var toggleMute: (MapFavorite) -> Void
        /// Live mute state, read at swipe time so the title is never stale.
        var isMuted: (ProfileID) -> Bool

        static let none = RowActions(
            openProfile: { _ in }, toggleMute: { _ in }, isMuted: { _ in false }
        )
    }

    /// The live split — mutated by every add, remove, drop and deletion.
    private(set) var sections: MapSubFilterSections
    /// The catalogue order, so a demoted row returns to its natural place in
    /// Available rather than the bottom.
    private let naturalOrder: [MapSubFilter]
    private var selected: Set<MapSubFilter>
    private let imagePipeline: ImagePipeline?
    private let rowActions: RowActions
    /// Fires with the ACTIVE list on every membership or order change — the
    /// horizontal bar mirrors it verbatim.
    private let onOptionsChanged: ([MapSubFilterOption]) -> Void
    /// Fires with the applied refinements on every tap — the bar and the map
    /// follow the selection as it is built, not once at the end.
    private let onSelectionChanged: (Set<MapSubFilter>) -> Void

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
    /// The validation action: the system Done item (prominent by default on
    /// iOS 26), which confirms what the rows already show and closes.
    private lazy var doneItem = UIBarButtonItem(
        systemItem: .done,
        primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
    )
    /// The edit toggle, spelled out. Deliberately NOT `editButtonItem`: iOS 26
    /// draws that as a ✓ glyph in its active state, which put a second
    /// checkmark on the bar directly opposite the validation one — two
    /// identical marks meaning different things.
    private lazy var editItem = UIBarButtonItem(
        title: "Edit",
        primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            setEditing(!isEditing, animated: true)
        }
    )
    /// Resolved avatars, keyed by profile — cache-hot from the pill row.
    private var avatarCache: [ProfileID: UIImage] = [:]
    private var avatarTasks: [Task<Void, Never>] = []
    private var query = ""

    /// Handles are meaningless over a filtered subset — see the type comment.
    private var isReorderable: Bool { query.isEmpty }

    /// The presentable form: the list wrapped in a navigation controller (the
    /// search controller and the bar items need a navigation item to dock
    /// into) configured as a standard medium/large sheet. Corner radius and
    /// dimming are left entirely to `UISheetPresentationController`.
    ///
    /// - Parameters:
    ///   - title: the primary this sheet refines ("Friends"/"Following"/"Places").
    ///   - all: every refinement the primary can offer, in repository order.
    ///   - activeSubFilters: which of them the bar shows, in bar order.
    static func makeSheet(
        title: String,
        all: [MapSubFilterOption],
        activeSubFilters: [MapSubFilter],
        selected: Set<MapSubFilter>,
        imagePipeline: ImagePipeline?,
        rowActions: RowActions = .none,
        onOptionsChanged: @escaping ([MapSubFilterOption]) -> Void,
        onSelectionChanged: @escaping (Set<MapSubFilter>) -> Void
    ) -> UINavigationController {
        let list = MapSubFilterSheetViewController(
            title: title, all: all, activeSubFilters: activeSubFilters,
            selected: selected, imagePipeline: imagePipeline, rowActions: rowActions,
            onOptionsChanged: onOptionsChanged, onSelectionChanged: onSelectionChanged
        )
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    private init(
        title: String,
        all: [MapSubFilterOption],
        activeSubFilters: [MapSubFilter],
        selected: Set<MapSubFilter>,
        imagePipeline: ImagePipeline?,
        rowActions: RowActions,
        onOptionsChanged: @escaping ([MapSubFilterOption]) -> Void,
        onSelectionChanged: @escaping (Set<MapSubFilter>) -> Void
    ) {
        self.sections = MapSubFilterSections(all: all, activeSubFilters: activeSubFilters)
        self.naturalOrder = all.map(\.subFilter)
        self.selected = selected
        self.imagePipeline = imagePipeline
        self.rowActions = rowActions
        self.onOptionsChanged = onOptionsChanged
        self.onSelectionChanged = onSelectionChanged
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
        applySnapshot(animated: false)
        loadAvatars()
    }

    // MARK: - Navigation item

    private func configureNavigationItem() {
        // Edit left, title centre, Done right.
        navigationItem.leftBarButtonItem = editItem
        navigationItem.rightBarButtonItem = doneItem

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
        listConfiguration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingActions(at: indexPath)
        }
        listConfiguration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, !isEditing,
                  let subFilter = dataSource.itemIdentifier(for: indexPath),
                  let favorite = option(for: subFilter)?.favorite else { return nil }
            return UISwipeActionsConfiguration(actions: [profileAction(favorite)])
        }
        let layout = UICollectionViewCompositionalLayout.list(using: listConfiguration)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // The applied refinements ARE the collection view's selection: that is
        // what the multiselect accessory renders from, and it makes a tap on a
        // lit row arrive as a deselect rather than a second select.
        collectionView.allowsMultipleSelection = true
        // Editing rearranges and removes; it never applies a filter.
        collectionView.allowsSelectionDuringEditing = false
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
                // Circles belong to the rows that CAN be applied — an
                // Available row has to join the bar before it can be on.
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
                // configuration — its selection circle would be stale).
                // Refused (over capacity): the same apply is what puts the
                // row back where it came from.
                applySnapshot(animated: !accepted)
                if accepted { publishOptions() } else { reloadHeaders() }
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
        // the existing cell and never re-runs the provider for it — the
        // demoted row kept its selection circle, and a promoted one would
        // arrive without one (caught in-sim). Reconfiguring the carried-over
        // items forces the provider to answer for the section they are in
        // now. Items new to this snapshot are excluded: reconfiguring an
        // identifier the current snapshot doesn't hold is not a valid ask.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter(existing.contains)
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.syncCollectionSelection()
        }
    }

    /// Mirrors `selected` into the collection view. Programmatic selection
    /// doesn't call the delegate, so this can't loop back into a toggle; it
    /// runs after every apply because a row that moved section (or left the
    /// list) comes back deselected.
    private func syncCollectionSelection() {
        let snapshot = dataSource.snapshot()
        let lit = Set(snapshot.sectionIdentifiers.contains(.active)
            ? snapshot.itemIdentifiers(inSection: .active).filter(selected.contains)
            : [])
        let currently = Set(collectionView.indexPathsForSelectedItems ?? [])
        for item in snapshot.itemIdentifiers {
            guard let indexPath = dataSource.indexPath(for: item) else { continue }
            switch (lit.contains(item), currently.contains(indexPath)) {
            case (true, false):
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            case (false, true):
                collectionView.deselectItem(at: indexPath, animated: false)
            default:
                break
            }
        }
    }

    /// Publishes the active list and refreshes the header counter.
    private func publishOptions() {
        onOptionsChanged(sections.active)
        reloadHeaders()
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

    /// Promotes an Available row into the bar. Refused (with a word about it)
    /// once the row is full — silently dropping the gesture would read as a
    /// broken button.
    private func activate(_ subFilter: MapSubFilter) -> Bool {
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
        publishOptions()
        return true
    }

    /// Demotes an Active row back to the catalogue, dropping any selection it
    /// carried — a refinement can't stay applied once its pill is gone.
    private func deactivate(_ subFilter: MapSubFilter) {
        sections.deactivate(subFilter, naturalOrder: naturalOrder)
        if selected.remove(subFilter) != nil {
            onSelectionChanged(selected)
        }
        applySnapshot(animated: true)
        publishOptions()
    }

    // MARK: - Swipe actions

    /// The trailing swipe is the SECTION's own verb, in either mode — Active
    /// removes, Available adds. Edit mode used to answer "Delete" for both,
    /// which offered to remove a row that wasn't there in the first place.
    private func trailingActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let subFilter = dataSource.itemIdentifier(for: indexPath) else { return nil }
        var actions: [UIContextualAction] = switch section(of: subFilter) {
        case .active: [removeAction(subFilter)]
        case .available: [addAction(subFilter)]
        }
        // Mute is an account courtesy, not a list operation — out of the way
        // while editing.
        if !isEditing, let favorite = option(for: subFilter)?.favorite {
            actions.append(muteAction(favorite))
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    private func removeAction(_ subFilter: MapSubFilter) -> UIContextualAction {
        let action = UIContextualAction(style: .destructive, title: "Remove") {
            [weak self] _, _, completion in
            self?.deactivate(subFilter)
            completion(true)
        }
        action.image = UIImage(systemName: "minus.circle")
        return action
    }

    private func addAction(_ subFilter: MapSubFilter) -> UIContextualAction {
        let action = UIContextualAction(style: .normal, title: "Add") {
            [weak self] _, _, completion in
            completion(self?.activate(subFilter) ?? false)
        }
        action.image = UIImage(systemName: "plus.circle")
        action.backgroundColor = .systemBlue
        return action
    }

    /// Opens the account. The sheet closes FIRST — the profile is a
    /// full-screen destination on the tab's stack, and leaving a half sheet
    /// standing over it would strand the viewer behind their own gesture.
    private func profileAction(_ favorite: MapFavorite) -> UIContextualAction {
        let action = UIContextualAction(style: .normal, title: "Profile") {
            [weak self] _, _, completion in
            completion(true)
            guard let self else { return }
            dismiss(animated: true) { [rowActions] in rowActions.openProfile(favorite) }
        }
        action.image = UIImage(systemName: "person.crop.circle")
        action.backgroundColor = .systemBlue
        return action
    }

    private func muteAction(_ favorite: MapFavorite) -> UIContextualAction {
        let muted = rowActions.isMuted(favorite.profileID)
        let action = UIContextualAction(style: .normal, title: muted ? "Unmute" : "Mute") {
            [weak self] _, _, completion in
            guard let self else { return completion(false) }
            rowActions.toggleMute(favorite)
            var snapshot = dataSource.snapshot()
            if snapshot.itemIdentifiers.contains(.profile(favorite.profileID)) {
                snapshot.reconfigureItems([.profile(favorite.profileID)])
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            completion(true)
        }
        action.image = UIImage(systemName: muted ? "speaker.wave.2" : "speaker.slash")
        action.backgroundColor = .systemIndigo
        return action
    }

    // MARK: - Edit mode

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        // The cells read `isEditing` off their configuration state, so this
        // is what swaps the selection circle for ⊖/⊕ and the grabber.
        collectionView.isEditing = editing
        editItem.title = editing ? "Done" : "Edit"
        editItem.style = editing ? .done : .plain
        // Validation is meaningless mid-edit: the rows the viewer is
        // rearranging aren't a result yet, and two live "finish" buttons on
        // one bar is a question nobody should have to answer.
        doneItem.isEnabled = !editing
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
    /// A tap on an unlit row. UIKit has already marked the cell selected, so
    /// the accessory is filled before this runs — the model just follows.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let subFilter = dataSource.itemIdentifier(for: indexPath) else { return }
        // You cannot filter by something the bar doesn't carry: picking an
        // Available row promotes it first, and a full row refuses the whole
        // gesture rather than applying an invisible filter.
        if section(of: subFilter) == .available, !activate(subFilter) {
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }
        apply(selection: selected.union([subFilter]))
    }

    /// A tap on a lit row — with multiple selection on, that arrives here
    /// instead of as a second select, which is exactly the toggle we want.
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard let subFilter = dataSource.itemIdentifier(for: indexPath) else { return }
        apply(selection: selected.subtracting([subFilter]))
    }

    /// The sheet stays open on every pick: the next one is a tap away, and
    /// Done is the only thing that closes it.
    private func apply(selection: Set<MapSubFilter>) {
        guard selection != selected else { return }
        selected = selection
        onSelectionChanged(selected)
        syncCollectionSelection()
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
/// name, `@handle` underneath — plus the applied-state mark, a mute glyph
/// when the account is muted, and the system reorder handle in edit mode
/// (Active section only).
///
/// Active rows carry a selection circle permanently — empty, or filled and
/// blue — so every row states both what it is and that it can be switched on.
/// There is no mode to enter and nothing appears or disappears mid-session,
/// which is what keeps the list from reflowing under the viewer's thumb.
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
        // The selection circle is the SYSTEM multiselect accessory, driven by
        // the cell's own `isSelected`, not a custom image view. A custom view
        // in the accessory area ghosted and doubled while a swipe translated
        // the row — UIKit lays its own accessories out through the swipe, a
        // hosted view has to be told, and there is no will-begin-swipe hook
        // on a collection-view list to tell it with.
        //
        // Editing is about membership and order; the circle would be a third
        // meaning competing with the ⊖/⊕ and the grabber.
        if isInActiveSection, !state.isEditing {
            accessories.append(.multiselect(displayed: .always))
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
