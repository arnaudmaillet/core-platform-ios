import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// One post made with the sound: its poster (or its words, for a text post),
/// and the marks that say which one is which.
///
/// Two marks, both the same dark capsule in the top-leading corner — one
/// family of labels on a thumbnail, stacked when a tile earns both:
/// - **♪ Original**: the post the sound was first published with. The
///   "Popular" row puts it first (`SoundSheetSections`).
/// - **Watching**: the post the sheet was opened from — second in "Popular".
///
/// The same cell in the rows, the grid and a pushed section's gallery.
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

/// A section's head: its title on the left, "View all ›" on the right when
/// the section holds more than the sheet shows (`SoundSheetSection.hasMore`).
///
/// "View all ›" is Discover's control in every respect the eye reads
/// (`DiscoverViewAllFooterView`) — a plain secondary-label button in semibold
/// subheadline, the chevron trailing and pointing RIGHT because it pushes a
/// screen — so the app says "there is more of this" one way. It sits at the
/// section's head rather than under it: a row scrolls sideways, and a door
/// under it would be under the toolbar at the collapsed detent.
///
/// ⚠️ ITS HEIGHT IS COMPUTED (`height(traits:)`), and the layout gives it that
/// height absolutely: it is part of the collapsed detent, which is never
/// measured off a live layout.
final class SoundSheetSectionHeaderView: UICollectionReusableView {
    static let viewAllTitle = "View all"

    var onViewAll: (() -> Void)?

    private let titleLabel = UILabel()
    private let button = UIButton(configuration: .plain())

    /// The header's height at `traits`' text size: the title's line with a
    /// little air, never under the 44pt a control needs.
    static func height(traits: UITraitCollection) -> CGFloat {
        let title = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traits)
        return max(44, (title.lineHeight + 2 * Spacing.sm).rounded(.up))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .title3).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs + 2
        configuration.baseForegroundColor = .secondaryLabel
        // Flush with the tiles' right edge: the plain style's own side padding
        // would stand the chevron off the gutter.
        configuration.contentInsets = .init(top: 0, leading: Spacing.sm, bottom: 0, trailing: 0)
        var text = AttributedString(Self.viewAllTitle)
        text.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        configuration.attributedTitle = text
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.onViewAll?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(button)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -Spacing.sm),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onViewAll = nil
    }

    func configure(title: String, hasMore: Bool) {
        titleLabel.text = title
        button.isHidden = !hasMore
        button.accessibilityLabel = "View all: \(title)"
    }

    /// The title as shown — what a test reads.
    var title: String? { titleLabel.text }
    /// Whether "View all" is offered — what a test reads.
    var offersViewAll: Bool { !button.isHidden }

    /// Presses "View all", as a tap would.
    func sendViewAll() { onViewAll?() }
}

/// The sound's head (`SoundSheetHeaderView`) as the sheet's first item: a
/// section of its own above the posts' sections, at the absolute height the
/// collapsed detent counted.
final class SoundSheetHeaderCell: UICollectionViewCell {
    let header = SoundSheetHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

