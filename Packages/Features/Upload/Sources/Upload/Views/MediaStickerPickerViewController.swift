import MediaPlayback
import StickerKit
import UIKit

/// The sheet a sticker is chosen from: the stickers the chat already uses, or
/// any emoji the phone draws.
///
/// ⚠️ **A PICK CLOSES THE SHEET AND SAYS WHAT WAS PICKED — NOTHING ELSE.** The
/// overlay mode decides where it goes and stores it; the sheet never touches
/// an edit.
@MainActor
final class MediaStickerPickerViewController: UIViewController {
    /// Which shelf is showing.
    enum Shelf: Int, CaseIterable {
        case stickers
        case emoji

        var title: String {
            switch self {
            case .stickers: "Stickers"
            case .emoji: "Emoji"
            }
        }
    }

    /// A choice was made.
    var onPick: ((FrameOverlay.Content) -> Void)?

    private(set) var shelf: Shelf = .stickers
    private var query = ""

    private let shelves = UISegmentedControl(items: Shelf.allCases.map(\.title))
    private let search = UISearchBar()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!

    private enum Metrics {
        static let sticker: CGFloat = 72
        static let emoji: CGFloat = 44
        static let header: CGFloat = 28
    }

    /// Each emoji's spoken name, looked up in one step — a cell asking the
    /// catalogue's list would walk a thousand entries per cell.
    private static let names: [String: String] = Dictionary(
        EmojiCatalog.all.map { ($0.glyph, $0.name) }, uniquingKeysWith: { first, _ in first }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        shelves.selectedSegmentIndex = shelf.rawValue
        shelves.addAction(UIAction { [weak self] _ in self?.shelfChanged() }, for: .valueChanged)
        search.placeholder = "Search emoji"
        search.searchBarStyle = .minimal
        search.delegate = self
        search.isHidden = true

        grid.backgroundColor = .clear
        grid.keyboardDismissMode = .onDrag
        grid.delegate = self
        grid.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.identifier)
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.identifier)
        grid.register(
            SectionTitle.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SectionTitle.identifier
        )
        dataSource = UICollectionViewDiffableDataSource(collectionView: grid) { [weak self] grid, path, id in
            guard let self else { return nil }
            switch shelf {
            case .stickers:
                let cell = grid.dequeueReusableCell(withReuseIdentifier: StickerCell.identifier, for: path) as? StickerCell
                if let sticker = StickerCatalog.sticker(id: id) { cell?.show(sticker) }
                return cell
            case .emoji:
                let cell = grid.dequeueReusableCell(withReuseIdentifier: EmojiCell.identifier, for: path) as? EmojiCell
                cell?.show(id, name: Self.names[id] ?? id)
                return cell
            }
        }
        dataSource.supplementaryViewProvider = { [weak self] grid, kind, path in
            let header = grid.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: SectionTitle.identifier, for: path
            ) as? SectionTitle
            let section = self?.dataSource.snapshot().sectionIdentifiers[path.section] ?? ""
            header?.label.text = EmojiCatalog.Section(rawValue: section)?.title ?? ""
            return header
        }

        let stack = UIStackView(arrangedSubviews: [shelves, search, grid])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        reload()
    }

    private func shelfChanged() {
        shelf = Shelf(rawValue: shelves.selectedSegmentIndex) ?? .stickers
        search.isHidden = shelf != .emoji
        if shelf != .emoji { search.resignFirstResponder() }
        reload()
    }

    /// What the grid shows for the shelf and the search.
    ///
    /// ⚠️ **EMOJI ARE ONE SECTION PER CATEGORY — OR ONE SECTION OF RESULTS.**
    func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        switch shelf {
        case .stickers:
            snapshot.appendSections(["stickers"])
            snapshot.appendItems(StickerCatalog.stickers.map(\.id))
        case .emoji:
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                for section in EmojiCatalog.Section.allCases {
                    let glyphs = EmojiCatalog.emoji(in: section).map(\.glyph)
                    guard !glyphs.isEmpty else { continue }
                    snapshot.appendSections([section.rawValue])
                    snapshot.appendItems(glyphs, toSection: section.rawValue)
                }
            } else {
                snapshot.appendSections(["results"])
                snapshot.appendItems(Array(Set(EmojiCatalog.search(trimmed).map(\.glyph))).sorted())
            }
        }
        let headed = shelf == .emoji && query.trimmingCharacters(in: .whitespaces).isEmpty
        grid.setCollectionViewLayout(
            Self.layout(side: shelf == .stickers ? Metrics.sticker : Metrics.emoji, headed: headed),
            animated: false
        )
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private static func layout(
        side: CGFloat = Metrics.sticker, headed: Bool = false
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .absolute(side), heightDimension: .absolute(side)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                subitems: [item]
            )
            group.interItemSpacing = .flexible(4)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 4
            if headed {
                section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(Metrics.header)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
                )]
            }
            return section
        }
    }

    private func pick(_ id: String) {
        let content: FrameOverlay.Content
        switch shelf {
        case .stickers: content = .sticker(id: id)
        case .emoji: content = .emoji(id)
        }
        onPick?(content)
        dismiss(animated: true)
    }

    // MARK: - Cells

    private final class StickerCell: UICollectionViewCell {
        static let identifier = "sticker"
        private let picture = UIImageView()
        private var shown: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.contentMode = .scaleAspectFit
            picture.frame = contentView.bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(picture)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func show(_ sticker: Sticker) {
            shown = sticker.id
            accessibilityLabel = sticker.label
            picture.image = nil
            StickerCatalog.firstFrame(for: sticker, size: CGSize(width: 88, height: 88)) { [weak self] image in
                guard let self, shown == sticker.id else { return }
                picture.image = image
            }
        }
    }

    private final class EmojiCell: UICollectionViewCell {
        static let identifier = "emoji"
        private let glyph = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            glyph.font = .systemFont(ofSize: 32)
            glyph.textAlignment = .center
            glyph.frame = contentView.bounds
            glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(glyph)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func show(_ emoji: String, name: String) {
            glyph.text = emoji
            accessibilityLabel = name.capitalized
        }
    }

    private final class SectionTitle: UICollectionReusableView {
        static let identifier = "title"
        let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.frame = bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}

extension MediaStickerPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        pick(id)
    }
}

extension MediaStickerPickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        reload()
    }
}

#if DEBUG
extension MediaStickerPickerViewController {
    /// Internal for tests: what the grid holds, section by section.
    var debugItems: [String] { dataSource?.snapshot().itemIdentifiers ?? [] }
    var debugSections: [String] { dataSource?.snapshot().sectionIdentifiers ?? [] }
    func debugShow(_ shelf: Shelf) {
        shelves.selectedSegmentIndex = shelf.rawValue
        shelfChanged()
    }
    func debugSearch(_ text: String) { searchBar(search, textDidChange: text) }
    func debugPick(_ id: String) { pick(id) }
}
#endif
