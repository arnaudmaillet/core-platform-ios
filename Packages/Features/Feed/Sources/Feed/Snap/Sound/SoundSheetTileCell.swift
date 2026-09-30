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

        let badges = Self.badgeStack([originalBadge, currentBadge])
        contentView.addSubview(badges)
        Self.pinBadges(badges, in: contentView)
    }

    /// The marks' column — one arrangement for the tile and the overlay a
    /// flight card wears (`makeBadgeOverlay`), so the two cannot drift.
    private static func badgeStack(_ badges: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: badges)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func makeBadgeStack(original: Bool, current: Bool) -> UIStackView {
        let originalBadge = TileBadge(text: "Original", symbol: "music.note")
        let currentBadge = TileBadge(text: "Watching", symbol: nil)
        originalBadge.isHidden = !original
        currentBadge.isHidden = !current
        return badgeStack([originalBadge, currentBadge])
    }

    private static func pinBadges(_ badges: UIView, in parent: UIView) {
        NSLayoutConstraint.activate([
            badges.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.xs + 2),
            badges.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.xs + 2),
            badges.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -Spacing.xs),
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

    // MARK: - Transition twins

    /// The tile as it rests, drawn fresh — what a WINDOW out of it starts as
    /// and what a close lands as, whatever the viewer ended on
    /// (`SnapFeedHeroOrigin.textReveal`). For You's Following card's twin
    /// (`ForYouFollowingCardCell.makeStandIn`), for this sheet's tile.
    ///
    /// Two arrangements, because the window grows from the tile to the whole
    /// screen and the two kinds of tile stand that differently:
    /// - a PICTURE fills the window and re-crops as it grows — the
    ///   `PostGridTileStandInView` rule, since a picture pinned at the tile's
    ///   size would be a postage stamp in a large grey card for most of the
    ///   flight;
    /// - WORDS stay at the tile's own size, centred, on the tile's ground —
    ///   `RevealDismissCardView`'s rule, since stretching them would re-wrap
    ///   the caption on every frame. Around them is ground on ground.
    ///
    /// ⚠️ ON AN OPAQUE GROUND. The tile's own fill is translucent — it rests
    /// on the sheet — and a window carries it over the PAGE, which would show
    /// through it. `standInGround` is that fill already composed over the
    /// sheet.
    static func makeStandIn(
        for tile: SoundSheetViewController.Tile,
        cover: UIImage?,
        size: CGSize,
        traits: UITraitCollection
    ) -> UIView {
        let card = UIView(frame: CGRect(origin: .zero, size: size))
        card.backgroundColor = standInGround(traits: traits)
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        let twin = SoundSheetTileCell(frame: card.bounds)
        twin.isUserInteractionEnabled = false
        // Its own ground is the translucent one; the card above already wears
        // the composed one.
        twin.contentView.backgroundColor = .clear
        twin.show(tile, cover: cover)
        let words = tile.thumbnailURL == nil
        twin.autoresizingMask = words
            ? [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            : [.flexibleWidth, .flexibleHeight]
        card.addSubview(twin)
        // Laid out HERE, at the tile's size and outside any animation — the
        // reveal lays a stand-in out inside its own block, and a first pass
        // there grows the badges and words out of the window's top-left
        // corner (`ForYouFollowingCardCell.addAnchoredOverlay`).
        UIView.performWithoutAnimation { card.layoutIfNeeded() }
        return card
    }

    /// The tile's marks alone, for a FLIGHT card to wear over its picture and
    /// fade as it grows (`SnapFeedHeroOrigin.restingOverlay`) — so a close
    /// does not land a bare picture and pop "Original" / "Watching" on in the
    /// frame the card is taken away. Nil for a tile that wears neither.
    ///
    /// Laid out once at `size`, then only re-posed by the card: the badges are
    /// pinned to the top-leading corner and never re-wrap.
    static func makeBadgeOverlay(
        for tile: SoundSheetViewController.Tile, size: CGSize
    ) -> UIView? {
        guard tile.isOriginal || tile.isCurrent else { return nil }
        let overlay = UIView(frame: CGRect(origin: .zero, size: size))
        overlay.isUserInteractionEnabled = false
        let badges = makeBadgeStack(original: tile.isOriginal, current: tile.isCurrent)
        overlay.addSubview(badges)
        pinBadges(badges, in: overlay)
        UIView.performWithoutAnimation { overlay.layoutIfNeeded() }
        return overlay
    }

    /// The tile's fill composed over the sheet it rests on — an opaque colour
    /// for a surface that is not resting on the sheet. Resolved against the
    /// tile's own traits (the sheet is ELEVATED in dark mode, which is part of
    /// what the tile looks like).
    static func standInGround(traits: UITraitCollection) -> UIColor {
        let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let base = UIColor.systemBackground.resolvedColor(with: traits)
        var (fr, fg, fb, fa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard fill.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
              base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        else { return base }
        return UIColor(
            red: fr * fa + br * (1 - fa),
            green: fg * fa + bg * (1 - fa),
            blue: fb * fa + bb * (1 - fa),
            alpha: 1
        )
    }

    /// What `configure` shows, set synchronously — a twin has its picture
    /// already and must draw it on its first frame.
    private func show(_ tile: SoundSheetViewController.Tile, cover: UIImage?) {
        postID = tile.postID
        originalBadge.isHidden = !tile.isOriginal
        currentBadge.isHidden = !tile.isCurrent
        captionLabel.text = tile.thumbnailURL == nil ? tile.caption : nil
        imageView.image = cover
    }

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

/// A section's head: its title, and — when the section holds more than the
/// sheet shows (`SoundSheetSection.hasMore`) — a chevron RIGHT AFTER the
/// title's last letter, the two one control that pushes the whole ranking.
///
/// ```
///  Popular ›                 ← title and chevron: one tap target
///  Recent                    ← shows everything it holds: no chevron
/// ```
///
/// No "View all" label (dropped 2026-09-30): a chevron after a title says
/// "this title opens its section", the way For You's section headers say it.
/// The control keeps the header's full height as its hit target; the chevron
/// is in the secondary label's colour, a notch smaller than the title, so the
/// title stays the word the eye reads.
///
/// ⚠️ ITS HEIGHT IS COMPUTED (`height(traits:)`), and the layout gives it that
/// height absolutely: it is part of the collapsed detent, which is never
/// measured off a live layout.
final class SoundSheetSectionHeaderView: UICollectionReusableView {
    var onViewAll: (() -> Void)?

    private let button = UIButton(configuration: .plain())

    /// The header's height at `traits`' text size: the title's line with a
    /// little air, never under the 44pt a control needs.
    static func height(traits: UITraitCollection) -> CGFloat {
        let title = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traits)
        return max(44, (title.lineHeight + 2 * Spacing.sm).rounded(.up))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            .applying(UIImage.SymbolConfiguration(weight: .bold))
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .secondaryLabel }
        configuration.baseForegroundColor = .label
        configuration.titleLineBreakMode = .byTruncatingTail
        // Flush with the tiles' left edge: the plain style's own padding would
        // stand the title off the gutter.
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.bold)
            return attributes
        }
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in self?.onViewAll?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
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
        button.configuration?.title = title
        button.configuration?.image = hasMore ? UIImage(systemName: "chevron.right") : nil
        // A section that shows everything is a plain title: nothing to press.
        button.isUserInteractionEnabled = hasMore
        button.accessibilityLabel = title
        button.accessibilityTraits = hasMore ? [.header, .button] : .header
        button.accessibilityHint = hasMore ? "Shows every post in \(title)" : nil
    }

    /// The title as shown — what a test reads.
    var title: String? { button.configuration?.title }
    /// Whether the chevron is offered — what a test reads.
    var offersViewAll: Bool { button.configuration?.image != nil && button.isUserInteractionEnabled }
    /// The title and its chevron — what a test lays out.
    var control: UIButton { button }

    /// Presses the title and its chevron, as a tap would.
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

