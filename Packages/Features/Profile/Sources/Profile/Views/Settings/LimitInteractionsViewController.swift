import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Limits (#416, backend #735, #736):
/// a temporary limit that holds comments and messages from an audience for
/// review, and whether others may reuse this profile's original sounds.
/// Not optimistic.
final class LimitInteractionsViewController: UIViewController {
    struct State: Equatable {
        var limit: InteractionLimit?
        var allowsSoundReuse: Bool
    }

    enum Phase: Equatable {
        case loading
        case loaded(State)
        case failed
    }

    enum Section: Hashable {
        case limit, audience, sounds
    }

    private enum Item: Hashable {
        case limitSwitch
        case audience(InteractionLimitAudience)
        case duration
        case soundReuse
        case loading
        case failed
    }

    private let manager: any InteractionLimitsManaging
    private let now: () -> Date
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    private var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any InteractionLimitsManaging, now: @escaping () -> Date = Date.init) {
        self.manager = manager
        self.now = now
        super.init(nibName: nil, bundle: nil)
        title = "Limits"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        load()
    }

    private func load() {
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                async let limit = manager.interactionLimit()
                async let sounds = manager.allowsSoundReuse()
                phase = .loaded(State(limit: try await limit, allowsSoundReuse: try await sounds))
            } catch {
                loadFailure = NetworkFailure.of(error)
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    private static let untilFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func durationTitle(days: Int) -> String {
        switch days {
        case 1: "1 Day"
        case 7: "1 Week"
        case 14: "2 Weeks"
        case 28: "4 Weeks"
        default: "\(days) Days"
        }
    }

    static func header(_ section: Section) -> String? {
        switch section {
        case .limit: nil
        case .audience: "Hold Comments and Messages From"
        case .sounds: "Your Sounds"
        }
    }

    func footer(_ section: Section) -> String? {
        switch section {
        case .limit:
            if case .loaded(let state) = phase, let limit = state.limit {
                return "On until \(Self.untilFormatter.string(from: limit.until)). Held comments are seen only by you and the people who wrote them, who aren't told."
            }
            return "For when you're getting unwanted attention: for up to 4 weeks, comments and messages from the people you choose are held, seen only by you and the people who wrote them."
        case .audience:
            return nil
        case .sounds:
            return "When this is off, no one else can post with an original sound from your posts."
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.cell()
            let state: State? = if case .loaded(let current) = phase { current } else { nil }
            switch item {
            case .limitSwitch:
                content.text = "Limit Interactions"
                content.image = UIImage(systemName: "hand.raised")
                content.imageProperties.tintColor = .label
                cell.accessories = [switchAccessory(isOn: state?.limit != nil) { [weak self] isOn in
                    self?.setLimitOn(isOn)
                }]
            case .audience(let audience):
                content.text = audience.title
                if state?.limit?.audience == audience { cell.accessories = [.checkmark()] }
            case .duration:
                content = .valueCell()
                content.text = "Until"
                content.secondaryText = state?.limit.map { Self.untilFormatter.string(from: $0.until) }
                let choices = InteractionLimit.durations.map { days in
                    UIAction(title: Self.durationTitle(days: days)) { [weak self] _ in self?.setDuration(days: days) }
                }
                cell.accessories = [.popUpMenu(UIMenu(children: choices), displayed: .always)]
            case .soundReuse:
                content.text = "Others Can Use Your Sounds"
                content.image = UIImage(systemName: "music.note")
                content.imageProperties.tintColor = .label
                cell.accessories = [switchAccessory(isOn: state?.allowsSoundReuse ?? true) { [weak self] isOn in
                    self?.setSoundReuse(isOn)
                }]
            case .loading:
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: loadFailure, fallback: "Couldn't load your limits. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.footer($0) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func switchAccessory(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = !isSaving
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.limit])
        switch phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .limit)
        case .failed:
            snapshot.appendItems([.failed], toSection: .limit)
        case .loaded(let state):
            snapshot.appendItems([.limitSwitch], toSection: .limit)
            if state.limit != nil {
                snapshot.appendSections([.audience])
                snapshot.appendItems(InteractionLimitAudience.allCases.map(Item.audience) + [.duration], toSection: .audience)
            }
            snapshot.appendSections([.sounds])
            snapshot.appendItems([.soundReuse], toSection: .sounds)
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Changes

    private func run(_ change: @escaping () async throws -> State) {
        guard !isSaving else { return }
        isSaving = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await change()
                isSaving = false
                phase = .loaded(next)
            } catch {
                isSaving = false
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't change your limits. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func until(days: Int) -> Date {
        now().addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// On: a week, from people who don't follow you; off: cleared.
    private func setLimitOn(_ isOn: Bool) {
        guard case .loaded(var state) = phase else { return }
        let manager = manager
        if isOn {
            let limit = InteractionLimit(audience: .nonFollowers, until: until(days: 7))
            run {
                try await manager.setInteractionLimit(limit)
                state.limit = limit
                return state
            }
        } else {
            run {
                try await manager.clearInteractionLimit()
                state.limit = nil
                return state
            }
        }
    }

    private func setAudience(_ audience: InteractionLimitAudience) {
        guard case .loaded(var state) = phase, var limit = state.limit, limit.audience != audience else { return }
        limit.audience = audience
        let manager = manager
        run {
            try await manager.setInteractionLimit(limit)
            state.limit = limit
            return state
        }
    }

    private func setDuration(days: Int) {
        guard case .loaded(var state) = phase, var limit = state.limit else { return }
        limit.until = until(days: days)
        let manager = manager
        run {
            try await manager.setInteractionLimit(limit)
            state.limit = limit
            return state
        }
    }

    private func setSoundReuse(_ allowed: Bool) {
        guard case .loaded(var state) = phase else { return }
        let manager = manager
        run {
            try await manager.setAllowsSoundReuse(allowed)
            state.allowsSoundReuse = allowed
            return state
        }
    }
}

extension LimitInteractionsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .audience, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .audience(let audience): setAudience(audience)
        case .failed: load()
        default: break
        }
    }
}
