import DesignSystem
import UIKit

/// The row of people or tags for an `@` or `#` being typed (#524), in the
/// same glass capsule and the same place as the emote strip — the two never
/// show together, one token is typed at a time.
@MainActor
final class TextCompletionStrip: UIView {
    static let height = EmoteSuggestionStrip.height

    var onSelect: ((TextCompletion) -> Void)?

    private(set) var completions: [TextCompletion] = []
    private let collectionView: UICollectionView

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.estimatedItemSize = CGSize(width: 120, height: 36)
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        // The emote strip's Liquid Glass capsule (#720).
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let glass = UIVisualEffectView(effect: effect)
        glass.cornerConfiguration = .capsule()
        glass.clipsToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(TextCompletionChip.self, forCellWithReuseIdentifier: TextCompletionChip.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = glass.contentView.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(collectionView)
        accessibilityIdentifier = "text-completions"
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `completions`, or collapses to nothing for an empty list.
    func show(_ completions: [TextCompletion]) {
        guard completions != self.completions else { return }
        self.completions = completions
        isHidden = completions.isEmpty
        collectionView.reloadData()
        if !completions.isEmpty { collectionView.setContentOffset(.zero, animated: false) }
    }
}

extension TextCompletionStrip: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        completions.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TextCompletionChip.reuseID, for: indexPath)
        (cell as? TextCompletionChip)?.configure(completions[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < completions.count else { return }
        onSelect?(completions[indexPath.item])
    }
}

/// One completion: the token as it will land, and a person's name beside
/// it when there is one.
final class TextCompletionChip: UICollectionViewCell {
    static let reuseID = "TextCompletionChip"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        label.adjustsFontForContentSizeCategory = false
        label.constrain(in: contentView) { parent in
            label.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12)
            label.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -12)
            label.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            parent.heightAnchor.constraint(equalToConstant: 36)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ completion: TextCompletion) {
        // Capped: the strip is a fixed 46pt capsule, like the emote strip.
        let base = UIFont.scaledFont(forTextStyle: .subheadline, weight: .regular, maximumPointSize: 19)
        let text = NSMutableAttributedString(string: completion.token, attributes: [
            .font: UIFont.scaledFont(forTextStyle: .subheadline, weight: .semibold, maximumPointSize: 19),
            .foregroundColor: UIColor.label
        ])
        if let title = completion.title, !title.isEmpty {
            text.append(NSAttributedString(string: "  " + title, attributes: [
                .font: base, .foregroundColor: UIColor.secondaryLabel
            ]))
        }
        label.attributedText = text
        accessibilityLabel = [completion.token, completion.title].compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }
}
