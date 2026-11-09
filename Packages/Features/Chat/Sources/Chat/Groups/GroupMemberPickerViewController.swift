import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// Picks a group's people (#2214): a search field, the people picked as
/// chips under it — a chip's ✕ unpicks — and the people to pick below, the
/// inbox search's own rows with a check on the picked ones.
///
/// "Next" (or "Add", adding to a group) stays off until enough are picked;
/// past the backend's cap a toast says so. What happens next is the host's
/// (`onNext`): the name step, or the invitations.
final class GroupMemberPickerViewController: UIViewController {
    private let viewModel: GroupMemberPickerViewModel
    private let imagePipeline: ImagePipeline?
    private let avatars: (any PeerAvatarProviding)?
    private let nextTitle: String

    /// The picked people, in order, on "Next".
    var onNext: (([PersonDisplayModel]) -> Void)?
    /// The sheet's Cancel.
    var onCancel: (() -> Void)?

    private let searchField = UISearchTextField()
    private let chipsScroll = UIScrollView()
    private let chipsStack = UIStackView()
    private var chips: [ProfileID: AppButton] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, ProfileID>!
    private let statusView = InboxStatusView()
    private lazy var nextItem = UIBarButtonItem(
        title: nextTitle, style: .prominent, target: self, action: #selector(nextTapped)
    )
    private var avatarLookups: [ObjectIdentifier: (id: ProfileID, task: Task<Void, Never>)] = [:]

    init(
        viewModel: GroupMemberPickerViewModel,
        title: String,
        nextTitle: String,
        imagePipeline: ImagePipeline?,
        avatars: (any PeerAvatarProviding)?
    ) {
        self.viewModel = viewModel
        self.nextTitle = nextTitle
        self.imagePipeline = imagePipeline
        self.avatars = avatars
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel?() }
        )
        navigationItem.rightBarButtonItem = nextItem
        configureHeader()
        configureList()
        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        viewModel.onCapReached = { [weak self] message in
            guard let self else { return }
            Feedback.warning(message, from: self)
        }
        render(viewModel.state)
    }

    // MARK: - Layout

    private func configureHeader() {
        searchField.placeholder = "Search people"
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.addAction(UIAction { [weak self] _ in
            self?.viewModel.queryChanged(self?.searchField.text ?? "")
        }, for: .editingChanged)

        chipsStack.axis = .horizontal
        chipsStack.spacing = Spacing.sm
        chipsStack.alignment = .center
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.alwaysBounceHorizontal = true
        chipsStack.pin(to: chipsScroll)
        chipsStack.heightAnchor.constraint(equalTo: chipsScroll.frameLayoutGuide.heightAnchor).isActive = true
        chipsScroll.isHidden = true

        let header = UIStackView(arrangedSubviews: [searchField, chipsScroll])
        header.axis = .vertical
        header.spacing = Spacing.sm
        header.constrain(in: view) { parent in
            header.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
            header.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            header.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            chipsScroll.heightAnchor.constraint(equalToConstant: 44)
        }
        headerStack = header
    }

    /// The field and the chips, above the list.
    private var headerStack: UIStackView?

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.allowsMultipleSelection = false
        // A titled sheet: the soft edge under its bar (#1591).
        collectionView.applyTopEdge(for: .titled)
        collectionView.constrain(in: view) { parent in
            collectionView.topAnchor.constraint(equalTo: headerStack?.bottomAnchor ?? parent.safeAreaLayoutGuide.topAnchor,
                                                constant: Spacing.sm)
            collectionView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            collectionView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            collectionView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        statusView.isHidden = true
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: collectionView.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }

        let personCell = UICollectionView.CellRegistration<PersonListCell, ProfileID> { [weak self] cell, _, id in
            guard let self, let person = self.viewModel.people[id] else { return }
            cell.configure(with: person.rowContent)
            // The check on a picked person: shown or not, the row keeps its width.
            cell.accessories.append(.checkmark(displayed: .always, options: .init(isHidden: !self.viewModel.isSelected(id))))
            cell.accessibilityTraits = self.viewModel.isSelected(id) ? [.button, .selected] : .button
            self.lookUpAvatar(of: id, into: cell)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderCapsuleView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            view.setTitle(self?.dataSource.sectionIdentifier(for: indexPath.section))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: personCell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    // MARK: - Render

    private var renderedSelection: [ProfileID] = []

    private func render(_ state: GroupMemberPickerViewModel.State) {
        guard isViewLoaded else { return }
        nextItem.isEnabled = state.canContinue
        var snapshot = NSDiffableDataSourceSnapshot<String, ProfileID>()
        for section in state.sections {
            // A person in two sections is listed once, in the first.
            let rows = section.rows.filter { snapshot.indexOfItem($0) == nil }
            guard !rows.isEmpty else { continue }
            snapshot.appendSections([section.title])
            snapshot.appendItems(rows, toSection: section.title)
        }
        // The checks follow the picks.
        let toggled = Set(state.selected).symmetricDifference(renderedSelection)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { toggled.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        renderChips(state.selected)
        renderedSelection = state.selected
        if state.showsNoResults {
            statusView.configure(symbol: "magnifyingglass", title: "No Results", message: "No one matches that name.")
            statusView.isHidden = false
        } else {
            statusView.isHidden = true
        }
    }

    /// One chip per picked person, in the order picked; the newest scrolled
    /// into view.
    private func renderChips(_ selected: [ProfileID]) {
        for (id, chip) in chips where !selected.contains(id) {
            chip.removeFromSuperview()
            chips[id] = nil
        }
        var added = false
        for id in selected where chips[id] == nil {
            guard let person = viewModel.people[id] else { continue }
            let chip = AppButton(
                aspect: .pill(.quiet), size: .row,
                content: AppButton.Content(
                    title: ChatProfile.firstName(of: person.displayName, handle: person.handle),
                    symbol: "xmark", imagePlacement: .trailing
                )
            )
            chip.accessibilityLabel = "Remove \(person.displayName)"
            chip.addAction(UIAction { [weak self] _ in self?.viewModel.remove(id) }, for: .primaryActionTriggered)
            chipsStack.addArrangedSubview(chip)
            chips[id] = chip
            added = true
        }
        // Arranged in the order picked.
        for (index, id) in selected.enumerated() {
            if let chip = chips[id], chipsStack.arrangedSubviews.firstIndex(of: chip) != index {
                chipsStack.insertArrangedSubview(chip, at: index)
            }
        }
        chipsScroll.isHidden = selected.isEmpty
        guard added else { return }
        chipsScroll.layoutIfNeeded()
        let end = max(0, chipsScroll.contentSize.width - chipsScroll.bounds.width)
        chipsScroll.setContentOffset(CGPoint(x: end, y: 0), animated: view.window != nil)
    }

    @objc private func nextTapped() {
        guard viewModel.state.canContinue else { return }
        onNext?(viewModel.selectedPeople)
    }

    /// The row's face: the skeleton while profile.v1 is asked, then the
    /// picture — the search results' own lookup.
    private func lookUpAvatar(of id: ProfileID, into cell: PersonListCell) {
        let key = ObjectIdentifier(cell)
        if avatarLookups[key]?.id == id { return }
        avatarLookups[key]?.task.cancel()
        guard let avatars, let imagePipeline else {
            avatarLookups[key] = nil
            cell.avatar.setPicture(nil, pipeline: nil)
            return
        }
        cell.avatar.awaitPicture()
        let task = Task { [weak self, weak cell] in
            let urls = await avatars.avatarURLs(for: [id])
            guard !Task.isCancelled, let self, let cell, self.avatarLookups[key]?.id == id else { return }
            cell.avatar.setPicture(urls[id], pipeline: imagePipeline)
        }
        avatarLookups[key] = (id, task)
    }

    #if DEBUG
    /// The chips on show, in order. Tests.
    var debugChipCount: Int { chipsStack.arrangedSubviews.count }
    /// Whether "Next" is on. Tests.
    var debugCanContinue: Bool { nextItem.isEnabled }
    #endif
}

extension GroupMemberPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.toggle(id)
    }
}
