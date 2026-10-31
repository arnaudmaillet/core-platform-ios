import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Hidden Words (#404, backend #728):
/// comments on the active profile's posts that contain a hidden word, or a
/// commonly reported offensive term, are hidden from everyone but their
/// author. Each change replaces the server's list; nothing here is
/// optimistic: a change shows as made, with the loader beside it, until the
/// server holds it (#1775, `SettingSaves`).
final class HiddenWordsViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(CommentFilterSettings)
        case failed
    }

    enum Section: Hashable {
        case offensive, words
    }

    private enum Item: Hashable {
        case offensive
        case word(String)
        case add
        case loading
        case failed
        /// Past 10 s (#1770): a row a tap retries.
        case takingLonger
    }

    private let manager: any CommentFiltersManaging
    private var phase: Phase = .loading {
        didSet {
            // Every answer, a save's included, is the next visit's first
            // frame (#1776).
            if case .loaded(let value) = phase { settingsCache?.store(value, as: CommentFiltersRecord.self, viewer: settingsWriter) }
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
    /// A change on its way to the server (#1775): the switch, or the list.
    private enum Change: Sendable {
        case offensive(Bool)
        case words([String])
    }

    private lazy var saves: SettingSaves<Section, Change> = {
        let saves = SettingSaves<Section, Change>()
        saves.onChange = { [weak self] in self?.applySnapshot() }
        return saves
    }()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manager: any CommentFiltersManaging) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        title = "Hidden Words"
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
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .word(let word) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.remove(word)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }
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
        } else if let stored = settingsCache?.value(CommentFiltersRecord.self) {
            phase = .loaded(stored)
        } else {
            phase = .loading
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.commentFilters())
            } catch {
                loadFailure = NetworkFailure.of(error)
                // A failed revalidation keeps the answer on screen.
                if case .loaded = phase { return }
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    static func header(_ section: Section) -> String? {
        switch section {
        case .offensive: nil
        case .words: "Hidden Words"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .offensive:
            "Hides comments on your posts that contain words commonly reported as offensive."
        case .words:
            "Comments on your posts that contain these words or phrases are hidden from everyone except the person who wrote them. They aren't told. Whole words only, in any case; an emoji matches anywhere."
        }
    }

    /// "spoiler, the end" → ["spoiler", "the end"].
    static func words(fromInput input: String) -> [String] {
        input.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.cell()
            switch item {
            case .offensive:
                content.text = "Hide Offensive Comments"
                content.image = UIImage(systemName: "eye.slash")
                content.imageProperties.tintColor = .label
                let toggle = UISwitch()
                if let filters = shown { toggle.isOn = filters.filtersOffensive }
                toggle.isEnabled = !saves.isSaving(.offensive)
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.setOffensive(toggle.isOn)
                }, for: .valueChanged)
                let control = UICellAccessory.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
                cell.accessories = saves.isSaving(.offensive) ? [.busy(), control] : [control]
            case .word(let word):
                content.text = word
            case .add:
                content.text = "Add Words…"
                // The list on its way: the loader, and the row waits.
                let travels = saves.isSaving(.words)
                content.textProperties.color = travels ? .secondaryLabel : .tintColor
                if travels { cell.accessories = [.busy()] }
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
                    for: loadFailure, fallback: "Couldn't load your filters. Tap to try again."
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.footer)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        switch phase {
        case .loading:
            snapshot.appendSections([.offensive])
            // The kit's timing (#1770): nothing for its delay, the bones,
            // "taking longer" past 10 s.
            switch loadingGate.loading() {
            case .bones: snapshot.appendItems([.loading], toSection: .offensive)
            case .takingLonger: snapshot.appendItems([.takingLonger], toSection: .offensive)
            case .nothing: break
            }
        case .failed:
            snapshot.appendSections([.offensive])
            snapshot.appendItems([.failed], toSection: .offensive)
        case .loaded(let saved):
            let filters = shown ?? saved
            snapshot.appendSections([.offensive, .words])
            snapshot.appendItems([.offensive], toSection: .offensive)
            snapshot.appendItems(filters.hiddenWords.map(Item.word) + [.add], toSection: .words)
            snapshot.reconfigureItems([.offensive, .add])
        }
        let animated = view.window != nil
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

    /// The filters as the rows show them: the changes on their way over the
    /// server's.
    private var shown: CommentFilterSettings? {
        guard case .loaded(var filters) = phase else { return nil }
        if case .offensive(let isOn)? = saves.value(for: .offensive) { filters.filtersOffensive = isOn }
        if case .words(let words)? = saves.value(for: .words) { filters.hiddenWords = words }
        return filters
    }

    /// Saves one change over the record the saves before it left — the
    /// server takes the whole list.
    private func save(_ change: Change) {
        guard let current = shown else { return }
        let key: Section
        switch change {
        case .offensive(let isOn):
            guard isOn != current.filtersOffensive else { return }
            key = .offensive
        case .words(let words):
            guard words != current.hiddenWords else { return }
            key = .words
        }
        let manager = manager
        saves.save(change, for: key, { [weak self] change in
            guard let self, case .loaded(var next) = phase else { return }
            switch change {
            case .offensive(let isOn): next.filtersOffensive = isOn
            case .words(let words): next.hiddenWords = words
            }
            let saved = try await manager.setCommentFilters(next)
            phase = .loaded(saved)
        }, failed: { [weak self] error in
            let message = (error as? CommentFiltersError) == .tooMany
                ? "You can hide up to \(CommentFilterSettings.maximumWords) words, each up to \(CommentFilterSettings.maximumWordLength) characters."
                : "Couldn't save your filters. Try again."
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        })
    }

    private func setOffensive(_ isOn: Bool) {
        save(.offensive(isOn))
    }

    private func remove(_ word: String) {
        guard let current = shown else { return }
        save(.words(current.hiddenWords.filter { $0 != word }))
    }

    private func presentAdd() {
        let alert = UIAlertController(
            title: "Add Hidden Words",
            message: "Separate words or phrases with commas.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "spoiler, the end"
            field.autocapitalizationType = .none
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            let words = Self.words(fromInput: alert?.textFields?.first?.text ?? "")
            guard !words.isEmpty else { return }
            guard let self, let current = shown else { return }
            save(.words(CommentFilterSettings.normalized(current.hiddenWords + words)))
        })
        present(alert, animated: true)
    }
}

extension HiddenWordsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .add, .failed: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .add where !saves.isSaving(.words): presentAdd()
        case .failed: load()
        case .takingLonger:
            loadingGate.retry()
            load()
        default: break
        }
    }
}

// MARK: - How it is left (#1144)

extension HiddenWordsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
