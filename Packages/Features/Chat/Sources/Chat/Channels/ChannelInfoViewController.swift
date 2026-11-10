import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import UIKit

/// A channel's info screen (#2215), pushed from its thread's header: the
/// channel (photo, name, subscriber count, who may join, description), what
/// the viewer may do with it — share it as a post, invite people, change who
/// may join, answer join requests, mute — its admins, its subscribers (owner
/// and admins), and Leave.
///
/// Every rule is the view model's; this draws what it is told. A person's
/// row opens their profile; its "⋯" (owner and admins) offers what the
/// viewer may do to them.
final class ChannelInfoViewController: UIViewController {
    private enum Section: Hashable {
        case channel
        case actions
        case admins
        case subscribers
        case leave
    }

    private enum Item: Hashable {
        case identity
        case shareAsPost
        case invite
        case visibility
        case requests
        case mute
        case addAdmin
        case person(ProfileID)
        case leave
    }

    private let viewModel: ChannelInfoViewModel
    private let imagePipeline: ImagePipeline?

    /// A person's row: their profile, with the name shown.
    var onOpenProfile: ((ProfileID, String) -> Void)?
    /// "Join Requests": the host pushes the channel's requests list from
    /// `presenter`, and calls `changed` when some were answered.
    var onOpenRequests: ((_ presenter: UIViewController, _ changed: @escaping @MainActor () -> Void) -> Void)?
    /// The viewer left: the host takes them back.
    var onLeft: (() -> Void)?
    /// "Share as a Post" (#2216): the host opens the Text Post screen with
    /// the channel's card (`AppRoute.composeShowcase`).
    var onShareAsPost: ((PostEmbed) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let statusView = InboxStatusView()
    private var state = ChannelInfoViewModel.State()

    init(viewModel: ChannelInfoViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = "Channel Info"
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
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var section = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            let identifier = self?.dataSource?.sectionIdentifier(for: index)
            section.headerMode = identifier == .admins || identifier == .subscribers ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: section, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.applyTopEdge(for: .titled)
        collectionView.pin(to: view)

        let identityCell = UICollectionView.CellRegistration<ChannelIdentityCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(with: self.state, pipeline: self.imagePipeline)
            cell.onEdit = self.state.canEdit ? { [weak self] in self?.presentEditor() } : nil
        }
        let actionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            self.configureAction(cell, item)
        }
        let personCell = UICollectionView.CellRegistration<PersonListCell, ProfileID> { [weak self] cell, _, id in
            guard let self, let row = (self.state.admins + self.state.subscribers).first(where: { $0.id == id }) else { return }
            self.configure(cell, with: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, path in
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            if self.dataSource.sectionIdentifier(for: path.section) == .admins {
                content.text = "Admins"
            } else {
                content.text = "Subscribers"
                content.secondaryText = self.state.subtitle
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, item in
            switch item {
            case .identity:
                collectionView.dequeueConfiguredReusableCell(using: identityCell, for: path, item: item)
            case .person(let id):
                collectionView.dequeueConfiguredReusableCell(using: personCell, for: path, item: id)
            default:
                collectionView.dequeueConfiguredReusableCell(using: actionCell, for: path, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, path in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
    }

    private func configureAction(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .shareAsPost:
            content.text = ChannelShowcase.shareTitle
            content.image = UIImage(systemName: ChannelShowcase.shareSymbol)
            content.textProperties.color = .tintColor
        case .invite:
            content.text = "Invite People"
            content.image = UIImage(systemName: "link")
            content.textProperties.color = .tintColor
        case .visibility:
            content.text = "Who Can Join"
            content.secondaryText = ChannelCopy.visibilityTitle(state.visibility)
            content.image = UIImage(systemName: state.visibility == .public ? "globe" : "hand.raised")
            content.prefersSideBySideTextAndSecondaryText = true
            cell.accessories = [.popUpMenu(visibilityMenu(), displayed: .always)]
        case .requests:
            content.text = "Join Requests"
            content.secondaryText = state.requestCount > 0 ? "\(state.requestCount)" : "None"
            content.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
            content.prefersSideBySideTextAndSecondaryText = true
            cell.accessories = [.disclosureIndicator()]
        case .mute:
            content.text = "Mute Notifications"
            content.image = UIImage(systemName: state.isMuted ? "bell.slash" : "bell")
            let toggle = UISwitch()
            toggle.isOn = state.isMuted
            toggle.accessibilityLabel = "Mute notifications"
            toggle.addAction(UIAction { [weak self] _ in self?.viewModel.toggleMute() }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        case .addAdmin:
            content.text = "Add Admin"
            content.image = UIImage(systemName: "person.badge.plus")
            content.textProperties.color = .tintColor
        case .leave:
            content.text = "Leave Channel"
            content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
        case .identity, .person:
            break
        }
        cell.contentConfiguration = content
    }

    private func visibilityMenu() -> UIMenu {
        UIMenu(children: ChannelCopy.choosableVisibilities.map { choice in
            UIAction(
                title: ChannelCopy.visibilityTitle(choice), subtitle: ChannelCopy.visibilityExplanation(choice),
                state: choice == state.visibility ? .on : .off
            ) { [weak self] _ in self?.viewModel.setVisibility(choice) }
        })
    }

    private func configure(_ cell: PersonListCell, with row: ChannelInfoViewModel.MemberRow) {
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

    private func render(_ next: ChannelInfoViewModel.State) {
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
        snapshot.appendSections([.channel, .actions])
        snapshot.appendItems([.identity], toSection: .channel)
        var actions: [Item] = []
        // "Share as a Post" (#2216): owner and admins of a public or
        // on-request channel — a private one can't be shown.
        if next.canShareAsPost { actions += [.shareAsPost] }
        actions += [.invite]
        if next.canEdit { actions += [.visibility, .requests] }
        if next.isIn { actions += [.mute] }
        snapshot.appendItems(actions, toSection: .actions)
        if !next.admins.isEmpty || next.canManageAdmins {
            snapshot.appendSections([.admins])
            snapshot.appendItems(next.admins.map { .person($0.id) } + (next.canManageAdmins ? [.addAdmin] : []), toSection: .admins)
        }
        if next.canEdit {
            snapshot.appendSections([.subscribers])
            snapshot.appendItems(next.subscribers.map { .person($0.id) }, toSection: .subscribers)
        }
        if next.isIn {
            snapshot.appendSections([.leave])
            snapshot.appendItems([.leave], toSection: .leave)
        }
        var stale: [Item] = []
        if previous.name != next.name || previous.description != next.description || previous.photoURL != next.photoURL
            || previous.subscriberCount != next.subscriberCount || previous.canEdit != next.canEdit
            || previous.visibility != next.visibility {
            stale += [.identity, .visibility]
        }
        if previous.isMuted != next.isMuted { stale.append(.mute) }
        if previous.requestCount != next.requestCount { stale.append(.requests) }
        let before = Dictionary((previous.admins + previous.subscribers).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stale += (next.admins + next.subscribers).filter { before[$0.id] != nil && before[$0.id] != $0 }.map { .person($0.id) }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let shown = Set(snapshot.itemIdentifiers)
        snapshot.reconfigureItems(stale.filter { existing.contains($0) && shown.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !existing.isEmpty)
    }

    // MARK: - Actions

    private func presentMemberMenu(_ id: ProfileID, from source: UIView?) {
        guard let row = (state.admins + state.subscribers).first(where: { $0.id == id }), !row.actions.isEmpty else { return }
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

    /// Handing the channel over, removing and banning are asked twice.
    private func confirm(_ action: ChannelInfoViewModel.MemberAction, on row: ChannelInfoViewModel.MemberRow) {
        let question: (title: String, message: String, button: String)? = switch action {
        case .transferOwnership:
            ("Make \(row.name) the owner?", "You'll become an admin. Only the owner can hand the channel over.", "Make Owner")
        case .remove:
            ("Remove \(row.name)?", "They can join again later.", "Remove")
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

    /// "Add Admin": the owner picks among the subscribers.
    private func presentAdminPicker(from source: UIView?) {
        let candidates = state.subscribers.filter { $0.actions.contains(.makeAdmin) }
        guard !candidates.isEmpty else {
            return presentNotice("No one to add yet", "Admins are chosen among the channel's subscribers.")
        }
        let sheet = UIAlertController(title: "Add Admin", message: "Admins post and answer join requests.", preferredStyle: .actionSheet)
        for row in candidates {
            sheet.addAction(UIAlertAction(title: row.name, style: .default) { [weak self] _ in
                self?.viewModel.perform(.makeAdmin, on: row.id)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    /// The name and the description, in one alert — owner and admins.
    private func presentEditor() {
        let alert = UIAlertController(title: "Edit Channel", message: nil, preferredStyle: .alert)
        alert.addTextField { [state] field in
            field.placeholder = "Channel name"
            field.text = state.name
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

    /// The channel's link (`AppRoute.conversationLink`), through the share
    /// sheet: opened, it lands in the channel, which offers to join.
    private func presentInvite(from source: UIView?) {
        guard let link = AppRoute.conversationLink(viewModel.conversationID) else { return }
        let share = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source ?? view
        present(share, animated: true)
    }

    private func confirmLeave() {
        if ChannelCopy.leaveBlockedReason(for: state.viewerRole) != nil { return viewModel.leave() }
        let alert = UIAlertController(
            title: ChannelCopy.leaveTitle(state.name), message: ChannelCopy.leaveMessage, preferredStyle: .alert
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

extension ChannelInfoViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .shareAsPost, .invite, .requests, .addAdmin, .leave, .person: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let source = collectionView.cellForItem(at: indexPath)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .person(let id):
            guard let row = (state.admins + state.subscribers).first(where: { $0.id == id }), !row.isViewer else { return }
            onOpenProfile?(id, row.name)
        case .shareAsPost:
            // The Text Post screen, the channel's card attached (#2216).
            guard let embed = viewModel.showcaseEmbed else { return }
            onShareAsPost?(embed)
        case .invite:
            presentInvite(from: source)
        case .requests:
            onOpenRequests?(self) { [weak self] in self?.viewModel.requestsChanged() }
        case .addAdmin:
            presentAdminPicker(from: source)
        case .leave:
            confirmLeave()
        default:
            break
        }
    }

    /// A person's menu on a long press too, for owner and admins.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, case .person(let id) = dataSource.itemIdentifier(for: path),
              let row = (state.admins + state.subscribers).first(where: { $0.id == id }), !row.actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: row.actions.map { action in
                UIAction(title: action.title, attributes: action.isDestructive ? .destructive : []) { _ in
                    self?.confirm(action, on: row)
                }
            })
        })
    }
}

#if DEBUG
extension ChannelInfoViewController {
    /// Whether the list offers "Share as a Post" now (#2216).
    var debugOffersShareAsPost: Bool { dataSource?.snapshot().itemIdentifiers.contains(.shareAsPost) == true }
    /// A tap on "Share as a Post", as the row's selection does.
    func debugShareAsPost() {
        guard let embed = viewModel.showcaseEmbed else { return }
        onShareAsPost?(embed)
    }
}
#endif

// MARK: - How it is left (#1144)

extension ChannelInfoViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

/// The channel at the top of its info screen (#2215): its photo — or its
/// initials — its name, its subscriber count, who may join, and its
/// description; "Edit" for owner and admins.
final class ChannelIdentityCell: UICollectionViewListCell {
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
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 0
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

    func configure(with state: ChannelInfoViewModel.State, pipeline: ImagePipeline?) {
        nameLabel.text = state.name
        countLabel.text = "\(state.subtitle) · \(ChannelCopy.visibilityTitle(state.visibility))"
        descriptionLabel.text = state.description
        descriptionLabel.isHidden = state.description.isEmpty
        editButton.isHidden = !state.canEdit
        photo.setMonogram(MonogramAvatarView.monogram(name: state.name, handle: ""))
        photo.setPicture(state.photoURL, pipeline: pipeline)
        accessibilityLabel = [state.name, countLabel.text ?? "", state.description].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
