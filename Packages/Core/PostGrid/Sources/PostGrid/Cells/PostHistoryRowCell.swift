import CoreModels
import DesignSystem
import EmoteKit
import MediaCore
import UIKit
import VoiceKitUI

/// ONE POST PER ROW (the owner, 2026-11-07, #2170) — the profile's History,
/// as the owner drew it:
///
/// ```
///   ┌────────┐  Title ·····························  2h
///   │ square │
///   │ media  │  (◯) Author ·······················  ♥ 1.2K
///   └────────┘
/// ```
///
/// - The square is the post's first page, centre-cropped, as tall as the two
///   lines beside it plus their padding and never under `minimumSquareSide`
///   — so it grows with the text size. A still, always: a row never plays
///   (it is not a `GridPlaybackCell`, so autoplay never picks it). A text
///   post draws its own text tile in miniature (`PostHistorySquareView`).
/// - Line 1: the caption's first line, truncated at the end, then when the
///   viewer VIEWED it — never truncated.
/// - Line 2: the author (the app's avatar, no relation badge, and the name,
///   truncated), then the likes as the cards show them — never truncated.
/// - At a large text size the trailing values go UNDER the leading ones
///   rather than crush the title to nothing (`wrapsTrailing`).
///
/// A list cell (`UICollectionViewListCell`) so the list's own trailing swipe
/// works on it. The author is a person beside content (#2145): a tap is the
/// profile card, a hold the profile (`PersonOpening`).
public final class PostHistoryRowCell: UICollectionViewListCell {
    public static let reuseID = "PostHistoryRowCell"

    // MARK: - Metrics

    /// The square is never smaller than this (#2170).
    public static let minimumSquareSide: CGFloat = 56
    /// Above and below the two lines, inside the square's height.
    public static let verticalPadding: CGFloat = Spacing.xs
    /// Between the two lines.
    public static let lineGap: CGFloat = Spacing.xs
    /// Between the square and the text (#2170).
    public static let mediaTextGap: CGFloat = Spacing.md
    /// Between a leading value and its trailing one on a line.
    public static let trailingGap: CGFloat = Spacing.sm
    /// The share of the text column the trailing values may take on a line
    /// before they wrap under the leading ones.
    public static let trailingShareLimit: CGFloat = 0.4

    /// The title's face: `.body` semibold on the app's scale (#2149).
    public static func titleFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        .scaledSystemFont(
            ofSize: UIFont.defaultPointSize(for: .body), weight: .semibold, relativeTo: .body,
            compatibleWith: traits
        )
    }

    /// The view time's, the author's and the likes' face: `.footnote`.
    public static func detailFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        .appFont(forTextStyle: .footnote, compatibleWith: traits)
    }

    /// The author's disc: the detail line's height, never under 16 pt.
    public static func avatarDiameter(detailFont: UIFont) -> CGFloat {
        max(16, detailFont.lineHeight.rounded(.up))
    }

    /// The square's side for these faces — the two lines (each trailing
    /// value under its line when `wraps`), their gap and padding — never
    /// under `minimumSquareSide`.
    ///
    /// A voice post's first line is its voice (#2208): `speaks` measures it
    /// at the compact panel's height (#2241) when that is taller than the
    /// title's line.
    public static func squareSide(titleFont: UIFont, detailFont: UIFont, wraps: Bool, speaks: Bool = false) -> CGFloat {
        let detailLine = detailFont.lineHeight.rounded(.up)
        let titleLine = titleFont.lineHeight.rounded(.up)
        let panel: CGFloat = VoiceView.panelHeight(for: .compact)
        let firstLine: CGFloat = speaks ? max(titleLine, panel) : titleLine
        let first: CGFloat = firstLine + (wraps ? detailLine : 0)
        let second = avatarDiameter(detailFont: detailFont) + (wraps ? detailLine : 0)
        let side = verticalPadding * 2 + first + lineGap + second
        return max(minimumSquareSide, side.rounded(.up))
    }

    /// Whether the trailing values go under the leading ones: when the wider
    /// of them would take more than `trailingShareLimit` of the text column.
    public static func wrapsTrailing(textWidth: CGFloat, trailingWidth: CGFloat) -> Bool {
        guard textWidth > 0 else { return false }
        return trailingWidth + trailingGap > textWidth * trailingShareLimit
    }

    /// A row's title: the caption's FIRST line, trimmed; empty for none.
    public static func title(for post: GalleryPost) -> String {
        let firstLine = post.caption.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// When the post was viewed, as the row writes it: the app's short
    /// relative age ("2h", "3d", "1w").
    public static func viewedText(_ viewedAt: Date?, now: Date) -> String? {
        viewedAt.map { RelativeAgeFormatter.short(from: $0, to: now) }
    }

    // MARK: - Accessibility

    /// VoiceOver's one element (#2170): "title, by author, viewed 2 hours
    /// ago, 1,200 likes" — what is absent is left out.
    ///
    /// A voice post's row (#2208) opens on its voice: "Voice post, 13
    /// seconds, From the ridge, by …".
    ///
    /// A showcase's row (#2216) names its card after the words: "Boats in at
    /// six, Channel Harbour notes, 12.4K subscribers, by …".
    public static func accessibilityLabel(
        for post: GalleryPost, viewedAt: Date?, now: Date, speaks: Bool = false, showsEmbed: Bool = false
    ) -> String {
        var parts: [String] = []
        let title = title(for: post)
        if showsEmbed, let channel = post.embed?.channel {
            if !title.isEmpty { parts.append(title) }
            parts.append(ChannelEmbedCopy.accessibilityLabel(ChannelEmbedLocalState.applied(to: channel)))
        } else if speaks, let voice = post.voice {
            parts.append(VoiceView.accessibilityLabel(
                role: .post(author: nil), senderName: nil, duration: voice.duration, unplayed: false
            ))
            if !title.isEmpty { parts.append(title) }
        } else {
            parts.append(title.isEmpty ? kindName(post) : title)
        }
        if let author = post.authorName ?? post.authorHandle.map({ "@\($0)" }), !author.isEmpty {
            parts.append("by \(author)")
        }
        if let viewedAt { parts.append("viewed \(spokenAge(of: viewedAt, now: now))") }
        if let likes = post.reactionCount {
            let number = NumberFormatter.localizedString(from: NSNumber(value: likes), number: .decimal)
            parts.append(likes == 1 ? "\(number) like" : "\(number) likes")
        }
        return parts.joined(separator: ", ")
    }

    /// What a post with no caption is called aloud.
    static func kindName(_ post: GalleryPost) -> String {
        if post.isCollection { return "Carousel" }
        switch post.kind {
        case .video: return "Video"
        case .photo: return "Photo"
        case .text: return "Text post"
        }
    }

    /// The view time spelled out: "just now", "2 hours ago".
    static func spokenAge(of date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The VoiceOver action that stands for the author's hold
    /// (`PersonOpening`'s name).
    public static let openProfileActionName = PersonOpening.openProfileActionName

    // MARK: - Events

    /// A tap on the author: the profile card (#2145).
    public var onAuthorTapped: (() -> Void)? {
        didSet { opening.openCard = onAuthorTapped }
    }
    /// A hold on the author: the profile, pushed (#2145). Also VoiceOver's
    /// "Open profile".
    public var onAuthorHeld: (() -> Void)? {
        didSet {
            opening.openProfile = onAuthorHeld
            refreshAccessibilityActions()
        }
    }
    // MARK: - The select mode (the profile's History, 2026-11-08)

    /// The selection circle's side, and the room either side of it — from
    /// the row's leading edge, and to the square (the owner: the circle
    /// centred in its gap, not against the picture).
    public static let selectionMarkSide: CGFloat = 24
    public static let selectionMarkGap: CGFloat = 16
    /// How far the square, the title and the author slide to make room.
    public static var selectionShift: CGFloat { selectionMarkSide + selectionMarkGap }
    /// The fade the title and the name melt into, just before the time and
    /// the likes, which stay where they are.
    static let selectionFade: CGFloat = 28

    private let selectionMark = UIImageView()
    public private(set) var isSelecting = false
    private var isSelectedRow = false

    /// The select mode (the list editing): the square, the title and the
    /// author slide right for the circle while the time and the likes stay;
    /// the title is not cut a second time — it fades into them. The author
    /// rests, so a tap on it selects the row as anywhere else does.
    override public func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        authorView.isUserInteractionEnabled = !state.isEditing
        // A press in the select mode selects the row, the card's button
        // included (#2216).
        isEditingRows = state.isEditing
        syncEmbedInteraction()
        let selected = state.isEditing && state.isSelected
        if selected != isSelectedRow {
            isSelectedRow = selected
            applySelectionMark(animated: window != nil && state.isEditing)
        }
        accessibilityTraits = selected ? [.button, .selected] : .button
        guard state.isEditing != isSelecting else { return }
        isSelecting = state.isEditing
        let animated = window != nil && !MotionPreference.reducesMotion
        // Laid out first, outside any animation: the circle is where it
        // belongs before it fades and grows in.
        UIView.performWithoutAnimation { contentView.layoutIfNeeded() }
        placeSelectionMark()
        applySelectionFades()
        let place = { self.applySelectionPlacement() }
        guard animated else { return place() }
        UIView.animate(springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState], animations: place)
    }

    /// The circle — empty, or the brand's check — swapped by the symbol's
    /// own Replace.
    private func applySelectionMark(animated: Bool) {
        let image = UIImage(systemName: isSelectedRow ? "checkmark.circle.fill" : "circle")
        selectionMark.tintColor = isSelectedRow ? Palette.tint : .tertiaryLabel
        if animated, !MotionPreference.reducesMotion, let image {
            selectionMark.setSymbolImage(image, contentTransition: .replace)
        } else {
            selectionMark.image = image
        }
    }

    /// Where the slid parts and the circle stand for the mode.
    private func applySelectionPlacement() {
        let shift = isSelecting ? CGAffineTransform(translationX: Self.selectionShift * layoutSign, y: 0) : .identity
        for view in [square as UIView, titleLabel, voiceCaption, embedCard, authorView] { view.transform = shift }
        selectionMark.alpha = isSelecting ? 1 : 0
        selectionMark.transform = isSelecting ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
    }

    private var layoutSign: CGFloat { effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1 }

    /// The circle at the row's leading edge — the list's margin before it,
    /// the same gap after it to the slid square — centred on the square.
    ///
    /// ⚠️ NEVER INSIDE AN ANIMATION (the owner, 2026-11-08): the list lays
    /// its rows out inside its editing transition, and the circle's first
    /// frame then grew from the row's top-left corner. It is placed at once;
    /// only its alpha and scale spring.
    private func placeSelectionMark() {
        let side = Self.selectionMarkSide
        let x = layoutSign > 0 ? 0 : contentView.bounds.width - side
        UIView.performWithoutAnimation {
            selectionMark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            selectionMark.center = CGPoint(x: x + side / 2, y: square.center.y)
        }
    }

    /// The title and the name melt into the time and the likes while they
    /// are slid (a mask on each, in its own space); nothing at rest.
    private func applySelectionFades() {
        guard isSelecting else {
            titleLabel.layer.mask = nil
            authorView.layer.mask = nil
            return
        }
        fade(titleLabel, before: timeLabel.isHidden || wrapsTrailingValues ? nil : timeLabel)
        fade(authorView, before: likes.isHidden || wrapsTrailingValues ? nil : likes)
    }

    /// Masks `view` to melt away just before `neighbour` (the row's end
    /// without one), as it stands once slid.
    private func fade(_ view: UIView, before neighbour: UIView?) {
        guard let container = view.superview, view.bounds.width > 0 else { return }
        let width = view.bounds.width
        // Its laid-out place, whatever transform it wears.
        let origin = view.center.x - width / 2
        let end: CGFloat
        if let neighbour, neighbour.superview === container {
            end = neighbour.center.x - neighbour.bounds.width / 2 - Spacing.xs
        } else {
            end = contentView.convert(CGPoint(x: contentView.bounds.maxX, y: 0), to: container).x
        }
        let localEnd = (end - origin - Self.selectionShift) / width
        let localStart = localEnd - Self.selectionFade / width
        guard localEnd < 1 else { view.layer.mask = nil; return }
        let mask = (view.layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        let start = max(0, min(1, localStart)), finish = max(0, min(1, localEnd))
        let flipped = layoutSign < 0
        mask.locations = (flipped
            ? [0, 1 - finish, 1 - start, 1].map { NSNumber(value: Double($0)) }
            : [0, start, finish, 1].map { NSNumber(value: Double($0)) })
        if flipped { mask.colors = mask.colors?.reversed() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = view.bounds
        CATransaction.commit()
        view.layer.mask = mask
    }

    /// Whether the circle shows, and checked.
    public var debugSelectionMark: (shown: Bool, checked: Bool) { (isSelecting && selectionMark.alpha > 0, isSelectedRow) }
    /// The circle's frame and the square's, in the row's space, as drawn.
    public var debugSelectionFrames: (mark: CGRect, square: CGRect) {
        (selectionMark.frame, square.frame)
    }
    /// Whether the title melts away (a mask) now.
    public var debugTitleFades: Bool { titleLabel.layer.mask != nil }

    /// The row's action for VoiceOver — its menu's first row: its title and
    /// what it does, the page's; nil for none.
    public var rowAction: (title: String, perform: () -> Void)? {
        didSet { refreshAccessibilityActions() }
    }
    /// The cover landed.
    public var onCoverLoaded: (() -> Void)? {
        get { square.onCoverLoaded }
        set { square.onCoverLoaded = newValue }
    }

    // MARK: - Views

    private let square = PostHistorySquareView()
    private let titleLabel = EmoteLabel()
    /// A voice post's first line (#2208, behind `-voice-posts`): the shared
    /// voice component, compact (#2241), in the title's place — the panel
    /// across the line up to the time, the post's words in the square's
    /// miniature, under it in reading order.
    private let voiceCaption = VoicePostCaptionView()
    /// A showcase's card (#2216, behind `-channels`): the shared embed card,
    /// full size, under the title — the author's words stay on the first
    /// line, the card takes the room under them, the author's line under it.
    /// The row grows for it; the square keeps its side, at the row's top.
    private let embedCard = PostEmbedView()
    /// Whether the list is in its select mode.
    private var isEditingRows = false
    /// The column's two placings: centred on the square (every row), or
    /// hung from the row's top with the row closing under it (a showcase's,
    /// taller than the square).
    private var columnCentred: NSLayoutConstraint?
    private var squareClosesRow: NSLayoutConstraint?
    private var embedPlacing: [NSLayoutConstraint] = []
    private weak var linesColumn: UIStackView?
    private let timeLabel = UILabel()
    private let authorView = UIView()
    private let avatar = AvatarView(diameter: 16, size: .avatar)
    private let nameLabel = UILabel()
    private let likes: PostMetricLabel
    private let firstLine: UIStackView
    private let secondLine: UIStackView
    private lazy var opening = PersonOpening(on: authorView)

    private var squareSide: NSLayoutConstraint?
    private var titleHeight: NSLayoutConstraint?
    private var avatarSide: NSLayoutConstraint?
    private var post: GalleryPost?
    private var viewedAt: Date?
    /// The width the trailing values were last decided for.
    private var wrapWidth: CGFloat = -1
    /// Whether the trailing values sit under the leading ones now.
    public private(set) var wrapsTrailingValues = false

    override public init(frame: CGRect) {
        // The count, then the heart: "1.2K ♥" (the owner, 2026-11-07).
        likes = PostMetricLabel(
            symbol: LikesSymbol.glyph, font: Self.detailFont(), color: .secondaryLabel, glyphTrailing: true
        )
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        firstLine = UIStackView()
        secondLine = UIStackView()
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        // The row's own words: VoiceOver reads it as ONE element (#2170).
        isAccessibilityElement = true
        accessibilityTraits = .button

        square.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(square)
        selectionMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        selectionMark.contentMode = .center
        selectionMark.alpha = 0
        selectionMark.isAccessibilityElement = false
        contentView.addSubview(selectionMark)
        applySelectionMark(animated: false)

        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        // `@handle`s and `#tag`s as captions draw them (#524).
        titleLabel.textEntityStyle = .link
        titleLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        likes.setContentHuggingPriority(.required, for: .horizontal)
        likes.setContentCompressionResistancePriority(.required, for: .horizontal)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        authorView.addSubview(avatar)
        authorView.addSubview(nameLabel)
        authorView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        authorView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        voiceCaption.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        voiceCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (line, views) in [
            (firstLine, [titleLabel, voiceCaption, timeLabel]), (secondLine, [authorView, spacer, likes]),
        ] {
            views.forEach(line.addArrangedSubview)
            line.spacing = Self.trailingGap
        }
        embedCard.isHidden = true
        let column = UIStackView(arrangedSubviews: [firstLine, embedCard, secondLine])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Self.lineGap
        // The card's own air after it; before it, set as it shows
        // (`applyEmbed`) — a custom spacing after the title's line would
        // also stand between the two lines of a row with no card.
        column.setCustomSpacing(Self.embedGap, after: embedCard)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        linesColumn = column

        let side = square.heightAnchor.constraint(equalToConstant: Self.minimumSquareSide)
        // ONE line, exactly: a caption with no words keeps it, and one whose
        // emotes are drawn by the label's own text layout cannot make it
        // taller than the line the square was measured for.
        let titleHeight = titleLabel.heightAnchor.constraint(equalToConstant: 0)
        let avatarSide = avatar.widthAnchor.constraint(equalToConstant: 16)
        // The square IS the row's height; the self-sizing pass reads it.
        let bottom = square.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottom.priority = .required - 1
        let centred = column.centerYAnchor.constraint(equalTo: square.centerYAnchor)
        // A showcase's row: the column from the row's top, at the lines'
        // padding, and the row closing under whichever is taller.
        let columnBottom = column.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding
        )
        columnBottom.priority = .required - 1
        embedPlacing = [
            column.topAnchor.constraint(equalTo: square.topAnchor, constant: Self.verticalPadding),
            columnBottom,
            square.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            square.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            square.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
            square.widthAnchor.constraint(equalTo: square.heightAnchor),
            side,
            column.leadingAnchor.constraint(equalTo: square.trailingAnchor, constant: Self.mediaTextGap),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            centred,
            column.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            titleHeight,
            avatar.leadingAnchor.constraint(equalTo: authorView.leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: authorView.centerYAnchor),
            avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),
            avatarSide,
            authorView.heightAnchor.constraint(greaterThanOrEqualTo: avatar.heightAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: authorView.trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: authorView.centerYAnchor),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: authorView.topAnchor),
        ])
        squareSide = side
        columnCentred = centred
        squareClosesRow = bottom
        self.titleHeight = titleHeight
        self.avatarSide = avatarSide
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: PostHistoryRowCell, _) in
            cell.applyFonts()
        }
        // The author's tap and hold, attached once.
        _ = opening
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Configure

    /// Dresses the row for `post`, viewed at `viewedAt` (nil: no time),
    /// read against `now`.
    public func configure(
        with post: GalleryPost, viewedAt: Date?, now: Date = Date(), imagePipeline: ImagePipeline?,
        showsVoice: Bool = VoicePostDisplay.areDrawn, showsEmbed: Bool = PostEmbeds.areDrawn
    ) {
        self.post = post
        self.viewedAt = viewedAt
        // A showcase's card outranks a voice (#2216), as on the list's card.
        let embedSize = Self.embedSize(for: post, showsEmbed: showsEmbed)
        let voiced = embedSize == nil && Self.voiceSize(for: post, showsVoice: showsVoice) != nil
        square.configure(with: post, imagePipeline: imagePipeline, speaks: voiced)
        applyVoice(voiced ? post : nil)
        applyEmbed(embedSize, for: post, imagePipeline: imagePipeline)
        // A post with no caption keeps the line's height (`titleHeight`).
        titleLabel.attributedText = nil
        titleLabel.text = Self.title(for: post)
        // ⚠️ AFTER the text: an emote caption is attributed text whose
        // paragraph style resets the label's line break (to wrapping), and a
        // recycled row then CLIPPED its next title mid-word instead of
        // ending it on "…" — seen on the simulator.
        titleLabel.lineBreakMode = .byTruncatingTail
        let viewed = Self.viewedText(viewedAt, now: now)
        timeLabel.text = viewed
        timeLabel.isHidden = viewed == nil
        let author = post.authorName ?? post.authorHandle.map { "@\($0)" }
        nameLabel.text = author
        avatar.setMonogram(MonogramAvatarView.monogram(name: post.authorName ?? "", handle: post.authorHandle ?? ""))
        avatar.setPicture(post.authorAvatarURL, pipeline: imagePipeline)
        authorView.isHidden = author == nil
        // No person, no action (#2145): read as the gesture fires.
        let hasAuthor = post.authorID != nil
        opening.hasPerson = { hasAuthor }
        likes.set(post.reactionCount)
        accessibilityLabel = Self.accessibilityLabel(
            for: post, viewedAt: viewedAt, now: now, speaks: voiced, showsEmbed: showsCard
        )
        wrapWidth = -1
        setNeedsLayout()
    }

    // MARK: - A voice post (#2208)

    /// The size a row gives a voice post's caption, for a text post that
    /// speaks with the switch on: compact (#2241, the issue's table) — the
    /// shorter panel keeps a history row a list row. Pure.
    public static func voiceSize(for post: GalleryPost, showsVoice: Bool) -> VoicePostDisplay.Size? {
        showsVoice && post.kind == .text && post.voice != nil ? .compact : nil
    }

    /// Whether the first line is a voice now.
    private var speaks: Bool { !voiceCaption.isHidden }

    /// ⚠️ ITS DRAGS ARE ITS OWN, compact as it is (#2275, the owner's
    /// recording): nothing scrolls sideways under a history row, so a
    /// sideways drag on the panel scrubs and the pager around the list (the
    /// profile's Posts | Saved | History) waits for it; a vertical drag
    /// still scrolls the list, and one beside the panel still pages.
    static let voiceDragsAreOwn = true

    private func applyVoice(_ post: GalleryPost?) {
        if let post, let voice = post.voice {
            voiceCaption.show(
                postID: post.id.rawValue, url: voice.url, duration: voice.duration, levels: voice.waveform,
                author: post.authorName, size: Self.voiceSize(for: post, showsVoice: true) ?? .compact,
                dragsAreOwn: Self.voiceDragsAreOwn
            )
        } else {
            voiceCaption.clear()
        }
        titleLabel.isHidden = speaks
        refreshAccessibilityActions()
        applyWrap(wrapsTrailingValues)
    }

    /// The row left the screen (a list's `didEndDisplaying`): a voice it
    /// plays stops where it is, unless the post's page shows it.
    public func voiceDidEndDisplaying() {
        voiceCaption.leftScreen()
    }

    // MARK: - A showcase (#2216)

    /// Between the title's line and the card, and the card and the author.
    public static let embedGap: CGFloat = Spacing.sm

    /// The size a row gives a showcase's embed: full, under the title, for a
    /// text post with one and the switch on. Pure.
    public static func embedSize(for post: GalleryPost, showsEmbed: Bool) -> PostEmbeds.Size? {
        post.kind == .text && PostEmbeds.shown(post.embed, drawn: showsEmbed) != nil ? .full : nil
    }

    /// Whether the row draws a showcase's card now.
    private var showsCard: Bool { !embedCard.isHidden }

    private func applyEmbed(_ size: PostEmbeds.Size?, for post: GalleryPost?, imagePipeline: ImagePipeline?) {
        if let size, let embed = post?.embed {
            embedCard.show(embed, size: size, pipeline: imagePipeline)
            // The row's one VoiceOver element follows the card's answer.
            embedCard.onEmbedChange = { [weak self] _ in self?.refreshEmbedAccessibility() }
        } else {
            embedCard.clear()
            embedCard.onEmbedChange = nil
        }
        // Taller than the square: the column hangs from the row's top and
        // closes it; otherwise centred on the square, as every row.
        linesColumn?.setCustomSpacing(showsCard ? Self.embedGap : Self.lineGap, after: firstLine)
        columnCentred?.isActive = !showsCard
        squareClosesRow?.isActive = !showsCard
        if showsCard { NSLayoutConstraint.activate(embedPlacing) } else { NSLayoutConstraint.deactivate(embedPlacing) }
        syncEmbedInteraction()
        refreshAccessibilityActions()
    }

    /// The card's button takes its tap out of the select mode only.
    private func syncEmbedInteraction() {
        embedCard.isUserInteractionEnabled = showsCard && !isEditingRows
    }

    private func refreshEmbedAccessibility() {
        guard let post else { return }
        accessibilityLabel = Self.accessibilityLabel(
            for: post, viewedAt: viewedAt, now: Date(), speaks: speaks, showsEmbed: showsCard
        )
        refreshAccessibilityActions()
    }

    /// New counters on the same post: the likes, and VoiceOver's words.
    public func updateCounts(from post: GalleryPost) {
        self.post = post
        likes.set(post.reactionCount)
        accessibilityLabel = Self.accessibilityLabel(
            for: post, viewedAt: viewedAt, now: Date(), speaks: speaks, showsEmbed: showsCard
        )
    }

    private func applyFonts() {
        let title = Self.titleFont(compatibleWith: traitCollection)
        let detail = Self.detailFont(compatibleWith: traitCollection)
        titleLabel.font = title
        timeLabel.font = detail
        nameLabel.font = detail
        likes.setFont(detail)
        titleHeight?.constant = title.lineHeight.rounded(.up)
        let diameter = Self.avatarDiameter(detailFont: detail)
        avatarSide?.constant = diameter
        avatar.setDiameter(diameter)
        wrapWidth = -1
        applyWrap(Self.wrapsTrailing(textWidth: textWidth(forRowWidth: bounds.width), trailingWidth: trailingWidth()))
        setNeedsLayout()
    }

    // MARK: - Wrapping at large sizes

    private func textWidth(forRowWidth width: CGFloat) -> CGFloat {
        let side = squareSide?.constant ?? Self.minimumSquareSide
        return width - side - Self.mediaTextGap
    }

    private func trailingWidth() -> CGFloat {
        max(
            timeLabel.isHidden ? 0 : timeLabel.intrinsicContentSize.width,
            likes.isHidden ? 0 : likes.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        )
    }

    /// Decides the lines' shape for a row `width` wide — once per width.
    private func decideWrap(forWidth width: CGFloat) {
        guard width > 0, abs(width - wrapWidth) > 0.5 else { return }
        wrapWidth = width
        applyWrap(Self.wrapsTrailing(textWidth: textWidth(forRowWidth: width), trailingWidth: trailingWidth()))
    }

    private func applyWrap(_ wraps: Bool) {
        wrapsTrailingValues = wraps
        for line in [firstLine, secondLine] {
            line.axis = wraps ? .vertical : .horizontal
            line.alignment = wraps ? .leading : .center
            line.spacing = wraps ? 0 : Self.trailingGap
        }
        // Centred, not on the first baseline: an emote caption is drawn by
        // the label's own text layout, whose baseline `UILabel` does not
        // report — the time stood a line above it (seen on the simulator).
        squareSide?.constant = Self.squareSide(
            titleFont: titleLabel.font ?? Self.titleFont(), detailFont: timeLabel.font ?? Self.detailFont(), wraps: wraps,
            speaks: speaks
        )
    }

    override public func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        decideWrap(forWidth: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    override public func layoutSubviews() {
        let before = wrapsTrailingValues
        decideWrap(forWidth: bounds.width)
        super.layoutSubviews()
        if before != wrapsTrailingValues { invalidateIntrinsicContentSize() }
        placeSelectionMark()
        if isSelecting { applySelectionFades() }
    }

    // MARK: - Accessibility actions

    private func refreshAccessibilityActions() {
        var actions: [UIAccessibilityCustomAction] = []
        // The row is one element: its voice plays through an action (#2208).
        if let player = voiceCaption.voiceView, speaks {
            actions.append(UIAccessibilityCustomAction(name: "Play or pause the voice") { [weak player] _ in
                player?.onPlayTap?()
                return player != nil
            })
        }
        // …and its showcase's card acts through one (#2216): "Join".
        if showsCard, case .channel(let channel)? = embedCard.embed, let action = channel.action {
            actions.append(UIAccessibilityCustomAction(name: ChannelEmbedCopy.title(for: action)) { [weak self] _ in
                guard let self else { return false }
                // Requested's tap is its cancel's confirmation, a menu
                // VoiceOver can't open from here: the cancel itself.
                if action == .requested { embedCard.cancelRequest() } else { embedCard.performAction() }
                return true
            })
        }
        if onAuthorHeld != nil {
            actions.append(UIAccessibilityCustomAction(name: Self.openProfileActionName) { [weak self] _ in
                guard let self, post?.authorID != nil, let onAuthorHeld else { return false }
                onAuthorHeld()
                return true
            })
        }
        if let rowAction {
            actions.append(UIAccessibilityCustomAction(name: rowAction.title) { _ in
                rowAction.perform()
                return true
            })
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
    }

    // MARK: - The hero (the square opens and closes the post)

    /// The square, in the cell's space — what the opening grows from and
    /// the close returns to (#2170).
    public var mediaHeroRect: CGRect {
        layoutIfNeeded()
        return contentView.convert(square.frame, to: self)
    }

    /// The square's view, for a lift.
    public var squareView: UIView { square }

    /// The author's disc and name — where the person's tap and hold are,
    /// which the row's long press leaves alone.
    public var authorHitView: UIView { authorView }

    /// The picture the square shows now; nil for a text post's tile.
    public var renderedCover: UIImage? { square.renderedCover }

    /// The square's corner, for whatever can only wear one (a flight, a
    /// window): the rounded tile's, at its side.
    public var squareCornerRadius: CGFloat {
        AvatarShape.roundedTile.cornerRadius(side: square.bounds.width)
    }

    /// Hides the square alone while its twin is in the air — the words stay.
    public func setHeroConcealed(_ concealed: Bool) {
        square.alpha = concealed ? 0 : 1
    }

    /// Whether the square is hidden for a flight or a window.
    public var isHeroMediaConcealed: Bool { square.alpha == 0 }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // A recycled row comes back whole: a flight's hide was the last
        // post's.
        isHidden = false
        alpha = 1
        square.alpha = 1
        square.reset()
        avatar.reset()
        onAuthorTapped = nil
        onAuthorHeld = nil
        rowAction = nil
        onCoverLoaded = nil
        // A voice it played stops: the row is another post's now (#2208).
        applyVoice(nil)
        // A showcase's card, and a write in flight for it, go too (#2216).
        applyEmbed(nil, for: nil, imagePipeline: nil)
        post = nil
        viewedAt = nil
    }

    #if DEBUG
    /// What the lines read, for tests.
    public var debugTitle: String? { titleLabel.text }
    /// The voice in the title's place, nil for none (#2208).
    public var debugVoiceCaption: VoicePostCaptionView? { speaks ? voiceCaption : nil }
    /// The voice part, shown or not — for a test to put its own hub in.
    public var debugVoicePart: VoicePostCaptionView { voiceCaption }
    /// Whether the title shows.
    public var debugShowsTitle: Bool { !titleLabel.isHidden }
    /// The showcase's card under the title, nil for none (#2216).
    public var debugEmbedCard: PostEmbedView? { showsCard ? embedCard : nil }
    public var debugViewedText: String? { timeLabel.isHidden ? nil : timeLabel.text }
    public var debugAuthor: String? { nameLabel.text }
    public var debugTitleLineBreakMode: NSLineBreakMode { titleLabel.lineBreakMode }
    public var debugLikes: String? { likes.debugText }
    /// The frames of the pieces, in the cell's space.
    public var debugFrames: (square: CGRect, title: CGRect, time: CGRect, author: CGRect, likes: CGRect) {
        layoutIfNeeded()
        return (
            mediaHeroRect, titleLabel.convert(titleLabel.bounds, to: self),
            timeLabel.convert(timeLabel.bounds, to: self), nameLabel.convert(nameLabel.bounds, to: self),
            likes.convert(likes.bounds, to: self)
        )
    }
    /// Whether the title's text is wider than its label (it truncates).
    public var debugTitleTruncates: Bool {
        layoutIfNeeded()
        return titleLabel.intrinsicContentSize.width > titleLabel.bounds.width + 0.5
    }
    /// The same for the time, the name and the likes.
    public var debugTimeTruncates: Bool {
        layoutIfNeeded()
        return timeLabel.intrinsicContentSize.width > timeLabel.bounds.width + 0.5
    }
    public var debugLikesTruncates: Bool {
        layoutIfNeeded()
        return likes.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width > likes.bounds.width + 0.5
    }
    /// The square's marks: a clip's play, a carousel's stack.
    public var debugMarks: (play: Bool, stack: Bool, textTile: Bool) { square.debugMarks }
    /// The play mark's box side.
    public var debugPlaySide: CGFloat { square.debugPlaySide }
    /// The play mark's image (the owner's play, #2276).
    public var debugPlayImage: UIImage? { square.debugPlayImage }
    /// Whether the heart comes after the like count.
    public var debugLikesGlyphTrails: Bool { likes.debugGlyphTrails }
    /// A tap and a hold on the author, as a finger's would land.
    public func debugTapAuthor() { opening.debugTap() }
    public func debugHoldAuthor() { opening.debugHold() }
    #endif
}

// MARK: - The square

/// A row's square (#2170): the post's first page, centre-cropped, on the
/// rounded tile's outline (`AvatarShape.roundedTile`, the app's small
/// tiles) — a clip with a small play mark, a carousel with the stack mark —
/// or, for a text post, its own text tile in miniature: the card's ground
/// and its first words. Also what a window closing onto the row carries
/// (`makeStandIn`), so the two ends are one picture.
public final class PostHistorySquareView: UIView {
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let playMark = UIImageView()
    private let stackMark = UIImageView()
    /// A voice alone's mark on its text tile (#2208).
    private let micMark = UIImageView()
    private let outline = CAShapeLayer()
    private let edge = CAShapeLayer()
    private lazy var media: MediaSurface = {
        let media = MediaSurface(cover: imageView, in: self, coverSize: .px256)
        media.debugLabel = "history-row"
        return media
    }()

    var onCoverLoaded: (() -> Void)? {
        get { media.onCoverLoaded }
        set { media.onCoverLoaded = newValue }
    }

    public init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Surface.mediaGround
        layer.mask = outline
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.pin(to: self)

        textLabel.textColor = .label
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isHidden = true
        addSubview(textLabel)

        // The clip's mark is the owner's play (#2276).
        for (mark, symbol) in [(playMark, AppSymbol.play.rawValue), (stackMark, "square.fill.on.square.fill")] {
            mark.image = UIImage.symbol(named: symbol)
            mark.tintColor = .white
            mark.contentMode = .center
            mark.isHidden = true
            // Over a white picture, the shadow keeps the white mark readable
            // without a plate — the tiles' counters' rule.
            mark.layer.shadowColor = UIColor.black.cgColor
            mark.layer.shadowOpacity = 0.5
            mark.layer.shadowRadius = 2
            mark.layer.shadowOffset = .zero
            addSubview(mark)
        }
        micMark.image = UIImage(systemName: "mic.fill")
        micMark.tintColor = VoiceView.ink
        micMark.contentMode = .center
        micMark.isHidden = true
        addSubview(micMark)
        // The card's dark-mode hairline, on the tile's own outline.
        edge.fillColor = UIColor.clear.cgColor
        layer.addSublayer(edge)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PostHistorySquareView, _) in
            view.resolveEdge()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A square for `post` as a cell draws it, its cover loaded through
    /// `imagePipeline`.
    func configure(with post: GalleryPost, imagePipeline: ImagePipeline?, speaks: Bool = false) {
        dress(for: post)
        // A voice alone (#2208): a mic in the text tile, where the words
        // would be; a voice with words keeps them.
        micMark.isHidden = !(speaks && post.kind == .text && textLabel.text?.isEmpty != false)
        guard post.kind != .text else {
            media.reset()
            return
        }
        let side = max(bounds.width, PostHistoryRowCell.minimumSquareSide)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        media.coverSize = PostGridTileCell.coverBucket(forDrawnSize: CGSize(width: side, height: side), scale: scale)
        media.loadCover(post.thumbnailURL, pipeline: imagePipeline, item: post.id)
    }

    /// The window's twin of a row's square: `post` with `cover` (the
    /// picture the row showed), `side` points square.
    public static func makeStandIn(for post: GalleryPost, cover: UIImage?, side: CGFloat) -> PostHistorySquareView {
        let view = PostHistorySquareView()
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.dress(for: post)
        // A window wears its own corner: the twin fills it edge to edge.
        view.layer.mask = nil
        view.edge.isHidden = true
        if post.kind != .text {
            view.imageView.image = cover
            view.imageView.alpha = 1
        }
        view.layoutIfNeeded()
        return view
    }

    private func dress(for post: GalleryPost) {
        let isText = post.kind == .text
        backgroundColor = PostGridTileCell.fillColor(for: post)
        imageView.isHidden = isText
        textLabel.isHidden = !isText
        textLabel.text = isText ? post.caption.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        playMark.isHidden = isText || post.kind != .video
        stackMark.isHidden = isText || !post.isCollection
        edge.isHidden = !isText
        setNeedsLayout()
    }

    func reset() {
        micMark.isHidden = true
        media.reset()
        imageView.image = nil
        textLabel.text = nil
    }

    var renderedCover: UIImage? { imageView.isHidden ? nil : media.renderedCover ?? imageView.image }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        let path = AvatarShape.roundedTile.path(in: bounds)
        outline.frame = bounds
        outline.path = path.cgPath
        edge.frame = bounds
        edge.path = path.cgPath
        resolveEdge()
        // The words at a size the square can hold — its own first words, as
        // a tile of its page would show them.
        let inset = (side * 0.12).rounded()
        textLabel.font = .systemFont(ofSize: max(7, (side * 0.15).rounded()), weight: .semibold)
        textLabel.frame = bounds.insetBy(dx: inset, dy: inset)
        let markSide = max(12, (side * 0.24).rounded())
        // The play mark a little bigger than the corner's stack mark (the
        // owner, 2026-11-07): it is the square's one sign of a clip.
        let playSide = max(14, (side * Self.playShare).rounded())
        playMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: playSide * 0.6, weight: .semibold)
        stackMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: markSide * 0.5, weight: .semibold)
        playMark.frame = CGRect(x: (side - playSide) / 2, y: (side - playSide) / 2, width: playSide, height: playSide)
        micMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: playSide * 0.6, weight: .semibold)
        micMark.frame = playMark.frame
        let corner = (side * 0.1).rounded()
        stackMark.frame = CGRect(x: side - markSide - corner / 2, y: corner / 2, width: markSide, height: markSide)
    }

    /// The play mark's box, as a share of the square's side: 0.34 (it was
    /// 0.24, the stack mark's; the owner asked twice for bigger,
    /// 2026-11-07).
    static let playShare: CGFloat = 0.34

    private func resolveEdge() {
        edge.lineWidth = Surface.hairline(for: traitCollection) * 2
        edge.strokeColor = Surface.cardEdge.resolvedColor(with: traitCollection).cgColor
    }

    #if DEBUG
    var debugPlaySide: CGFloat { playMark.frame.width }
    var debugPlayImage: UIImage? { playMark.image }

    var debugMarks: (play: Bool, stack: Bool, textTile: Bool) {
        (!playMark.isHidden, !stackMark.isHidden, !textLabel.isHidden)
    }
    #endif
}

// MARK: - The skeleton

/// A row's bones while History loads (#2170, sections by presence #1773):
/// the square, two bars and the author's small circle — at the row's own
/// height, so the rows land into the shape the bones drew.
public final class PostHistoryRowSkeletonCell: UICollectionViewCell {
    public static let reuseID = "PostHistoryRowSkeletonCell"

    private let square = SkeletonBoneView(rounding: .fixed(0))
    private let squareMask = CAShapeLayer()
    private let titleBar = SkeletonBoneView()
    private let avatarBone = SkeletonBoneView()
    private let authorBar = SkeletonBoneView()
    private var side: NSLayoutConstraint?
    private var titleWidth: NSLayoutConstraint?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        square.layer.mask = squareMask
        for bone in [square, titleBar, avatarBone, authorBar] {
            bone.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bone)
        }
        let side = square.heightAnchor.constraint(equalToConstant: PostHistoryRowCell.minimumSquareSide)
        let bottom = square.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottom.priority = .required - 1
        let text = square.trailingAnchor
        let titleWidth = titleBar.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: 0.55
        )
        NSLayoutConstraint.activate([
            square.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            square.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
            square.widthAnchor.constraint(equalTo: square.heightAnchor),
            side,
            titleBar.leadingAnchor.constraint(equalTo: text, constant: PostHistoryRowCell.mediaTextGap),
            titleBar.heightAnchor.constraint(equalToConstant: 12),
            titleWidth,
            titleBar.bottomAnchor.constraint(equalTo: square.centerYAnchor, constant: -PostHistoryRowCell.lineGap),
            avatarBone.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor),
            avatarBone.topAnchor.constraint(equalTo: square.centerYAnchor, constant: PostHistoryRowCell.lineGap),
            avatarBone.widthAnchor.constraint(equalToConstant: 16),
            avatarBone.heightAnchor.constraint(equalToConstant: 16),
            authorBar.leadingAnchor.constraint(equalTo: avatarBone.trailingAnchor, constant: 6),
            authorBar.centerYAnchor.constraint(equalTo: avatarBone.centerYAnchor),
            authorBar.heightAnchor.constraint(equalToConstant: 10),
            authorBar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.3),
        ])
        self.side = side
        self.titleWidth = titleWidth
        applySide()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: PostHistoryRowSkeletonCell, _) in
            cell.applySide()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The bones vary their title's length row to row, so a column of them
    /// reads as text rather than a pattern.
    public func configure(variant: Int) {
        guard let titleWidth else { return }
        let multiplier: CGFloat = [0.55, 0.42, 0.5][abs(variant) % 3]
        titleWidth.isActive = false
        let next = titleBar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: multiplier)
        next.isActive = true
        self.titleWidth = next
    }

    private func applySide() {
        side?.constant = PostHistoryRowCell.squareSide(
            titleFont: PostHistoryRowCell.titleFont(compatibleWith: traitCollection),
            detailFont: PostHistoryRowCell.detailFont(compatibleWith: traitCollection), wraps: false
        )
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        squareMask.frame = square.bounds
        squareMask.path = AvatarShape.roundedTile.path(in: square.bounds).cgPath
    }
}
