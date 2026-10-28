import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Limits (#416, backend #735, #736):
/// a temporary limit that holds comments and messages from an audience for
/// review, and whether others may reuse this profile's original sounds.
/// Not optimistic: a change shows where the tap put it, with the loader
/// beside it, until the server holds it (#1775, `SettingSaves`).
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
        /// Past 10 s (#1770): a row a tap retries.
        case takingLonger
    }

    private let manager: any InteractionLimitsManaging
    private let now: () -> Date
    private var phase: Phase = .loading {
        didSet {
            // Every answer, a save's included, is the next visit's first
            // frame (#1776).
            if case .loaded(let value) = phase { settingsCache?.store(value, as: InteractionLimitsRecord.self, viewer: settingsWriter) }
            applySnapshot()
        }
    }
    /// The screen's last answer on the device (#1776): it opens on it, with
    /// no skeleton, then revalidates in place. Set by the builder.
    var settingsCache: SettingsLocalCache?
    /// The viewer the screen opened for: what its answers are stored as.
    private lazy var settingsWriter = settingsCache?.viewer
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    /// The limit on its way to the server (#1775): on, off, another audience
    /// or another end — one at a time.
    private lazy var limitSaves: SettingSaves<Section, InteractionLimit?> = {
        let saves = SettingSaves<Section, InteractionLimit?>()
        saves.onChange = { [weak self] in self?.applySnapshot() }
        return saves
    }()
    /// The sounds' switch on its way.
    private lazy var soundSaves: SettingSaves<Section, Bool> = {
        let saves = SettingSaves<Section, Bool>()
        saves.onChange = { [weak self] in self?.applySnapshot() }
        return saves
    }()
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
        // ⚠️ CACHE FIRST (#1776, the rule of #1756): what the server last said
        // is the first frame; the read below revalidates it in place.
        if case .loaded = phase {
        } else if let stored = settingsCache?.value(InteractionLimitsRecord.self) {
            phase = .loaded(stored)
        } else {
            phase = .loading
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                async let limit = manager.interactionLimit()
                async let sounds = manager.allowsSoundReuse()
                phase = .loaded(State(limit: try await limit, allowsSoundReuse: try await sounds))
            } catch {
                loadFailure = NetworkFailure.of(error)
                // A failed revalidation keeps the answer on screen.
                if case .loaded = phase { return }
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
            let saved: State? = if case .loaded(let current) = phase { current } else { nil }
            // What the rows show: the changes on their way over the server's
            // record; a row whose change travels wears the loader (#1775).
            let state = shown(saved)
            switch item {
            case .limitSwitch:
                content.text = "Limit Interactions"
                content.image = UIImage(systemName: "hand.raised")
                content.imageProperties.tintColor = .label
                let control = switchAccessory(isOn: state?.limit != nil, isSaving: limitSaves.isSaving(.limit)) { [weak self] isOn in
                    self?.setLimitOn(isOn)
                }
                let travels = (state?.limit != nil) != (saved?.limit != nil)
                cell.accessories = travels ? [.busy(), control] : [control]
            case .audience(let audience):
                content.text = audience.title
                if state?.limit?.audience == audience {
                    let travels = saved?.limit != nil && saved?.limit?.audience != audience
                    cell.accessories = travels ? [.busy(), .checkmark()] : [.checkmark()]
                }
            case .duration:
                content = .valueCell()
                content.text = "Until"
                content.secondaryText = state?.limit.map { Self.untilFormatter.string(from: $0.until) }
                let choices = InteractionLimit.durations.map { days in
                    UIAction(title: Self.durationTitle(days: days)) { [weak self] _ in self?.setDuration(days: days) }
                }
                let menu = UICellAccessory.popUpMenu(UIMenu(children: choices), displayed: .always)
                let travels = saved?.limit != nil && saved?.limit?.until != state?.limit?.until
                cell.accessories = travels ? [.busy(), menu] : [menu]
            case .soundReuse:
                content.text = "Others Can Use Your Sounds"
                content.image = UIImage(systemName: "music.note")
                content.imageProperties.tintColor = .label
                let control = switchAccessory(isOn: state?.allowsSoundReuse ?? true, isSaving: soundSaves.isSaving(.sounds)) { [weak self] isOn in
                    self?.setSoundReuse(isOn)
                }
                cell.accessories = soundSaves.isSaving(.sounds) ? [.busy(), control] : [control]
            case .loading:
                cell.contentConfiguration = SkeletonRowConfiguration(sample: "A row of this list")
                cell.accessories = []
                return
            case .takingLonger:
                content.text = TakingLongerCopy.row
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

    private func switchAccessory(isOn: Bool, isSaving: Bool, onChange: @escaping (Bool) -> Void) -> UICellAccessory {
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
            // The kit's timing (#1770): nothing for its delay, the bones,
            // "taking longer" past 10 s.
            switch loadingGate.loading() {
            case .bones: snapshot.appendItems([.loading], toSection: .limit)
            case .takingLonger: snapshot.appendItems([.takingLonger], toSection: .limit)
            case .nothing: break
            }
        case .failed:
            snapshot.appendItems([.failed], toSection: .limit)
        case .loaded(let saved):
            snapshot.appendItems([.limitSwitch], toSection: .limit)
            if shown(saved)?.limit != nil {
                snapshot.appendSections([.audience])
                snapshot.appendItems(InteractionLimitAudience.allCases.map(Item.audience) + [.duration], toSection: .audience)
            }
            snapshot.appendSections([.sounds])
            snapshot.appendItems([.soundReuse], toSection: .sounds)
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        let animated = false
        if case .loading = phase {
            dataSource.apply(snapshot, animatingDifferences: animated)
        } else {
            // The answer waits out the bones' minimum (#1770).
            loadingGate.landed { [weak self] in self?.dataSource.apply(snapshot, animatingDifferences: animated) }
        }
    }

    /// The settings' loading on the kit's timing (#1770). Injectable so a
    /// test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var loadingGate: ListSkeletonGate = {
        let gate = ListSkeletonGate(clock: skeletonClock)
        gate.onChange = { [weak self] in self?.applySnapshot() }
        return gate
    }()

    // MARK: - Changes

    /// The record as the rows show it: the changes on their way over it.
    private func shown(_ saved: State?) -> State? {
        guard var state = saved else { return nil }
        if let limit = limitSaves.value(for: .limit) { state.limit = limit }
        if let allowed = soundSaves.value(for: .sounds) { state.allowsSoundReuse = allowed }
        return state
    }

    private func failed() {
        let alert = UIAlertController(title: nil, message: "Couldn't change your limits. Try again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Saves `limit` — nil clears it — and takes it into the record.
    private func save(_ limit: InteractionLimit?) {
        guard case .loaded = phase else { return }
        let manager = manager
        limitSaves.save(limit, for: .limit, { [weak self] limit in
            if let limit {
                try await manager.setInteractionLimit(limit)
            } else {
                try await manager.clearInteractionLimit()
            }
            guard let self, case .loaded(var state) = phase else { return }
            state.limit = limit
            phase = .loaded(state)
        }, failed: { [weak self] _ in self?.failed() })
    }

    private func until(days: Int) -> Date {
        now().addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// On: a week, from people who don't follow you; off: cleared.
    private func setLimitOn(_ isOn: Bool) {
        save(isOn ? InteractionLimit(audience: .nonFollowers, until: until(days: 7)) : nil)
    }

    private func setAudience(_ audience: InteractionLimitAudience) {
        guard case .loaded(let saved) = phase, var limit = shown(saved)?.limit, limit.audience != audience else { return }
        limit.audience = audience
        save(limit)
    }

    private func setDuration(days: Int) {
        guard case .loaded(let saved) = phase, var limit = shown(saved)?.limit else { return }
        limit.until = until(days: days)
        save(limit)
    }

    private func setSoundReuse(_ allowed: Bool) {
        guard case .loaded = phase else { return }
        let manager = manager
        soundSaves.save(allowed, for: .sounds, { [weak self] allowed in
            try await manager.setAllowsSoundReuse(allowed)
            guard let self, case .loaded(var state) = phase else { return }
            state.allowsSoundReuse = allowed
            phase = .loaded(state)
        }, failed: { [weak self] _ in self?.failed() })
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
        case .takingLonger:
            loadingGate.retry()
            load()
        default: break
        }
    }
}
