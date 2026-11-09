import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A group's info screen (#2214), pushed from its thread's header: the
/// group (photo, name, description, member count), what the viewer may do
/// with it (add members, mute), its members with their roles, and Leave.
///
/// Every rule — who edits, who manages whom, whether the owner may leave —
/// is the view model's; this draws what it is told. A member's row opens
/// their profile; its "⋯" (owner and admins only) offers what the viewer
/// may do to them.
final class GroupInfoViewController: UIViewController {
    private enum Section: Hashable {
        case group
        case actions
        case members
        case leave
    }

    private enum Item: Hashable {
        case identity
        case addMembers
        case mute
        case member(ProfileID)
        case leave
    }

    private let viewModel: GroupInfoViewModel
    private let imagePipeline: ImagePipeline?

    /// A member's row was tapped: their profile, with the name shown.
    var onOpenProfile: ((ProfileID, String) -> Void)?
    /// "Add members": the host presents the picker over `presenter`, and
    /// hands back who was picked.
    var onAddMembers: ((_ presenter: UIViewController, _ excluded: Set<ProfileID>, _ memberCount: Int,
                        _ completion: @escaping ([ProfileID]) -> Void) -> Void)?
    /// The viewer left: the host takes them back to the inbox.
    var onLeft: (() -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let statusView = InboxStatusView()
    private var state = GroupInfoViewModel.State()

    init(viewModel: GroupInfoViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = "Group Info"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureList()
        statusView.isHidden = true
        statusView.pin(to: view, relativeTo: .safeArea)
        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        viewModel.onNotice = { [weak self] title, message in self?.presentNotice(title, message) }
        viewModel.onFailure = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        viewModel.onLeft = { [weak self] in self?.onLeft?() }
        render(viewModel.state)
        viewModel.load()
    }

    // MARK: - The list

    private func configureList() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var section = configuration
            // Only Members is titled.
            let isMembers = self?.dataSource?.sectionIdentifier(for: index) == .members
            section.headerMode = isMembers ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: section, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        // A titled screen: the soft edge under its bar (#1591).
        collectionView.applyTopEdge(for: .titled)
        collectionView.pin(to: view)

        let identityCell = UICollectionView.CellRegistration<GroupIdentityCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(with: self.state, pipeline: self.imagePipeline)
            cell.onEdit = self.state.canEdit ? { [weak self] in self?.presentEditor() } : nil
        }
        let actionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = cell.defaultContentConfiguration()
            cell.accessories = []
            switch item {
            case .addMembers:
                content.text = "Add Members"
                content.image = UIImage(systemName: "person.badge.plus")
                content.textProperties.color = .tintColor
            case .mute:
                content.text = "Mute Notifications"
                content.image = UIImage(systemName: self.state.isMuted ? "bell.slash" : "bell")
                let toggle = UISwitch()
                toggle.isOn = self.state.isMuted
                toggle.accessibilityLabel = "Mute notifications"
                toggle.addAction(UIAction { [weak self] _ in self?.viewModel.toggleMute() }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            case .leave:
                content.text = "Leave Group"
                content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
                content.textProperties.color = .systemRed
                content.imageProperties.tintColor = .systemRed
            default:
                break
            }
            cell.contentConfiguration = content
        }
        let memberCell = UICollectionView.CellRegistration<PersonListCell, ProfileID> { [weak self] cell, _, id in
            guard let self, let row = self.state.members.first(where: { $0.id == id }) else { return }
            self.configure(cell, with: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = "Members"
            content.secondaryText = self?.state.subtitle
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, item in
            switch item {
            case .identity:
                collectionView.dequeueConfiguredReusableCell(using: identityCell, for: path, item: item)
            case .member(let id):
                collectionView.dequeueConfiguredReusableCell(using: memberCell, for: path, item: id)
            default:
                collectionView.dequeueConfiguredReusableCell(using: actionCell, for: path, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, path in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
    }

    private func configure(_ cell: PersonListCell, with row: GroupInfoViewModel.MemberRow) {
        let second = [row.roleLabel, row.handle.map { "@\($0)" }].compactMap(\.self).joined(separator: " · ")
        cell.configure(with: PersonRowContent(
            displayName: row.name, handle: second,
            monogram: MonogramAvatarView.monogram(name: row.name, handle: row.handle ?? "")
        ))
        cell.avatar.setPicture(row.avatarURL, pipeline: imagePipeline)
        guard !row.actions.isEmpty else { return }
        let more = AppIconButton(style: .glyph, content: .symbol("ellipsis"))
        more.inkColor = .secondaryLabel
        more.accessibilityLabel = "Manage \(row.name)"
        let id = row.id
        more.addAction(UIAction { [weak self, weak more] _ in self?.presentMemberMenu(id, from: more) }, for: .primaryActionTriggered)
        cell.accessories.append(.customView(configuration: .init(
            customView: more, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual
        )))
    }

    // MARK: - Render

    private func render(_ next: GroupInfoViewModel.State) {
        guard isViewLoaded else { return }
        let previous = state
        state = next
        switch next.phase {
        case .loading:
            statusView.isHidden = true
            return
        case .failed(let message):
            statusView.configure(
                symbol: "exclamationmark.triangle", title: "Something went wrong", message: message,
                actionTitle: "Try Again", action: { [weak self] in self?.viewModel.load() }
            )
            statusView.isHidden = false
            return
        case .loaded:
            statusView.isHidden = true
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.group, .actions, .members, .leave])
        snapshot.appendItems([.identity], toSection: .group)
        snapshot.appendItems((next.canAddMembers ? [.addMembers] : []) + [.mute], toSection: .actions)
        snapshot.appendItems(next.members.map { .member($0.id) }, toSection: .members)
        snapshot.appendItems([.leave], toSection: .leave)
        // What changed in place: the group's identity, the mute, each member
        // whose row changed (a role, a name).
        var stale: [Item] = []
        if previous.name != next.name || previous.description != next.description || previous.photoURL != next.photoURL
            || previous.memberCount != next.memberCount || previous.canEdit != next.canEdit {
            stale.append(.identity)
        }
        if previous.isMuted != next.isMuted { stale.append(.mute) }
        let before = Dictionary(previous.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stale += next.members.filter { before[$0.id] != nil && before[$0.id] != $0 }.map { .member($0.id) }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(stale.filter { existing.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !existing.isEmpty)
    }

    // MARK: - Actions

    private func presentMemberMenu(_ id: ProfileID, from source: UIView?) {
        guard let row = state.members.first(where: { $0.id == id }), !row.actions.isEmpty else { return }
        let sheet = UIAlertController(title: row.name, message: nil, preferredStyle: .actionSheet)
        for action in row.actions {
            sheet.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) {
                [weak self] _ in self?.confirm(action, on: row)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    /// Handing the group over, removing and banning are asked twice.
    private func confirm(_ action: GroupInfoViewModel.MemberAction, on row: GroupInfoViewModel.MemberRow) {
        let question: (title: String, message: String, button: String)? = switch action {
        case .transferOwnership:
            ("Make \(row.name) the owner?", "You'll become an admin. Only the owner can hand the group over.", "Make Owner")
        case .remove:
            ("Remove \(row.name)?", "They can be invited again later.", "Remove")
        case .ban:
            ("Remove and ban \(row.name)?", "They won't be able to join again.", "Remove and Ban")
        case .makeAdmin, .removeAdmin:
            nil
        }
        guard let question else { return viewModel.perform(action, on: row.id) }
        let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: question.button, style: action == .transferOwnership ? .default : .destructive) {
            [weak self] _ in self?.viewModel.perform(action, on: row.id)
        })
        present(alert, animated: true)
    }

    /// The name and the description, in one alert — owner and admins.
    private func presentEditor() {
        let alert = UIAlertController(title: "Edit Group", message: nil, preferredStyle: .alert)
        alert.addTextField { [state] field in
            field.placeholder = "Group name"
            field.text = state.ownName
            field.autocapitalizationType = .sentences
        }
        alert.addTextField { [state] field in
            field.placeholder = "Description"
            field.text = state.description
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let fields = alert?.textFields ?? []
            self?.viewModel.editIdentity(name: fields.first?.text ?? "", description: fields.last?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func confirmLeave() {
        if GroupInfoViewModel.leaveBlockedReason(for: state.viewerRole) != nil { return viewModel.leave() }
        let alert = UIAlertController(
            title: "Leave \(state.name)?", message: "You won't get its messages any more.", preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.viewModel.leave() })
        present(alert, animated: true)
    }

    private func presentNotice(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension GroupInfoViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .addMembers, .leave, .member: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .member(let id):
            guard let row = state.members.first(where: { $0.id == id }), !row.isViewer else { return }
            onOpenProfile?(id, row.name)
        case .addMembers:
            onAddMembers?(self, viewModel.memberIDs, state.memberCount) { [weak self] ids in self?.viewModel.add(ids) }
        case .leave:
            confirmLeave()
        default:
            break
        }
    }

    /// A member's menu on a long press too, for owner and admins.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, case .member(let id) = dataSource.itemIdentifier(for: path),
              let row = state.members.first(where: { $0.id == id }), !row.actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: row.actions.map { action in
                UIAction(title: action.title, attributes: action.isDestructive ? .destructive : []) { [weak self] _ in
                    self?.confirm(action, on: row)
                }
            })
        })
    }
}

/// The group at the top of its info screen (#2214): its photo — or its
/// initials, no photo picked yet — its name, how many are in it, and its
/// description; "Edit" for owner and admins.
final class GroupIdentityCell: UICollectionViewListCell {
    private let photo = AvatarView(diameter: GroupNameViewController.discDiameter, size: .px256)
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let editButton = AppButton(aspect: .pill(.quiet), size: .row, content: .title("Edit"))
    var onEdit: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.font = .appFont(forTextStyle: .title2)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        countLabel.font = .appFont(forTextStyle: .subheadline)
        countLabel.textColor = .secondaryLabel
        descriptionLabel.font = .appFont(forTextStyle: .body)
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0
        for label in [nameLabel, countLabel, descriptionLabel] { label.adjustsFontForContentSizeCategory = true }
        editButton.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [photo, nameLabel, countLabel, descriptionLabel, editButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.setCustomSpacing(Spacing.md, after: photo)
        stack.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.lg, leading: Spacing.lg, bottom: Spacing.lg, trailing: Spacing.lg
        ))
        backgroundConfiguration = .clear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with state: GroupInfoViewModel.State, pipeline: ImagePipeline?) {
        nameLabel.text = state.name
        countLabel.text = state.subtitle
        descriptionLabel.text = state.description
        descriptionLabel.isHidden = state.description.isEmpty
        editButton.isHidden = !state.canEdit
        photo.setMonogram(MonogramAvatarView.monogram(name: state.name, handle: ""))
        photo.setPicture(state.photoURL, pipeline: pipeline)
        accessibilityLabel = [state.name, state.subtitle, state.description].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
