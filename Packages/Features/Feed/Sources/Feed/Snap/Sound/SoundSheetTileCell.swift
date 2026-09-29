import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One post made with the sound: its poster (or its words, for a text post),
/// and the marks that say which one is which.
///
/// Two marks, both the same dark capsule in the top-leading corner — one
/// family of labels on a thumbnail, stacked when a tile earns both:
/// - **♪ Original**: the post the sound was first published with. The grid
///   puts it first (`SoundSheetViewController.gridPostIDs`).
/// - **Watching**: the post the sheet was opened from.
final class SoundSheetTileCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let originalBadge = TileBadge(text: "Original", symbol: "music.note")
    private let currentBadge = TileBadge(text: "Watching", symbol: nil)
    private let captionLabel = UILabel()
    private var loading: Task<Void, Never>?
    private var postID: PostID?

    /// Every corner of every tile, wherever it is: in scale with the grid's
    /// gutter (`SoundSheetViewController.gutter`, 8pt) — a radius much larger
    /// than the gap between tiles opens a light "rosette" where four corners
    /// meet, wider than the gap itself (the Upload picker's measured lesson,
    /// `MediaPickerGridCell.Metrics.corner`).
    static let cornerRadius: CGFloat = Spacing.md

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        // ⚠️ A FIXED RADIUS, NEVER `.containerConcentric`. #304 made the tiles
        // concentric with the sheet; at large the sheet's corners ARE the
        // screen's, so a tile scrolling past the bottom corners took the
        // screen's radius less the few points between them and read as
        // cropped — then square again a row later. Concentricity is for what
        // STAYS near a corner (chrome), not for content that scrolls past it.
        contentView.layer.cornerRadius = Self.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        // A text post has no picture: its words are its tile.
        captionLabel.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 5
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(captionLabel)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.sm),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.sm),
            captionLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let badges = UIStackView(arrangedSubviews: [originalBadge, currentBadge])
        badges.axis = .vertical
        badges.alignment = .leading
        badges.spacing = Spacing.xs
        badges.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badges)
        NSLayoutConstraint.activate([
            badges.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.xs + 2),
            badges.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.xs + 2),
            badges.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Spacing.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
        loading?.cancel()
        imageView.image = nil
    }

    /// The picture on the tile, for the hero to take off with.
    var cover: UIImage? { imageView.image }

    /// Whether the "Original" mark shows — what a test reads.
    var showsOriginalBadge: Bool { !originalBadge.isHidden }

    /// Hides the tile while its post is in the air or open, so the card and
    /// the tile are never both on screen.
    func setConcealed(_ concealed: Bool) {
        contentView.alpha = concealed ? 0 : 1
    }

    func configure(_ tile: SoundSheetViewController.Tile, pipeline: ImagePipeline) {
        postID = tile.postID
        originalBadge.isHidden = !tile.isOriginal
        currentBadge.isHidden = !tile.isCurrent
        accessibilityLabel = [
            tile.isOriginal ? "Original" : nil,
            tile.isCurrent ? "This post" : "Post",
        ].compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = .button
        loading?.cancel()
        captionLabel.text = tile.thumbnailURL == nil ? tile.caption : nil
        guard let url = tile.thumbnailURL else { return }
        let id = tile.postID
        loading = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.postID == id else { return }
            self.imageView.image = image
        }
    }
}

/// A tile's mark: white caption2 on a dark capsule, readable over any poster
/// in either appearance — a thumbnail is its own ground, not the sheet's.
private final class TileBadge: UIView {
    init(text: String, symbol: String?) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        let label = UILabel()
        let font = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        let title = NSMutableAttributedString()
        if let symbol, let glyph = UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            title.append(NSAttributedString(attachment: NSTextAttachment(image: glyph)))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: text))
        title.addAttributes([.font: font, .foregroundColor: UIColor.white],
                            range: NSRange(location: 0, length: title.length))
        label.attributedText = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs + 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Spacing.xs + 2)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// "View all N posts", under the grid's first row: the door to the rest.
///
/// Its own cell — in a section of its own between the first row and the
/// others — so the collapsed detent can end right under it, above the
/// toolbar, and so the large detent can take it out of the grid with the
/// diffable snapshot's own animation (`SoundSheetViewController.Section.more`).
final class SoundSheetMoreCell: UICollectionViewCell {
    static let height: CGFloat = 44

    var onTap: (() -> Void)?

    private let button = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs + 2
        configuration.baseForegroundColor = .secondaryLabel
        button.configuration = configuration
        // Centred: it is the sheet's hinge, not a column heading.
        button.contentHorizontalAlignment = .center
        button.accessibilityHint = "Shows every post with this sound"
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String) {
        var text = AttributedString(title)
        text.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        button.configuration?.attributedTitle = text
    }

    /// The title as shown — what a test reads.
    var title: String? { button.configuration?.attributedTitle.map { String($0.characters) } }

    /// Presses the control, as a tap would.
    func sendTap() { onTap?() }
}
