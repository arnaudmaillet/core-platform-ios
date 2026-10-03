import CoreModels
import DesignSystem
import EmoteKit
import MediaCore
import UIKit

/// The foot of a compact card: who posted, and the first lines of what they
/// said — over a scrim on a picture, straight on the card for words.
///
/// Born as the Following card's overlay (`ForYouFollowingCardCell`, which
/// still calls it `ForYouCardCaptionOverlay`), and shared since 2026-10-03 with
/// the mosaic's LARGE tiles (`PostGridTileCell.showsInfo`) — one arrangement,
/// so a tile and a Following card read as the same furniture at different
/// sizes. The words-on-the-card placement (`.onCard`) now only dresses a text
/// post's long-press preview: the Following row's text cards are the list's
/// own card (`PostGridListRowCell`).
///
/// Its own view, not a few labels inside the cell, because a flight needs a
/// COPY of it: the card that flies out of the row wears this as its resting
/// furniture and the flight fades it as the card grows into the page, the way
/// a mosaic brick's counters leave (`SnapFeedHeroOrigin.restingOverlay`).
///
/// ## ⚠️ Laid out ONCE, at the card's size — then posed, never re-laid out
///
/// A copy that rides a transition window is resized every frame of it, from
/// the card to the whole screen and back. Laid out against those sizes the
/// way a cell lays out, the caption re-wrapped at every width, and whatever
/// pass ran first ran inside the flight's animation block: every label grew
/// out of the window's top-left corner towards its place, the whole length
/// of a close. Filmed on a Following video card and on text cards alike — "the
/// text appears from the top-left and extends to the bottom-right, as if it
/// were not anchored".
///
/// So a copy is built with its `referenceSize` — the card's resting size —
/// and wraps its words there, exactly as the card in the row does. At any
/// other size each piece keeps that layout and is POSED, by a uniform scale of
/// the window's width to the card's, onto the edge it belongs to: the foot for
/// a picture's author and caption, the top for a text card's words, the foot
/// for its author. The window's corners carry them from the first frame, and
/// only the fade the flight gives the whole overlay changes what is seen —
/// the arrangement the flight already gives the page's chrome replica, laid
/// out once and scaled into the card.
///
/// The cell's own overlay passes no reference: it IS the card, and lays out
/// at whatever size the card is, like any view.
///
/// ## The author's face
///
/// A small disc leads the author's name (2026-09-30), as tall as the name's
/// line — the band's avatar (`PostAuthorBandView`) at the size a caption can
/// afford. It follows the app's avatar contract: the initials are drawn at
/// once and the picture, when the post names one, is laid over them as it
/// arrives. A COPY — the flight's resting furniture, a window's stand-in —
/// reads the picture straight from the pipeline's memory when the card in the
/// row already drew it, so the face the card takes off with is the face it
/// had.
///
/// ## The like
///
/// Every card closes its AUTHOR LINE with a heart and the post's count
/// (`PostLikeReadoutView`) — the line's trailing end, the name truncating
/// before it. On a text card that line is the foot, so the heart sits in the
/// card's bottom-right corner, where a mosaic tile's sits; on a picture it is
/// the line above the caption's lines. A READOUT, red once the viewer has
/// staked, never a control (product call, 3 October 2026): it takes no
/// touch, so a tap on it opens the post like a tap anywhere on the card.
/// Part of the overlay rather than of the cell for the reason the overlay is
/// its own view: a flight's copy and a close's stand-in wear the heart too,
/// so nothing appears or changes colour in the landing frame.
public final class PostCardCaptionOverlay: UIView {
    public enum Placement: Sendable {
        /// Over media: white text on a dark scrim rising from the foot.
        case onMedia
        /// A text post: the card IS the words, so no scrim, and the caption
        /// takes the whole card rather than two lines of it.
        case onCard
    }

    /// How the white words over a picture keep off its bright patches,
    /// beyond the scrim.
    public enum TextShadow: Sendable {
        /// A soft shadow on each label's LAYER — the Following card's, as it
        /// always was. A layer shadow with no path is an offscreen pass per
        /// label per frame; a row of three cards affords it.
        case layer
        /// The same soft shadow drawn INTO the text (`NSShadow`), in the
        /// label's own backing store: no offscreen pass. What a mosaic tile
        /// wears — a screen of tiles is a dozen of these at once.
        case inline
    }

    /// Two lines over a picture — the product call: enough to know what the
    /// post is about, not so much that the picture is covered.
    nonisolated public static let mediaCaptionLines = 2
    /// A text post's words fill the card — the long press's preview of one
    /// (`ForYouPostPreviewViewController`), the only `.onCard` left since the
    /// Following row's text cards became the list's own card (2026-10-03).
    nonisolated public static let textCaptionLines = 7

    /// The fonts the overlay sets its words in.
    private static func captionFont(onMedia: Bool) -> UIFont {
        onMedia
            ? .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .medium)
            : .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
    }

    /// The scrim, as a VIEW: a bare sublayer's frame does not ride a UIKit
    /// animation block, so a scrim posed inside one jumped to its landing
    /// rect while the window it belongs to was still travelling.
    private let scrim = ScrimView()
    private let authorLabel = UILabel()
    /// The author's disc, before the name — initials, and the picture over
    /// them once it is here. Posed like the labels (bounds, centre,
    /// transform), so it rides a flight's window by its corner too.
    private let avatar = MonogramAvatarView(diameter: 16)
    private let avatarPicture = AvatarImageView()
    /// The picture's load. Holds the overlay weakly: a card recycled before it
    /// lands drops its overlay, and the picture goes nowhere.
    private var avatarTask: Task<Void, Never>?
    /// An `EmoteLabel`: the caption's emoji and `:code:` emotes animate on the
    /// card as they do on the list's cards (`PostGridListRowCell`), and only
    /// while the card is actually on screen (`EmoteVisibility`).
    private let captionLabel = EmoteLabel()
    private let placement: Placement
    /// The like — see the note on this type. Nil only where the card is
    /// shown without one (the long press's preview).
    public private(set) var likeReadout: PostLikeReadoutView?
    /// The size the words are wrapped at — see the note on this type. Nil:
    /// whatever size the overlay is.
    private let referenceSize: CGSize?
    /// The layout at the reference size, kept so a pose re-derives it only
    /// when the reference itself changes (the cell's, as the card resizes).
    private var restingLayout: RestingLayout?
    /// Whether the pieces have been posed at all. The first pose is never
    /// animated, whoever's block it lands in: a label with no frame yet would
    /// grow into its place out of a zero rect — the unfold this type exists to
    /// end.
    private var hasPosed = false

    /// - Parameter captionLines: how many lines of the caption to show. Nil:
    ///   the placement's own (`mediaCaptionLines`, `textCaptionLines`); a
    ///   mosaic tile asks for fewer as it gets smaller (`PostTileInfo`).
    /// - Parameter imagePipeline: where the author's picture comes from. Nil
    ///   draws the initials alone.
    /// - Parameter viewerStake: what the viewer has staked on the post — the
    ///   like closing the author line, red when there is any. Nil: no like.
    /// - Parameter textShadow: see `TextShadow`. Only drawn over a picture.
    public init(
        post: GalleryPost, placement: Placement, captionLines: Int? = nil, referenceSize: CGSize? = nil,
        imagePipeline: ImagePipeline? = nil, viewerStake: Int? = nil, textShadow: TextShadow = .layer
    ) {
        self.placement = placement
        let reference = referenceSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        self.referenceSize = reference
        super.init(frame: CGRect(origin: .zero, size: reference ?? .zero))
        isUserInteractionEnabled = false
        let onMedia = placement == .onMedia
        scrim.isHidden = !onMedia
        addSubview(scrim)
        authorLabel.font = Self.authorFont
        authorLabel.textColor = onMedia ? .white : .secondaryLabel
        let author = post.authorName ?? post.authorHandle.map { "@\($0)" }
        let diameter = Self.avatarDiameter(for: authorLabel.font)
        avatar.setDiameter(diameter)
        avatar.setMonogram(MonogramAvatarView.monogram(
            name: post.authorName ?? "", handle: post.authorHandle ?? ""
        ))
        avatar.isHidden = author == nil
        avatar.isUserInteractionEnabled = false
        // Over a picture the initials sit on the scrim, like the white name
        // beside them: drawn in the dark style, or a light-mode plate and ink
        // all but vanish into the photograph (seen on the simulator).
        if onMedia { avatar.overrideUserInterfaceStyle = .dark }
        avatarPicture.isHidden = true
        avatarPicture.pin(to: avatar)
        captionLabel.font = Self.captionFont(onMedia: onMedia)
        captionLabel.textColor = onMedia ? .white : .label
        captionLabel.numberOfLines = max(0, captionLines ?? (onMedia ? Self.mediaCaptionLines : Self.textCaptionLines))
        captionLabel.lineBreakMode = .byTruncatingTail
        // No lines asked for: no caption at all, rather than `numberOfLines`
        // 0's "as many as it takes".
        captionLabel.isHidden = captionLabel.numberOfLines == 0
        let caption = captionLabel.isHidden ? nil : post.caption
        if onMedia, textShadow == .inline {
            authorLabel.attributedText = author.map {
                NSAttributedString(string: $0, attributes: Self.inlineAttributes(
                    font: authorLabel.font, color: .white
                ))
            }
            captionLabel.attributedText = caption.map {
                EmoteText.attributedString($0, attributes: Self.inlineAttributes(
                    font: captionLabel.font, color: .white
                ), catalog: captionLabel.engine.catalog)
            }
        } else {
            authorLabel.text = author
            captionLabel.text = caption
            for label in [authorLabel, captionLabel] where onMedia {
                label.layer.shadowColor = UIColor.black.cgColor
                label.layer.shadowOpacity = Self.shadowOpacity
                label.layer.shadowRadius = Self.shadowRadius
                label.layer.shadowOffset = .zero
            }
        }
        addSubview(captionLabel)
        addSubview(avatar)
        addSubview(authorLabel)
        loadAvatar(post.authorAvatarURL, from: imagePipeline)
        if let viewerStake {
            // Over the picture or on the card, in the author line's type so
            // the two read as one line.
            let like = PostLikeReadoutView(
                ground: onMedia ? .media : .card, font: authorLabel.font
            )
            like.setCount(post.reactionCount)
            like.setViewerStake(viewerStake)
            addSubview(like)
            likeReadout = like
        }
    }

    /// The author line's type.
    public static var authorFont: UIFont {
        .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
    }

    /// The caption's type over a picture.
    public static var mediaCaptionFont: UIFont { captionFont(onMedia: true) }

    /// How tall the words stand over a picture's foot with `captionLines`
    /// lines of caption — the inset, the lines, the author's line above them.
    /// The scrim is not counted: it fades to nothing at its top.
    public static func mediaTextHeight(captionLines: Int) -> CGFloat {
        let caption = captionLines > 0
            ? (mediaCaptionFont.lineHeight * CGFloat(captionLines)).rounded(.up)
            : 0
        return inset + caption + 2 + authorFont.lineHeight.rounded(.up)
    }

    private static let shadowOpacity: Float = 0.35
    private static let shadowRadius: CGFloat = 2

    /// White type with the layer shadow's look drawn into the glyphs —
    /// `TextShadow.inline`.
    private static func inlineAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(CGFloat(shadowOpacity))
        shadow.shadowBlurRadius = shadowRadius
        shadow.shadowOffset = .zero
        return [.font: font, .foregroundColor: color, .shadow: shadow]
    }

    /// What the viewer has staked on the post, now — the heart's colour. Its
    /// size does not change with it, so nothing is laid out again.
    public func setViewerStake(_ total: Int) {
        likeReadout?.setViewerStake(total)
    }

    /// The post's like count, now — a count of another width re-lays the
    /// author line (unanimated, like the first pass).
    public func setLikeCount(_ count: Int64?) {
        guard let likeReadout else { return }
        let before = likeReadout.fittedSize
        likeReadout.setCount(count)
        guard likeReadout.fittedSize != before else { return }
        restingLayout = nil
        hasPosed = false
        setNeedsLayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The disc is exactly as tall as the name's line: the face and the name
    /// read as one line of type, not as an avatar with a caption.
    public static func avatarDiameter(for font: UIFont) -> CGFloat {
        font.lineHeight.rounded(.up)
    }

    /// The gap between the disc and the name.
    private static let avatarGap: CGFloat = 5

    /// The picture over the initials: from memory at once when the pipeline
    /// has it — every copy of a card the row has drawn — else when it lands.
    /// The initials stay under it, the rendered state (the app's avatar
    /// contract), so a face that never arrives costs nothing.
    private func loadAvatar(_ url: URL?, from imagePipeline: ImagePipeline?) {
        guard let url, let imagePipeline, !avatar.isHidden else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            showAvatar(cached)
            return
        }
        avatarTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled,
                  let self else { return }
            showAvatar(image)
        }
    }

    private func showAvatar(_ image: UIImage) {
        avatarPicture.image = image
        avatarPicture.isHidden = false
        // A covered disc draws the picture alone, no plate rim around it.
        avatar.isCovered = true
    }

    private static let inset: CGFloat = 10
    /// The least air between the name and the heart closing its line.
    private static let likeGap: CGFloat = 8

    /// Where each piece sits on a card of `size`, in that card's space.
    private struct RestingLayout {
        let size: CGSize
        let caption: CGRect
        let author: CGRect
        /// The author's disc, on the name's line, before it.
        let avatar: CGRect
        /// The like, closing the name's line; `.null` without one.
        let like: CGRect
        /// The scrim's top edge; it always runs to the card's foot.
        let scrimTop: CGFloat
    }

    private func restingLayout(for size: CGSize) -> RestingLayout {
        let inset = Self.inset
        let width = max(0, size.width - inset * 2)
        let authorHeight = authorLabel.font.lineHeight.rounded(.up)
        // The name's line starts after the disc; the caption keeps the card's
        // whole width.
        let face = avatar.isHidden ? 0 : Self.avatarDiameter(for: authorLabel.font) + Self.avatarGap
        // The heart ends on the card's inset, like the caption's.
        let likeSize = likeReadout?.fittedSize ?? .zero
        let authorWidth = max(0, width - face - (likeSize.width > 0 ? likeSize.width + Self.likeGap : 0))
        func disc(on line: CGRect) -> CGRect {
            let side = Self.avatarDiameter(for: authorLabel.font)
            return CGRect(x: inset, y: line.midY - side / 2, width: side, height: side)
        }
        func like(on line: CGRect) -> CGRect {
            guard likeSize.width > 0 else { return .null }
            return CGRect(
                x: size.width - inset - likeSize.width,
                y: line.midY - likeSize.height / 2,
                width: likeSize.width, height: likeSize.height
            )
        }
        let fitted = captionLabel.isHidden ? 0 : captionLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height.rounded(.up)
        switch placement {
        case .onMedia:
            // From the foot up: the caption's lines, the author above them.
            let caption = CGRect(
                x: inset, y: size.height - inset - fitted, width: width, height: fitted
            )
            let author = CGRect(
                x: inset + face, y: caption.minY - 2 - authorHeight, width: authorWidth, height: authorHeight
            )
            // The scrim reaches a little above the author, so the text never
            // sits on the picture's own brightness.
            return RestingLayout(
                size: size, caption: caption, author: author, avatar: disc(on: author),
                like: like(on: author), scrimTop: max(0, author.minY - 36)
            )
        case .onCard:
            // The words from the top, the author at the foot.
            let author = CGRect(
                x: inset + face, y: size.height - inset - authorHeight, width: authorWidth, height: authorHeight
            )
            let available = author.minY - inset * 2
            let caption = CGRect(
                x: inset, y: inset + 2, width: width, height: min(fitted, max(0, available))
            )
            return RestingLayout(
                size: size, caption: caption, author: author, avatar: disc(on: author),
                like: like(on: author), scrimTop: size.height
            )
        }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let reference = referenceSize ?? bounds.size
        if restingLayout?.size != reference {
            restingLayout = restingLayout(for: reference)
        }
        guard let resting = restingLayout, resting.size.width > 0 else { return }
        if hasPosed {
            pose(resting)
        } else {
            hasPosed = true
            // The disc's own insides (initials, picture) too: laid out by
            // constraints in a pass that would otherwise run AFTER this one,
            // inside whatever block is open, and grow out of a zero rect.
            UIView.performWithoutAnimation {
                pose(resting)
                avatar.layoutIfNeeded()
            }
        }
    }

    /// Every piece at its resting layout, scaled by the window's width over
    /// the card's and pinned to the edge it belongs to — which is exactly the
    /// resting layout when the overlay is the card's own size.
    ///
    /// By `bounds`/`center`/`transform`, never `frame`: a label keeps the
    /// bounds it wrapped its words in, so nothing re-wraps and nothing is
    /// redrawn stretched. Only where a piece is and how large it is drawn
    /// move, and both ride whatever animation block is posing the window.
    private func pose(_ resting: RestingLayout) {
        let scale = bounds.width / resting.size.width
        func fromFoot(_ y: CGFloat) -> CGFloat { bounds.height - (resting.size.height - y) * scale }
        func place(_ view: UIView, _ rect: CGRect, atFoot: Bool) {
            view.bounds = CGRect(origin: .zero, size: rect.size)
            view.center = CGPoint(
                x: rect.midX * scale, y: atFoot ? fromFoot(rect.midY) : rect.midY * scale
            )
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        switch placement {
        case .onMedia:
            place(captionLabel, resting.caption, atFoot: true)
            place(authorLabel, resting.author, atFoot: true)
            place(avatar, resting.avatar, atFoot: true)
            if let likeReadout, !resting.like.isNull { place(likeReadout, resting.like, atFoot: true) }
            let top = fromFoot(resting.scrimTop)
            scrim.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        case .onCard:
            place(captionLabel, resting.caption, atFoot: false)
            place(authorLabel, resting.author, atFoot: true)
            place(avatar, resting.avatar, atFoot: true)
            if let likeReadout, !resting.like.isNull { place(likeReadout, resting.like, atFoot: true) }
        }
    }

    /// The scrim: a gradient that rides its view's animated frame.
    private final class ScrimView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            guard let gradient = layer as? CAGradientLayer else { return }
            gradient.colors = [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.35).cgColor,
                UIColor.black.withAlphaComponent(0.72).cgColor
            ]
            gradient.locations = [0, 0.45, 1]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    #if DEBUG
    /// Where the words are drawn, in this overlay's space — the anchoring a
    /// suite pins.
    public var debugCaptionFrame: CGRect { captionLabel.frame }
    public var debugAuthorFrame: CGRect { authorLabel.frame }
    /// The author's disc, and whether a picture covers its initials.
    public var debugAvatarFrame: CGRect { avatar.isHidden ? .null : avatar.frame }
    public var debugShowsAvatarPicture: Bool { !avatarPicture.isHidden && avatarPicture.image != nil }
    /// The width the caption is wrapped at — the card's, never the window's.
    public var debugCaptionWrapWidth: CGFloat { captionLabel.bounds.width }
    /// The most lines the words may take, the height they are drawn in, and
    /// one line's height.
    public var debugCaptionLines: Int { captionLabel.numberOfLines }
    public var debugCaptionHeight: CGFloat { captionLabel.bounds.height }
    public var debugCaptionLineHeight: CGFloat { captionLabel.font.lineHeight }
    /// Where the heart is drawn, in this overlay's space — `.null` without one.
    public var debugLikeFrame: CGRect { likeReadout.map { $0.isHidden ? .null : $0.frame } ?? .null }
    /// The words as drawn: the author line, and the caption (nil when the
    /// overlay shows none).
    public var debugAuthorText: String? { authorLabel.attributedText?.string ?? authorLabel.text }
    public var debugCaptionText: String? {
        captionLabel.isHidden ? nil : (captionLabel.attributedText?.string ?? captionLabel.text)
    }
    /// How many caption lines the overlay allows — 0 when it shows none.
    public var debugCaptionLineLimit: Int { captionLabel.isHidden ? 0 : captionLabel.numberOfLines }
    /// How many lines the caption actually takes at its resting width.
    public var debugCaptionRenderedLines: Int {
        guard !captionLabel.isHidden, captionLabel.bounds.height > 0 else { return 0 }
        return Int((captionLabel.bounds.height / captionLabel.font.lineHeight).rounded())
    }
    /// Whether any label draws its shadow on its LAYER — an offscreen pass.
    public var debugUsesLayerShadows: Bool {
        [authorLabel, captionLabel].contains { $0.layer.shadowOpacity > 0 }
    }
    #endif
}
