import CoreModels
import UIKit

/// The inbox's search results: one sectioned list covering every category at
/// once, presented over the whole inbox while the field is active.
///
/// **Why a `searchResultsController` rather than filtering a page in place.**
/// The inbox is three horizontally paged surfaces under a tab capsule that
/// lives in the navigation bar. Narrowing one page would answer a global query
/// with a local list, and would leave the tabs on screen asserting a scope the
/// results don't have. A results controller is presented over the container's
/// whole view, so while search is active there is no page to swipe. That is the answer to
/// "which tab am I searching?": none of them, and the sections say where each
/// hit came from.
///
/// **The design is the compose picker's, deliberately.** Same glass
/// `SectionHeaderCapsuleView` pinned over the rows, same two-line person rows,
/// same `InboxStatusView` empty states. The two screens are one tap apart and
/// answer nearly the same question, so they should not look like two products.
final class InboxSearchResultsViewController: UIViewController {
    /// The diffable section identifier. The view model's own sections are
    /// wrapped rather than used directly so a status-only render still has a
    /// well-formed (empty) snapshot to apply.
    private typealias Section = InboxSearchViewModel.SectionKind
    private typealias Row = InboxSearchViewModel.Row

    private let viewModel: InboxSearchViewModel

    private var collectionView: UICollectionView!
    private let statusView = InboxStatusView()

    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var visibleSections: [Section] = []
    private var sectionTitles: [Section: String] = [:]
    private var hasRenderedContent = false

    /// Fired the instant a row is picked, BEFORE the route is emitted.
    ///
    /// The container uses it to collapse the search field: this controller is
    /// *presented* over the inbox, so a thread pushed while it is still up would
    /// arrive underneath it. Ordering matters and belongs to the owner, which is
    /// why this is a hook rather than something done here.
    var onWillOpenResult: (() -> Void)?

    init(viewModel: InboxSearchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Opaque, not clear: this view covers a live inbox, and anything showing
        // through would collide with the results at full contrast.
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureStatusView()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        render(.prompt)
    }

    // MARK: - Setup

    private func configureCollectionView() {
        // Built per section rather than from one list configuration: every
        // section here carries a header, but the FIRST one must lose its top
        // padding — that padding separates a section from the rows above it, and
        // at the top of the list there is nothing above to separate from.
        let layout = UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.headerMode = .supplementary
            if index == 0 { configuration.headerTopPadding = 0 }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        // The field lives in the navigation bar above, so a drag downward is
        // unambiguously "put the keyboard away and let me read".
        collectionView.keyboardDismissMode = .onDrag
        collectionView.pin(to: view)

        let conversationRegistration = UICollectionView.CellRegistration<
            ConversationResultCell, ConversationID
        > { [weak self] cell, _, id in
            guard let model = self?.viewModel.conversationModels[id] else { return }
            cell.configure(with: model)
        }

        let personRegistration = UICollectionView.CellRegistration<
            PersonListCell, ProfileID
        > { [weak self] cell, _, id in
            guard let model = self?.viewModel.peopleModels[id] else { return }
            cell.configure(with: model)
        }

        // A plain list pins its headers, so rows pass DIRECTLY under this one.
        // `SectionHeaderCapsuleView` carries its own glass and a clear
        // background, which is what lets the rows show through around it.
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderCapsuleView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            // Captured by SECTION, not by index path: the header is reused and
            // its index path is only valid for this configure pass, whereas the
            // section it names survives the snapshots that reshuffle rows
            // beneath it.
            let section = self?.visibleSections[safe: indexPath.section]
            header.setTitle(
                section.flatMap { self?.sectionTitles[$0] },
                leadsList: indexPath.section == 0
            )
            header.onTap = { [weak self] in
                guard let self, let section else { return }
                self.scrollToTop(of: section)
            }
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Row>(
            collectionView: collectionView
        ) { collectionView, indexPath, row in
            switch row {
            case .conversation(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: conversationRegistration, for: indexPath, item: id
                )
            case .person(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: personRegistration, for: indexPath, item: id
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configureStatusView() {
        statusView.isHidden = true
        // Bounded below by the KEYBOARD rather than the safe area: this screen
        // exists to be typed into, so the space actually left over is what the
        // message should be centred in — and riding the guide follows the
        // keyboard up and down for free. With it down the guide sits on the
        // bottom edge, which is the plain full-screen centring this wants at rest.
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: InboxSearchViewModel.Phase) {
        switch phase {
        case .prompt:
            apply([])
            showStatus(
                symbol: "magnifyingglass",
                title: "Search Messages",
                message: "Find a conversation, a request, or someone new by name or handle."
            )

        case .loading:
            // No skeleton: the local halves answer on the keystroke, so this is
            // only ever the brief window where a query has no local match and the
            // directory is still out. Bones there would flash a promise of rows
            // that usually never arrive.
            apply([])
            statusView.isHidden = true

        case .content(let sections):
            statusView.isHidden = true
            apply(sections)

        case .noResults(let query):
            apply([])
            showStatus(
                symbol: "magnifyingglass",
                title: "No Results",
                message: "Nothing matches “\(query)”."
            )

        case .failed(let message):
            apply([])
            showStatus(symbol: "exclamationmark.triangle", title: "Something went wrong", message: message)
        }
    }

    private func apply(_ sections: [InboxSearchViewModel.Section]) {
        visibleSections = sections.map(\.kind)
        sectionTitles = sections.reduce(into: [:]) { titles, section in
            titles[section.kind] = section.title
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for section in sections {
            snapshot.appendSections([section.kind])
            snapshot.appendItems(section.rows, toSection: section.kind)
        }
        // Animate only once there is something to animate FROM, and only while
        // on screen — an off-screen apply would replay its animation the next
        // time search is opened.
        dataSource.apply(snapshot, animatingDifferences: hasRenderedContent && view.window != nil)
        hasRenderedContent = true
    }

    /// Scrolls `section` up to just under the navigation bar.
    ///
    /// Offset arithmetic rather than `scrollToItem(at:.top)`: that puts the
    /// section's first ROW at the top, and the pinned header then sits squarely
    /// on it. What the viewer means by "take me to People" is the header.
    private func scrollToTop(of section: Section) {
        guard let index = visibleSections.firstIndex(of: section),
              collectionView.numberOfItems(inSection: index) > 0
        else { return }

        let first = IndexPath(item: 0, section: index)
        guard let row = collectionView.layoutAttributesForItem(at: first) else { return }
        let headerHeight = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: first
        )?.frame.height ?? 0

        let top = -collectionView.adjustedContentInset.top
        // The furthest the list can actually travel; without the clamp the last
        // section would rubber-band and settle back, which reads as the tap
        // having been ignored.
        let bottom = max(top, collectionView.contentSize.height
            + collectionView.adjustedContentInset.bottom
            - collectionView.bounds.height)
        let target = min(max(row.frame.minY - headerHeight + top, top), bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    private func showStatus(symbol: String, title: String, message: String) {
        // The list stays mounted and simply empty: it owns the keyboard's scroll
        // context, and tearing it down to show a message would take that with it.
        statusView.configure(symbol: symbol, title: title, message: message)
        statusView.isHidden = false
    }
}

extension InboxSearchResultsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        // Selection is disabled for the rest of this screen's life: the search UI
        // is coming down and a thread is going up, and a second tap landing in
        // that window would stack a second push.
        collectionView.allowsSelection = false
        onWillOpenResult?()
        viewModel.didSelect(row)
    }
}

extension InboxSearchResultsViewController: UISearchResultsUpdating {
    /// Every keystroke, plus the system's clear glyph and the cancel that
    /// collapses the field. The view model owns trimming and debouncing, so this
    /// stays a pass-through.
    func updateSearchResults(for searchController: UISearchController) {
        // Re-armed here rather than on appearance: this controller is presented
        // and dismissed by the search controller without ever being deallocated,
        // so a row disabled by a previous pick has to come back when the viewer
        // returns and types again.
        collectionView.allowsSelection = true
        viewModel.queryChanged(searchController.searchBar.text ?? "")
    }
}

private extension Array {
    /// Index-path bounds outlive the snapshot that produced them; a supplementary
    /// configure can land after a section has gone away.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
