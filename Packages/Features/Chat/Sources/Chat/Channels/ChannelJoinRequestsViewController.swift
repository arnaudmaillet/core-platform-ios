import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The join requests list (#2215): who asked to join the channels the
/// viewer runs, and when, each with Approve and Decline; the bar's menu
/// answers them all. One section per channel, each titled with its name.
final class ChannelJoinRequestsViewController: UIViewController {
    private let viewModel: ChannelJoinRequestsViewModel
    private let imagePipeline: ImagePipeline?

    /// A requester's row: their profile.
    var onOpenProfile: ((ProfileID, String) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ConversationID, ProfileID>!
    private let statusView = InboxStatusView()
    private var state = ChannelJoinRequestsViewModel.State()
    private lazy var allItem = UIBarButtonItem(title: "All", menu: allMenu())

    init(viewModel: ChannelJoinRequestsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = "Join Requests"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureList()
        statusView.isHidden = true
        statusView.pin(to: view, relativeTo: .safeArea)
        navigationItem.rightBarButtonItem = allItem
        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        viewModel.onFailure = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: self)
        }
        render(viewModel.state)
        viewModel.load()
    }

    private func allMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Approve All", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.confirmAll(approve: true)
            },
            UIAction(title: "Decline All", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                self?.confirmAll(approve: false)
            },
        ])
    }

    private func confirmAll(approve: Bool) {
        let count = state.count
        guard count > 0 else { return }
        let noun = count == 1 ? "1 request" : "\(count) requests"
        let alert = UIAlertController(
            title: approve ? "Approve \(noun)?" : "Decline \(noun)?",
            message: approve ? "They'll subscribe and see every post." : "They can ask again later.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: approve ? "Approve All" : "Decline All", style: approve ? .default : .destructive) {
            [weak self] _ in self?.viewModel.answerAll(approve: approve)
        })
        present(alert, animated: true)
    }

    // MARK: - The list

    private func configureList() {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var section = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            // Every section names its channel, a lone one too (the owner,
            // 2026-11-10): without it nothing on the screen said which
            // channel the requests were for.
            section.headerMode = (self?.state.groups.isEmpty ?? true) ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: section, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.applyTopEdge(for: .titled)
        collectionView.pin(to: view)

        let cell = UICollectionView.CellRegistration<PersonListCell, ChannelJoinRequestsViewModel.Row> { [weak self] cell, _, row in
            self?.configure(cell, with: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, path in
            var content = UIListContentConfiguration.header()
            content.text = self?.state.groups[safe: path.section]?.channel.name
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, path, id in
            guard let row = self?.state.groups[safe: path.section]?.rows.first(where: { $0.id == id }) else { return nil }
            return collectionView.dequeueConfiguredReusableCell(using: cell, for: path, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, path in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
    }

    private func configure(_ cell: PersonListCell, with row: ChannelJoinRequestsViewModel.Row) {
        let when = RelativeAgeFormatter.short(from: row.requestedAt, to: Date())
        let second = [row.handle.map { "@\($0)" }, when].compactMap(\.self).joined(separator: " · ")
        cell.configure(with: PersonRowContent(
            displayName: row.name, handle: second,
            monogram: MonogramAvatarView.monogram(name: row.name, handle: row.handle ?? "")
        ))
        cell.avatar.setPicture(row.avatarURL, pipeline: imagePipeline)
        let approve = Self.approveButton(for: row.name)
        let decline = AppIconButton(style: .glyph, content: .symbol("xmark"))
        decline.inkColor = .secondaryLabel
        decline.accessibilityLabel = "Decline \(row.name)"
        let id = row.id
        let channel = row.channelID
        approve.addAction(UIAction { [weak self] _ in
            self?.viewModel.answer(id, in: channel, approve: true)
        }, for: .primaryActionTriggered)
        decline.addAction(UIAction { [weak self] _ in
            self?.viewModel.answer(id, in: channel, approve: false)
        }, for: .primaryActionTriggered)
        cell.accessories = [
            .customView(configuration: .init(customView: approve, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
            .customView(configuration: .init(customView: decline, placement: .trailing(displayed: .always), reservedLayoutWidth: .actual)),
        ]
    }

    /// A request's Approve: the row action (#2231) — repeated on every
    /// request, so on the tinted ground, not a solid capsule. Internal for
    /// tests.
    static func approveButton(for name: String) -> AppButton {
        let approve = AppButton(aspect: .rowAction, size: .row, content: .title("Approve"))
        approve.accessibilityLabel = "Approve \(name)"
        return approve
    }

    // MARK: - Render

    private func render(_ next: ChannelJoinRequestsViewModel.State) {
        guard isViewLoaded else { return }
        let regrouped = (state.groups.count > 1) != (next.groups.count > 1)
        state = next
        allItem.isEnabled = !next.isEmpty && !next.isWorking
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
            statusView.configure(
                symbol: "person.crop.circle.badge.checkmark", title: "No requests",
                message: "When someone asks to join a channel you run, they wait here."
            )
            statusView.isHidden = !next.isEmpty || next.isWorking
        }
        var snapshot = NSDiffableDataSourceSnapshot<ConversationID, ProfileID>()
        for group in next.groups {
            snapshot.appendSections([group.channel.id])
            snapshot.appendItems(group.rows.map(\.id), toSection: group.channel.id)
        }
        if regrouped { collectionView.collectionViewLayout.invalidateLayout() }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }
}

extension ChannelJoinRequestsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = state.groups[safe: indexPath.section]?.rows[safe: indexPath.item] else { return }
        onOpenProfile?(row.id, row.name)
    }
}

// MARK: - How it is left (#1144)

extension ChannelJoinRequestsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
