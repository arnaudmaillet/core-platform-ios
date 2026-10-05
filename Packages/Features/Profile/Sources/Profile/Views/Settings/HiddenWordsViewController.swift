import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Hidden Words (#404, backend #728):
/// comments on the active profile's posts that contain a hidden word, or a
/// commonly reported offensive term, are hidden from everyone but their
/// author. Each change replaces the server's list; nothing here is optimistic.
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
    }

    private let manager: any CommentFiltersManaging
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
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
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.commentFilters())
            } catch {
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
                if case .loaded(let filters) = phase { toggle.isOn = filters.filtersOffensive }
                toggle.isEnabled = !isSaving
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.setOffensive(toggle.isOn)
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            case .word(let word):
                content.text = word
            case .add:
                content.text = "Add Words…"
                content.textProperties.color = .tintColor
            case .loading:
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content.text = "Couldn't load your filters. Tap to try again."
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
            snapshot.appendItems([.loading], toSection: .offensive)
        case .failed:
            snapshot.appendSections([.offensive])
            snapshot.appendItems([.failed], toSection: .offensive)
        case .loaded(let filters):
            snapshot.appendSections([.offensive, .words])
            snapshot.appendItems([.offensive], toSection: .offensive)
            snapshot.appendItems(filters.hiddenWords.map(Item.word) + [.add], toSection: .words)
            snapshot.reconfigureItems([.offensive])
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    // MARK: - Changes

    private func save(_ change: (inout CommentFilterSettings) -> Void) {
        guard case .loaded(let current) = phase, !isSaving else { return }
        var next = current
        change(&next)
        guard next != current else { return }
        isSaving = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await manager.setCommentFilters(next))
            } catch {
                let message = (error as? CommentFiltersError) == .tooMany
                    ? "You can hide up to \(CommentFilterSettings.maximumWords) words, each up to \(CommentFilterSettings.maximumWordLength) characters."
                    : "Couldn't save your filters. Try again."
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            isSaving = false
            applySnapshot()
        }
    }

    private func setOffensive(_ isOn: Bool) {
        save { $0.filtersOffensive = isOn }
    }

    private func remove(_ word: String) {
        save { $0.hiddenWords.removeAll { $0 == word } }
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
            self?.save { $0.hiddenWords = CommentFilterSettings.normalized($0.hiddenWords + words) }
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
        case .add: presentAdd()
        case .failed: load()
        default: break
        }
    }
}
