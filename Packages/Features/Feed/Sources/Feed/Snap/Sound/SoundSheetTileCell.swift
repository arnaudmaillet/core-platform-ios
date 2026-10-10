import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// One post made with the sound: its poster (or its words, for a text post),
/// the marks that say which one is which, and its likes.
///
/// ## The foot carries the furniture, the head the words (2026-09-30)
///
/// ```
///   ┌──────────────┐
///   │ words words  │   a text post's caption, from the TOP — it reads
///   │ words…       │   like the page it opens into, not a centred quote
///   │              │
///   │ ♪ Original   │   the marks, stacked, BOTTOM-leading
///   │ Watching  ♥ 3│   the likes, BOTTOM-trailing
///   └──────────────┘
/// ```
///
/// Two marks, both the same dark capsule — one family of labels on a
/// thumbnail, stacked when a tile earns both, the last one on the foot:
/// - **♪ Original**: the post the sound was first published with. The
///   "Popular" row puts it first (`SoundSheetSections`).
/// - **Watching**: the post the sheet was opened from — second in "Popular".
///
/// The LIKES close the foot on the other side, exactly as every gallery's
/// brick does (`PostGridTileCell`'s `likes`: `heart.fill`, caption2
/// semibold, white under a soft shadow, 8pt in and 7pt up). That is not a
/// resemblance but a contract: this sheet's hero is a `.tile` flight card,
/// and the card draws that very count at those very insets
/// (`PostGridFlightCard`) — a tile without it landed a card whose heart
/// vanished in the frame the card was taken away. No scrim: the marks carry
/// their own dark ground and the count its shadow, as on every brick.
///
/// On WORDS the count is ink on the tile's own fill (`.secondaryLabel`, no
/// shadow): a white heart on a light grey tile is not a read-out. Words only
/// ever travel as the tile's own twin (`makeStandIn`), so no flight card has
/// to know.
///
/// The same cell in the rows, the grid and a pushed section's gallery.
final class SoundSheetTileCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let originalBadge = TileBadge(text: "Original", symbol: "music.note")
    private let currentBadge = TileBadge(text: "Watching", symbol: nil)
    private let captionLabel = UILabel()
    /// The count over a picture — the galleries' brick's, see the type's note.
    private let pictureLikes = PostMetricLabel(
        symbol: "heart.fill", font: PostGridFlightCard.metaFont, color: .white, shadowed: true
    )
    /// The count on words: the tile's ink, no shadow.
    private let wordsLikes = PostMetricLabel(
        symbol: "heart.fill", font: PostGridFlightCard.metaFont, color: .secondaryLabel
    )
    private let badges: UIStackView
    /// The marks' foot — moved by `footLift` when they cannot share the line.
    private var badgesBottom: NSLayoutConstraint!
    /// Set on a twin once it is laid out at the tile's size: the foot's
    /// arrangement is the TILE's, and a twin grown with a window must not
    /// re-decide it at every width it passes through (see `footLift`).
    private var footFrozen = false
    private var loading: Task<Void, Never>?
    private var postID: PostID?
    /// The shimmer over a placeholder's fill (#831): a post still on its way
    /// reads as coming, not as a broken grey tile. Made only for a
    /// placeholder and removed once it is filled in — an endless sweep under
    /// every loaded tile would recomposite for nothing.
    ///
    /// ⚠️ **NO FAILED TILE, AND THAT IS THE SHEET'S DESIGN.** A post that cannot
    /// be loaded leaves the sheet and the sections are dealt again without it
    /// (`SnapFeedViewController.presentSoundSheet`, `SoundSheetSections`): its
    /// tile would lead nowhere, and "Popular" may go with it. A quiet failed
    /// tile left in place would be a dead end in a grid of things to open.
    private var bone: SkeletonBoneView?

    /// Every corner of every tile, wherever it is: in scale with the grid's
    /// gutter (`SoundSheetViewController.gutter`, 8pt) — a radius much larger
    /// than the gap between tiles opens a light "rosette" where four corners
    /// meet, wider than the gap itself (the Upload picker's measured lesson,
    /// `MediaPickerGridCell.Metrics.corner`).
    static let cornerRadius: CGFloat = Spacing.md

    override init(frame: CGRect) {
        badges = Self.badgeStack([originalBadge, currentBadge])
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

        // A text post has no picture: its words are its tile, read from the
        // top like the page they open into.
        captionLabel.font = .scaledFont(forTextStyle: .caption1, weight: .semibold)
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 5
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(captionLabel)

        contentView.addSubview(badges)
        badgesBottom = Self.pinBadges(badges, in: contentView)
        for likes in [pictureLikes, wordsLikes] {
            likes.isHidden = true
            contentView.addSubview(likes)
            Self.pinLikes(likes, in: contentView)
        }

        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm),
            captionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.sm),
            captionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.sm),
            // Never into the foot: at a large text size the words give up
            // lines rather than run under the marks or the count. (A hidden
            // mark column is empty, and so no taller than nothing.)
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: badges.topAnchor, constant: -Spacing.xs),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: wordsLikes.topAnchor, constant: -Spacing.xs),
        ])
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

    /// The marks on the foot, bottom-leading — the same few points off both
    /// edges they used to keep in the top corner.
    ///
    /// ⚠️ PINNED TO THE FOOT, SO THEY RIDE IT. Every copy that grows with a
    /// window — the twin (`makeStandIn`), the flight card's overlay
    /// (`makeBadgeOverlay`) — is laid out INSIDE the pose that sizes it
    /// (`RevealStage.apply`, `PostGridFlightCard.poseRestingChrome`), so the
    /// marks follow the window's bottom edge on the flight's own curve. Pinned
    /// to the top they could not have drifted even laid out late; pinned here,
    /// a pass deferred to the end of the turn would snap them to where they
    /// land while the window was still travelling.
    @discardableResult
    private static func pinBadges(_ badges: UIView, in parent: UIView, lift: CGFloat = 0) -> NSLayoutConstraint {
        let bottom = badges.bottomAnchor.constraint(
            equalTo: parent.bottomAnchor, constant: -(badgeInset + lift)
        )
        NSLayoutConstraint.activate([
            badges.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: badgeInset),
            bottom,
            badges.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -Spacing.xs),
        ])
        return bottom
    }

    /// The marks' distance from the tile's leading and bottom edges.
    private static let badgeInset: CGFloat = Spacing.xs + 2
    /// The count's, from the trailing and bottom edges — the flight card's.
    private static let likesTrailingInset: CGFloat = 8
    private static let likesBottomInset: CGFloat = 7

    /// How far the marks step up off the foot: nothing when the last mark and
    /// the count share the line, else the count's line and a gap.
    ///
    /// ⚠️ THE ROW'S TILES ARE TOO NARROW FOR BOTH. "♪ Original" is ~66pt of
    /// capsule and "♥ 1.2K" ~38pt of count; a Popular tile is ~108pt wide
    /// (`rowTilesAcross`), and the two marked tiles are exactly the row's
    /// first two. So the foot is shared when it fits (the grid's wider
    /// tiles, a short count) and the marks stand on the count's line
    /// otherwise — still bottom-leading, never under the count.
    ///
    /// Decided at the TILE's width, once, and carried unchanged by every copy
    /// that grows with a window: a twin freezes it (`footFrozen`), the flight
    /// card's overlay is built with it. Re-decided at the window's width, the
    /// marks would drop onto the foot partway through a flight — a jump.
    static func footLift(width: CGFloat, badges: UIView, likes: UIView) -> CGFloat {
        guard !likes.isHidden, width > 0 else { return 0 }
        let marks = badges.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        guard marks.height > 0 else { return 0 }
        let count = likes.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let room = width - badgeInset - likesTrailingInset - Spacing.xs
        if marks.width + count.width <= room { return 0 }
        return likesBottomInset + count.height + Spacing.xs - badgeInset
    }

    override func layoutSubviews() {
        if !footFrozen {
            let likes = pictureLikes.isHidden ? wordsLikes : pictureLikes
            badgesBottom.constant = -(Self.badgeInset + Self.footLift(
                width: bounds.width, badges: badges, likes: likes
            ))
        }
        super.layoutSubviews()
    }

    /// The count, bottom-trailing, at the flight card's own insets
    /// (`PostGridFlightCard`: 8 in, 7 up) — the card lands on this.
    private static func pinLikes(_ likes: UIView, in parent: UIView) {
        likes.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            likes.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -likesTrailingInset),
            likes.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -likesBottomInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
        loading?.cancel()
        imageView.image = nil
        postID = nil
        bone?.removeFromSuperview()
        bone = nil
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
    ///   the caption on every frame. Around them is ground on ground. The
    ///   whole tile travels as one piece, so its words (at its head) and its
    ///   marks and count (at its foot) keep their places inside it.
    ///
    /// A picture's marks and count are pinned to the twin's FOOT and ride the
    /// window's bottom edge as it grows — see `pinBadges`.
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
        twin.footFrozen = true
        return card
    }

    /// The tile's marks alone, for a FLIGHT card to wear over its picture and
    /// fade as it grows (`SnapFeedHeroOrigin.restingOverlay`) — so a close
    /// does not land a bare picture and pop "Original" / "Watching" on in the
    /// frame the card is taken away. Nil for a tile that wears neither.
    ///
    /// Only the marks: the COUNT is the card's own (`PostGridFlightCard`
    /// draws a `.tile` source's likes itself, at the tile's insets). Laid out
    /// at `size`, then re-laid out only inside the card's pose
    /// (`poseRestingChrome`): the marks are pinned to the foot, bottom-leading
    /// as on the tile, and ride it — they never re-wrap.
    static func makeBadgeOverlay(
        for tile: SoundSheetViewController.Tile, size: CGSize
    ) -> UIView? {
        guard tile.isOriginal || tile.isCurrent else { return nil }
        let overlay = UIView(frame: CGRect(origin: .zero, size: size))
        overlay.isUserInteractionEnabled = false
        let badges = makeBadgeStack(original: tile.isOriginal, current: tile.isCurrent)
        // The count the card draws, measured only: the marks stand where the
        // tile's do (`footLift`), decided at the tile's size.
        let likes = PostMetricLabel(
            symbol: "heart.fill", font: PostGridFlightCard.metaFont, color: .white, shadowed: true
        )
        likes.set(tile.likeCount)
        let lift = footLift(width: size.width, badges: badges, likes: likes)
        overlay.addSubview(badges)
        pinBadges(badges, in: overlay, lift: lift)
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
        showLikes(of: tile)
        captionLabel.text = tile.thumbnailURL == nil ? tile.caption : nil
        imageView.image = cover
    }

    /// The count on the ground it will be read on — see the type's note.
    private func showLikes(of tile: SoundSheetViewController.Tile) {
        let words = tile.thumbnailURL == nil
        pictureLikes.set(words ? nil : tile.likeCount)
        wordsLikes.set(words ? tile.likeCount : nil)
        setNeedsLayout()
    }

    /// How far the marks stand off the foot now — what a test reads.
    var debugFootLift: CGFloat { -badgesBottom.constant - Self.badgeInset }

    #if DEBUG
    /// The likes as drawn, nil when the tile shows none — what a test reads.
    var debugLikes: String? {
        [pictureLikes, wordsLikes].first { !$0.isHidden }?.debugText
    }
    #endif

    /// Whether the "Original" mark shows — what a test reads.
    var showsOriginalBadge: Bool { !originalBadge.isHidden }

    /// Hides the tile while its post is in the air or open, so the card and
    /// the tile are never both on screen.
    func setConcealed(_ concealed: Bool) {
        contentView.alpha = concealed ? 0 : 1
    }

    /// Whether the placeholder's shimmer shows — what a test reads.
    var showsPlaceholderBone: Bool { bone.map { !$0.isHidden && $0.alpha > 0 } ?? false }

    /// The bone on a placeholder; off a loaded tile — cross-faded away when
    /// the same post is filled in (charter P10), dropped at once when the
    /// cell now stands for another.
    private func setPlaceholder(_ placeholder: Bool, fillingIn: Bool) {
        if placeholder {
            if bone == nil {
                let bone = SkeletonBoneView(rounding: .fixed(0))
                // The tile's own fill is the ground; the bone adds only the
                // sweep, so a placeholder keeps the tile's colour.
                bone.backgroundColor = .clear
                bone.frame = contentView.bounds
                bone.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                contentView.insertSubview(bone, aboveSubview: imageView)
                self.bone = bone
            }
            bone?.showSkeleton()
        } else if let bone {
            self.bone = nil
            if fillingIn {
                bone.fadeOutSkeleton(removing: true)
            } else {
                bone.removeFromSuperview()
            }
        }
    }

    func configure(_ tile: SoundSheetViewController.Tile, pipeline: ImagePipeline) {
        let fillingIn = postID == tile.postID
        setPlaceholder(!tile.isLoaded, fillingIn: fillingIn)
        postID = tile.postID
        originalBadge.isHidden = !tile.isOriginal
        currentBadge.isHidden = !tile.isCurrent
        showLikes(of: tile)
        accessibilityLabel = [
            tile.isOriginal ? "Original" : nil,
            tile.isCurrent ? "This post" : "Post",
            tile.likeCount.map { "\(PostMetadata.count($0)) likes" },
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
        let font = UIFont.scaledFont(forTextStyle: .caption2, weight: .semibold)
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

