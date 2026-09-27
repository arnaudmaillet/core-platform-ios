import UIKit

/// The row of matches for an inline `:query`, floating just above the
/// composer's field (see `EmoteKeyboard.suggestionAnchor`).
@MainActor
final class EmoteSuggestionStrip: UIView {
    static let height: CGFloat = 46
    /// How many of the leading suggestions may start a bake.
    static let animatedLead = 6

    var onSelect: ((Emote) -> Void)?

    private let engine: EmoteEngine
    private(set) var suggestions: [Emote] = []
    private let collectionView: UICollectionView

    init(engine: EmoteEngine) {
        self.engine = engine
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 42, height: 42)
        layout.minimumLineSpacing = 2
        layout.sectionInset = UIEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        clipsToBounds = true
        backgroundColor = .clear
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous

        let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(EmoteTileCell.self, forCellWithReuseIdentifier: EmoteTileCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collectionView)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `emotes`, or collapses to nothing for an empty list.
    func show(_ emotes: [Emote]) {
        guard emotes.map(\.id) != suggestions.map(\.id) else { return }
        suggestions = emotes
        isHidden = emotes.isEmpty
        collectionView.reloadData()
        if !emotes.isEmpty { collectionView.setContentOffset(.zero, animated: false) }
    }
}

extension EmoteSuggestionStrip: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        suggestions.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmoteTileCell.reuseID, for: indexPath)
        // The first few matches are what the person is spelling out: those
        // may bake and animate; the tail plays only what is resident.
        (cell as? EmoteTileCell)?.configure(
            suggestions[indexPath.item], engine: engine, prefersAnimation: indexPath.item < Self.animatedLead
        )
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < suggestions.count else { return }
        onSelect?(suggestions[indexPath.item])
    }
}
