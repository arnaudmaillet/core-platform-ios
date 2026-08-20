import DesignSystem
import MediaCore
import MediaPlayback
import UIKit

// MARK: - Timeline row

/// One full-width row of the Activity/Short timelines: the caption with
/// reading padding on a soft card, plus — when the post carries media — a
/// rounded full-width preview under the text (play badge for videos), and a
/// quiet metadata line closing the card: views, reactions, comments on the
/// leading side, the post's compact age trailing. Short pages never have
/// media, so their rows are text + metadata.
public final class PostGridListRowCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    public static let reuseID = "PostGridListRowCell"
    /// The inner preview's rounding — the radius a hero flying from this row
    /// must start at, so the card is the preview's twin rather than its
    /// approximation.
    public static let mediaCornerRadius: CGFloat = 12

    /// Where the page STOPS MATCHING this card, in the card's own space — the
    /// reveal's cut line. Below it the destination is veiled for the length of
    /// a flight, so the window shows no more of itself than the card does.
    ///
    /// ## Two answers, one rule
    ///
    /// The rule is not about truncation, though it was written as if it were.
    /// A card shows a caption and a metric line; the page shows the same
    /// caption, the same metric line, and then its comments and its composer.
    /// The cut is wherever the two part company:
    ///
    /// * **Truncated caption** — they part at the card's fourth line, because
    ///   the page has a fifth. Measured on an iPhone SE, that is 103pt into a
    ///   145pt card, and 154pt of the page below it has no counterpart at all.
    /// * **Whole caption** — the caption matches AND the metric line matches
    ///   (the page's caption row borrows this cell's own constants, so the two
    ///   are the same layout at the same offsets — measured, a 101pt row
    ///   against a 101pt anchor). They part below the card's own bottom, where
    ///   the page keeps going into its comments.
    ///
    /// Answering `nil` for the second case is what this used to do, and it left
    /// a short post's comments on screen for the whole flight only to have them
    /// vanish in the final frame. There is no post for which the page and the
    /// card agree all the way down: the page always has a comment stream.
    ///
    /// MEASURED, never read off a subview's frame — see the note in
    /// `captionEnd` below, and `CaptionTruncationTests`.
    public var revealCut: CGFloat? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // The whole caption is shown: the card ends where its own bounds do,
        // and everything past that on the page is the stream.
        guard showMoreRange != nil else { return bounds.height }
        return captionEnd
    }

    /// The caption's own bottom in the card's space.
    ///
    /// MEASURED, never read off the label's frame — and that distinction is the
    /// whole of this property.
    ///
    /// A self-sizing cell gets its height from the collection view's
    /// attributes, but its subtree keeps the geometry of whatever pass last ran
    /// over it. Arm a reveal in that window and they disagree in a way that
    /// looks like nothing is wrong: measured on an iPhone SE, `bounds` was a
    /// correct 343x145 while the card underneath was still 343x88 and the label
    /// inside it 311x30 — for text that measures 86.5. `setNeedsLayout` +
    /// `layoutIfNeeded` did NOT reconcile them.
    ///
    /// The veil built on 46pt instead of 103 cut the page three lines too high,
    /// so the flight carried a greyed slab where the card's own four lines
    /// belonged. So the two inputs here are the ones that are always right:
    /// `bounds`, which comes from the attributes, and the label's own opinion
    /// of its text. `ceil` for the reason `preferredLayoutAttributesFitting`
    /// ceils — half a point short is a clipped descender.
    private var captionEnd: CGFloat? {
        let available = bounds.width - Self.captionInset * 2
        guard available > 0 else { return nil }
        let text = captionLabel.sizeThatFits(
            CGSize(width: available, height: .greatestFiniteMagnitude)
        )
        return Self.captionTopInset + ceil(text.height)
    }

    /// The preview's rect in this cell's own space, or nil for a text-only row
    /// (which has no media to fly). A hero source reads this to decide whether
    /// a row can host a flight at all.
    public var mediaHeroRect: CGRect? {
        guard !mediaView.isHidden else { return nil }
        layoutIfNeeded()
        return mediaView.frame
    }

    /// The image the preview is currently showing — the exact pixels the
    /// viewer is looking at, so a flight starts from them rather than from a
    /// cache lookup that could miss.
    public var renderedCover: UIImage? { mediaView.image }

    /// The preview box — a row's media is one part of its card, so this is the
    /// part visibility is measured against. Falls back to the whole cell only
    /// for a text row, which has no video to measure anyway.
    public var videoMediaRect: CGRect { mediaHeroRect ?? bounds }

    // MARK: - Autoplay surface

    /// The surface an autoplaying row renders into, built on first use so a
    /// timeline of stills never allocates a player layer it will not use.
    ///
    /// Placed INSIDE the preview box, unlike the tile's, which fills the whole
    /// cell. That is the row's shape talking: the media is one part of a card,
    /// so the video has to be clipped to the part — and putting it in the box
    /// also means it inherits the box's rounding and, for free, the alpha that
    /// `setHeroMediaConcealed` applies while a twin is in the air. A sibling
    /// surface would have needed concealing separately, and would have been
    /// the thing left visible over a flight.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "row"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        mediaView.addSubview(view)
        view.pin(to: mediaView)
        sendVideoSurfaceBelowBadge(view)
        loadedVideoRenderView = view
        return view
    }

    public private(set) var loadedVideoRenderView: VideoRenderView?

    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.isHidden = false
        mediaView.addSubview(view)
        view.pin(to: mediaView)
        sendVideoSurfaceBelowBadge(view)
        loadedVideoRenderView = view
    }

    /// Keeps the ▶ glyph over the video, the way the tile keeps its furniture
    /// over a playing brick: the badge is what tells a video row apart, and it
    /// should read the same whether the preview is a still or moving.
    ///
    /// Separate from the `pin` above, and it has to be — `pin(to:)` begins with
    /// `addSubview`, which moves the view to the FRONT. Ordering the surface
    /// before pinning it is therefore silently undone, which is exactly what
    /// happened: the first playing row rendered correctly with its badge gone.
    private func sendVideoSurfaceBelowBadge(_ view: VideoRenderView) {
        mediaView.insertSubview(view, belowSubview: playBadge)
    }

    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    /// Reveals the surface once a player has been attached. The cover stays
    /// underneath as the poster, so the first frame replaces it rather than
    /// flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(mediaView.image)
        view.revealOnFirstFrame()
    }

    /// Back to a still row. Faded rather than switched off, so a sweep that
    /// stops several rows at once does not snap their covers back in one frame.
    public func endVideoPreview() {
        loadedVideoRenderView?.hideCrossFading()
    }

    /// Puts a cover on immediately, without waiting for the async load already
    /// in flight — the same race the tile closes, for the same reason: the
    /// autoplay gate must not pass on a cover the row is not actually showing.
    public func applyCover(_ image: UIImage) {
        guard mediaView.image == nil else { return }
        mediaView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load, so the autoplay gate is
    /// re-run for a row that arrived faceless.
    public var onCoverLoaded: (() -> Void)?

    /// Called when the collection view recycles this row, so the coordinator
    /// takes its player back before the cell is bound to another post.
    public var onReuse: (() -> Void)?

    /// Decides whether the caption OVERFLOWS, at the width the layout is
    /// actually going to give this row.
    ///
    /// It cannot be decided in `configure`: a self-sizing cell is configured
    /// before it is sized, so the width there is whatever the recycled cell
    /// happened to be carrying, and a caption measured against the wrong width
    /// answers the wrong question — three lines at one width is five at
    /// another. The attributes are authoritative, which is the same reason
    /// `CaptionBubbleCell` measures here rather than there.
    ///
    /// The measurement is the honest one: how tall the caption WANTS to be
    /// against how tall the cap allows. Asking `UILabel` whether it truncated
    /// would be reading a result of the layout pass that is being computed.
    override public func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetWidth = layoutAttributes.frame.width
        guard targetWidth > 0 else {
            return super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        if abs(bounds.width - targetWidth) > 0.5 {
            bounds.size.width = targetWidth
        }
        composeCaption(atWidth: targetWidth)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let fitted = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // Ceil, not round: half a point short of the caption is a clipped
        // descender on the last line.
        layoutAttributes.frame.size.height = ceil(fitted.height)
        return layoutAttributes
    }

    /// The ellipsis and the affordance, written INTO the caption so they sit at
    /// the end of the truncated text rather than under it.
    ///
    /// A label cannot do this for itself: `.byTruncatingTail` puts its ellipsis
    /// at the very end of the last line and leaves nowhere to put anything
    /// after it. So the text is shortened here, by hand, to the longest
    /// word-boundary prefix that still leaves room for "… Show more" on the
    /// last line — which is what makes the affordance read as part of the
    /// sentence it interrupts.
    private func composeCaption(atWidth width: CGFloat) {
        let font = captionLabel.font ?? .preferredFont(forTextStyle: .body)
        let available = width - Self.captionInset * 2
        guard !isCaptionExpanded, !fullCaption.isEmpty, available > 0 else {
            showMoreRange = nil
            captionLabel.attributedText = Self.plain(fullCaption, font: font)
            return
        }
        // Measured in LINES, from the font's own metrics — never a hardcoded
        // height, or a Dynamic Type step silently changes which captions are
        // considered long.
        let whole = Self.plain(fullCaption, font: font)
        guard Self.lineCount(whole, width: available) > Self.captionLineLimit else {
            showMoreRange = nil
            captionLabel.attributedText = whole
            return
        }
        let composed = Self.truncated(
            fullCaption, font: font, width: available, capLines: Self.captionLineLimit
        )
        captionLabel.attributedText = composed.text
        showMoreRange = composed.showMore
    }

    private static let showMoreTitle = "Show more"
    private static let ellipsis = "\u{2026} "

    private static func plain(_ text: String, font: UIFont?) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ])
    }

    /// How many lines `text` occupies at `width`, counted as LINE FRAGMENTS.
    ///
    /// Not `height / font.lineHeight`, which is what this did first and is
    /// wrong in a way that hides: `boundingRect` returns the laid-out height
    /// including leading, which for four lines of body text measured 88pt
    /// against a 20.5pt line height — 4.29, not 4. Rounding rescues small
    /// counts and drifts into over-reporting as they grow, so the error only
    /// appears at large Dynamic Type sizes or long captions.
    private static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        guard text.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var effective = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            count += 1
            index = NSMaxRange(effective)
        }
        return count
    }

    /// The longest word-boundary prefix of `text` whose last line still has
    /// room for "… Show more" AFTER it, plus the range that affordance
    /// occupies.
    ///
    /// Two steps, because the property wanted is not monotone and a single
    /// search cannot find it:
    ///
    /// 1. binary search for the longest prefix that fills at most `capLines` on
    ///    its own — this part IS monotone;
    /// 2. walk back a word at a time until the affordance fits on the same line
    ///    the prefix ends on.
    ///
    /// Searching in one step on "does the composition fit in `capLines`"
    /// instead — which is what this did first — maximises the wrong thing: a
    /// prefix filling three lines with the affordance wrapped alone onto a
    /// fourth satisfies it perfectly, and puts the affordance back on its own
    /// line, which is exactly what it exists to avoid. Caught by a test that
    /// counted the prefix's lines rather than the composition's.
    ///
    /// Word boundaries rather than characters: a caption cut mid-word reads as
    /// a rendering fault rather than as an interruption, and there are far
    /// fewer of them to search.
    private static func truncated(
        _ text: String, font: UIFont, width: CGFloat, capLines: Int
    ) -> (text: NSAttributedString, showMore: NSRange) {
        let ns = text as NSString
        var boundaries: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            boundaries.append(range.location + range.length)
        }
        if boundaries.isEmpty { boundaries = [ns.length] }

        func prefix(upTo end: Int) -> String {
            ns.substring(to: min(end, ns.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func compose(_ prefix: String) -> NSAttributedString {
            let composed = NSMutableAttributedString(
                attributedString: plain(prefix + ellipsis, font: font)
            )
            composed.append(NSAttributedString(string: showMoreTitle, attributes: [
                .font: font,
                .foregroundColor: UIColor.tintColor
            ]))
            return composed
        }

        // 1. The longest prefix that fills at most `capLines` by itself.
        var low = 0
        var high = boundaries.count - 1
        var fullest = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = plain(prefix(upTo: boundaries[mid]), font: font)
            if lineCount(candidate, width: width) <= capLines {
                fullest = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // 2. Back off until the affordance shares the prefix's last line.
        var index = fullest
        while index >= 0 {
            let body = prefix(upTo: boundaries[index])
            let composed = compose(body)
            let bodyLines = lineCount(plain(body, font: font), width: width)
            let composedLines = lineCount(composed, width: width)
            if composedLines == bodyLines, composedLines <= capLines {
                return (composed, showMoreRange(in: composed))
            }
            index -= 1
        }
        // Nothing fits beside it — a first word wider than the row. Show the
        // affordance alone rather than nothing at all.
        let composed = compose(prefix(upTo: boundaries[0]))
        return (composed, showMoreRange(in: composed))
    }

    private static func showMoreRange(in composed: NSAttributedString) -> NSRange {
        NSRange(
            location: composed.length - (showMoreTitle as NSString).length,
            length: (showMoreTitle as NSString).length
        )
    }

    /// Brings in the closing metric line, which the page never had, instead of
    /// letting it appear in a single frame.
    ///
    /// It runs at the LANDING — once the page is gone and the card is alone —
    /// and not during the flight, because the page is veiled over exactly that
    /// band: anything faded underneath an opaque cover arrives at full opacity
    /// anyway.
    ///
    /// ## Why the caption is NOT faded with it
    ///
    /// The card and the page differ on one more thing: the tail of the last
    /// line, where the affordance displaced the words the page still shows —
    /// "…a migration that… Show more" against "…a migration that had been".
    /// Cross-fading that was tried twice, once by dissolving the whole page
    /// against the card and once by dissolving this label against a copy of
    /// the page's version. Both showed the same artifact, because it is not a
    /// property of the mechanism: blending two DIFFERENT runs of text draws
    /// both of them, and the result reads as "that.had beenmore" rather than
    /// as a substitution.
    ///
    /// A fade only works against nothing, which is why the metric line takes
    /// one and the caption does not. Removing that last pop needs the two
    /// sides to stop differing — either the page truncating its own line four
    /// for the flight, or the veil hiding it so the card's can arrive into
    /// empty space — and both are structural rather than a fade.
    public func fadeInRevealedFurniture(duration: TimeInterval = 0.22) {
        // ONLY when the caption was truncated, and the symmetry with
        // `revealCut` is the reason. A truncated card's metric line arrives
        // into a band the page was filling with words, so it has to be brought
        // in rather than switched on. A whole caption's does not: the page
        // carries the same metric line at the same offset, unveiled, for the
        // entire flight — fading it in here would blink something that was
        // already on screen.
        guard showMoreRange != nil else { return }
        metaRow.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.metaRow.alpha = 1
        }
    }

    #if DEBUG
    /// Presses "Show more". Returns false when there was nothing to reveal,
    /// which is the answer a harness must not mistake for success.
    ///
    /// The simulator injects no touches, so this is the only way this control
    /// is reachable in an automated run.
    ///
    @discardableResult
    public func debugTapShowMore() -> Bool {
        guard showMoreRange != nil else { return false }
        revealTapped()
        return true
    }
    #endif

    /// Hides ONLY the preview while its twin is in the air.
    ///
    /// A row is a card of which the media is one part, and the flight carries
    /// that part (`mediaHeroRect`) — so that part is exactly what must
    /// disappear. Hiding the whole cell instead, which is what a tile needs,
    /// took the caption, the author line and the metrics with it: they were
    /// missing for the length of the flight and snapped back at its last
    /// frame, because nothing in the air was standing in for them.
    ///
    /// The invariant, in one line: CONCEAL EXACTLY WHAT THE FLIGHT
    /// REPRODUCES. A tile is its media, so the tile hides whole; a row is not,
    /// so it does not. A text row never flies at all — it pushes natively.
    ///
    /// Alpha, not `isHidden`, and that is load-bearing: `mediaHeroRect`
    /// reports nil for a hidden preview, so hiding it would make the row
    /// unable to answer where its own media is — which is the rect the
    /// DISMISSAL flies home to.
    public func setHeroMediaConcealed(_ concealed: Bool) {
        mediaView.alpha = concealed ? 0 : 1
        playBadge.alpha = concealed ? 0 : 1
    }


    /// The card's own rounding and fill, so a flight impersonating this row
    /// is its twin rather than an approximation of it. Restating either as a
    /// literal in the flight card is how the two drift.
    public static let cardCornerRadius: CGFloat = 18
    public static let cardFillColor: UIColor = .secondarySystemBackground
    /// The caption's type and inset, for the same reason.
    public static let captionInset: CGFloat = 16
    public static let captionTopInset: CGFloat = 16
    /// The closing metric line's placement, shared with the flight card that
    /// stands in for a text row.
    public static let metaBottomInset: CGFloat = 14
    public static let metaSpacing: CGFloat = 14
    /// How many lines of caption a card previews before it offers the rest.
    ///
    /// A card is a PREVIEW and the post is where the text is read, so the cap
    /// is set where a long caption still reads as a paragraph rather than as a
    /// wall — four lines. Only the card truncates: `PostCaptionRowView`, which
    /// wears the same face on the post's own page, deliberately does not.
    public static let captionLineLimit = 4
    /// The gap between the caption and whatever follows it — the metric line,
    /// the media preview, or the reveal affordance.
    public static let captionFollowGap: CGFloat = 12

    /// Fired when the viewer asks for the rest of a truncated caption. The HOST
    /// owns the answer, not this cell: a cell is recycled and the expansion has
    /// to survive that, so the set of expanded posts lives in
    /// `CaptionExpansion` and comes back through `configure`.
    public var onRevealFullCaption: (() -> Void)?

    private let card = UIView()
    private let captionLabel = UILabel()
    private var isCaptionExpanded = false
    /// The caption as the post carries it. The label shows a SHORTENED version
    /// while truncated, so the label's own text is not a copy of this and
    /// cannot be used in its place.
    private var fullCaption = ""
    /// The closing metric line, held so a landing can bring it in gently —
    /// see `fadeInRevealedFurniture`.
    private var metaRow: UIStackView!
    /// Where "Show more" sits inside the label's current attributed text, or
    /// nil when the caption fits and there is no affordance at all.
    ///
    /// It is the tap target: a range, not a view, because the affordance is a
    /// run of glyphs inside the caption's own layout now — see
    /// `captionTapped`.
    private var showMoreRange: NSRange?
    private let mediaView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    private let reactions = PostMetricLabel(symbol: "heart", font: metaFont, color: .secondaryLabel)
    private let comments = PostMetricLabel(symbol: "bubble.right", font: metaFont, color: .secondaryLabel)
    private let views = PostMetricLabel(symbol: "eye", font: metaFont, color: .secondaryLabel)
    private let ageLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    /// Swapped per configure: the metadata line hangs off the caption for
    /// text-only rows; media rows interpose the preview.
    private var metaFollowsCaption: NSLayoutConstraint!
    private var mediaConstraints: [NSLayoutConstraint] = []

    override public init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Self.cardFillColor
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.pin(to: contentView)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = Self.captionLineLimit
        // WORD WRAPPING, not tail truncation, and that is not a detail: the
        // ellipsis is written into the text here rather than drawn by the
        // label, because it has to be followed by "Show more" ON THE SAME
        // LINE. A label that truncates for itself puts the ellipsis at the
        // very end of the last line and leaves nowhere to put anything after
        // it.
        captionLabel.lineBreakMode = .byWordWrapping
        // TOP-ANCHORED DRAWING, and this is what makes the expansion read as a
        // reveal rather than as a jump.
        //
        // A label centres its text block inside its own bounds. Expanding sets
        // the whole caption on a label whose frame is still four lines tall and
        // then animates that frame open — so for the length of the animation
        // the text is taller than the box holding it, and centred means the
        // lines already on screen slide UP and out before drifting back down.
        // Anchored to the top they simply stay where they are while the rest
        // arrives underneath.
        captionLabel.contentMode = .top
        // The affordance is a run of glyphs inside this label, so the label is
        // what receives its tap.
        captionLabel.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(captionTapped))
        tap.delegate = self
        captionLabel.addGestureRecognizer(tap)
        captionLabel.constrain(in: card) { parent in
            captionLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: Self.captionTopInset)
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
        }

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.layer.cornerCurve = .continuous
        card.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: mediaView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10)
        }

        ageLabel.font = Self.metaFont
        ageLabel.textColor = .secondaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        // Views lead, reactions and comments follow — the same reach-first
        // order as the media tiles' counter pair.
        let metaRow = UIStackView(arrangedSubviews: [views, reactions, comments, spacer, ageLabel])
        self.metaRow = metaRow
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = Self.metaSpacing
        metaRow.constrain(in: card) { parent in
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
            metaRow.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Self.metaBottomInset)
        }
        metaFollowsCaption = metaRow.topAnchor.constraint(
            equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
        )
        metaFollowsCaption.isActive = true
        mediaConstraints = [
            mediaView.topAnchor.constraint(
                equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
            ),
            mediaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            mediaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            mediaView.heightAnchor.constraint(equalToConstant: 180),
            metaRow.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: 12)
        ]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // Hand the player back BEFORE anything else: a recycled row that kept
        // its loan would show the previous post's video under the new post's
        // cover. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        // Concealment is per-flight state and must not ride a recycled cell to
        // whatever post it is bound to next — the row equivalent of the tile's
        // `isHidden` reset.
        setHeroMediaConcealed(false)
        loadTask?.cancel()
        loadTask = nil
        mediaView.image = nil
        onRevealFullCaption = nil
        // Back to truncated. A recycled row must not inherit the previous
        // post's expansion — `configure` re-applies the host's answer for the
        // post it is actually bound to.
        isCaptionExpanded = false
        captionLabel.numberOfLines = Self.captionLineLimit
        showMoreRange = nil
        // A landing's fade is per-flight state and must not ride a recycled
        // cell to whatever post it is bound to next.
        metaRow.alpha = 1
    }

    private func revealTapped() {
        guard !isCaptionExpanded else { return }
        isCaptionExpanded = true
        captionLabel.numberOfLines = 0
        showMoreRange = nil
        captionLabel.attributedText = Self.plain(fullCaption, font: captionLabel.font)
        onRevealFullCaption?()
    }

    @objc private func captionTapped() {
        revealTapped()
    }

    /// ⚠️ The recognizer must REFUSE every touch that is not on the affordance,
    /// not merely ignore it.
    ///
    /// A gesture recognizer on the label consumes taps on the label whether or
    /// not its action does anything, so a recognizer that simply returned early
    /// for a miss would make the caption — the largest thing on the card —
    /// stop opening the post. Refusing at `shouldBegin` leaves the touch to the
    /// collection view's own selection.
    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let range = showMoreRange, !isCaptionExpanded else { return false }
        return Self.characterIndex(
            at: gesture.location(in: captionLabel), in: captionLabel
        ).map { NSLocationInRange($0, range) } ?? false
    }

    /// Which character of the label's text is under `point`, laid out exactly
    /// as the label lays it out.
    ///
    /// TextKit rather than arithmetic on line heights: the affordance is the
    /// tail of a wrapped line, so its position depends on where the line broke,
    /// which only a real layout knows. The container is configured to match the
    /// label — zero padding, the label's line-break mode and line cap — because
    /// a container that differs in any of those breaks the text somewhere else
    /// and hit-tests a different string.
    ///
    /// Returns nil when the point is outside the laid-out glyphs, so a tap in
    /// the empty tail of the last line is a miss rather than the nearest
    /// character.
    private static func characterIndex(at point: CGPoint, in label: UILabel) -> Int? {
        guard let attributed = label.attributedText, attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = label.lineBreakMode
        container.maximumNumberOfLines = label.numberOfLines
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let index = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        // `glyphIndex(for:)` clamps to the nearest glyph, so a point past the
        // end of a line answers with that line's last character. Rejecting a
        // point outside the glyph's own rect is what turns that clamp back into
        // a miss.
        let glyphRect = manager.boundingRect(
            forGlyphRange: NSRange(location: index, length: 1), in: container
        )
        guard glyphRect.contains(point) else { return nil }
        return manager.characterIndexForGlyph(at: index)
    }

    public func configure(
        with post: GalleryPost, imagePipeline: ImagePipeline, captionExpanded: Bool = false
    ) {
        isCaptionExpanded = captionExpanded
        captionLabel.numberOfLines = captionExpanded ? 0 : Self.captionLineLimit
        fullCaption = post.caption
        showMoreRange = nil
        // Provisional: the real composition needs the row's final width, which
        // only `preferredLayoutAttributesFitting` knows. Set here so a cell
        // that is never sized (a measuring instance) still reads correctly.
        captionLabel.attributedText = Self.plain(post.caption, font: captionLabel.font)
        let hasMedia = post.kind != .text
        mediaView.isHidden = !hasMedia
        playBadge.isHidden = post.kind != .video
        metaFollowsCaption.isActive = !hasMedia
        NSLayoutConstraint.deactivate(hasMedia ? [] : mediaConstraints)
        NSLayoutConstraint.activate(hasMedia ? mediaConstraints : [])

        reactions.set(post.reactionCount)
        comments.set(post.commentCount)
        views.set(post.viewCount)
        ageLabel.text = PostMetadata.compactAge(ofMillis: post.publishedAtMS)

        mediaView.image = nil
        mediaView.backgroundColor = post.kind == .video ? .darkGray : .tertiarySystemFill
        guard hasMedia, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            mediaView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.mediaView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.mediaView.image = image
            }
            // The row now has a face, which is the one thing the autoplay gate
            // was waiting for. Nothing else would ask again while the timeline
            // sits still.
            loadedVideoRenderView?.setPoster(image)
            onCoverLoaded?()
        }
    }
}

extension PostGridListRowCell: GridPlaybackCell {}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the compact counter pair (reactions, views) resting bottom-leading —
/// caption2 over a soft shadow, no scrim, so the preview stays the star.
public final class PostGridTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridTileCell"

    /// The mosaic's rounding, and the default: it is paired with that layout's
    /// 1.5pt hairline gutter, where anything softer would leave visible pinches
    /// where four bricks meet.
    public static let mosaicCornerRadius: CGFloat = 10

    /// The brick's rounding, settable because the two grids that share this
    /// cell space their tiles differently — see
    /// `ChaoticSliceLayout.harmonisedGutter`. Gap and curve are one decision,
    /// so a surface that widens the gap sets this to match.
    public var cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius {
        didSet { contentView.layer.cornerRadius = cornerRadius }
    }

    /// The image the brick is currently showing — see `PostGridListRowCell`'s
    /// note for why a hero reads this rather than the image pipeline.
    public var renderedCover: UIImage? { imageView.image }

    /// A tile IS its media, edge to edge, so the whole cell is the rect
    /// visibility is measured against.
    public var videoMediaRect: CGRect { bounds }

    /// The surface an autoplaying tile renders into, built on first use so a
    /// grid of stills never allocates a player layer it will not use.
    ///
    /// Not a `lazy var`: the coordinator needs to ask whether a cell *could* be
    /// playing (`loadedVideoRenderView`) without the question itself allocating
    /// the layer, which is exactly what touching a lazy var would do.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        if let loadedVideoRenderView { return loadedVideoRenderView }
        let view = VideoRenderView()
        #if DEBUG
        view.debugLabel = "tile"
        #endif
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Above the still, below the badge and counters, so the furniture keeps
        // reading over moving video exactly as it does over a poster.
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
        return view
    }

    /// The video surface if one was ever built, else nil — never allocates.
    public private(set) var loadedVideoRenderView: VideoRenderView?

    /// Installs a flight card's live surface as this tile's own, at landing.
    ///
    /// The view arrives already rendering, so the tile has nothing to wait for
    /// — the alternative is starting a fresh layer that is blank for ~100ms
    /// just as the card is removed, which is the flash at the end of a
    /// dismissal.
    public func adoptVideoRenderView(_ view: VideoRenderView) {
        if let existing = loadedVideoRenderView, existing !== view {
            existing.detachForReplacement()
            existing.removeFromSuperview()
        }
        view.transform = .identity
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = false
        contentView.insertSubview(view, aboveSubview: imageView)
        loadedVideoRenderView = view
    }

    /// Gives up the live surface so a hero flight can fly the *same* layer.
    ///
    /// Mirroring — attaching the player to a second `AVPlayerLayer` — cannot be
    /// seamless, because a freshly attached layer has no decoded frame and
    /// reports `isReadyForDisplay == false` for ~100ms. Measured. Moving the
    /// view that is already rendering has no such window: same layer, same
    /// player, same frame, just a different superview.
    ///
    /// The cell drops its reference; a later play builds a fresh surface.
    public func donateVideoRenderView() -> VideoRenderView? {
        guard let view = loadedVideoRenderView else { return nil }
        loadedVideoRenderView = nil
        view.removeFromSuperview()
        return view
    }

    /// Called when the collection view recycles this cell, so whoever loaned it
    /// a player takes it back. Mirrors `MapAnnotationView.onReuse`: a recycled
    /// cell that kept its player would render another post's video.
    public var onReuse: (() -> Void)?

    private let imageView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.postGridSystemFont(
        matching: .preferredFont(forTextStyle: .caption2), weight: .semibold
    )
    private let reactions = PostMetricLabel(
        symbol: "heart.fill", font: metaFont, color: .white, shadowed: true
    )
    private let views = PostMetricLabel(
        symbol: "eye.fill", font: metaFont, color: .white, shadowed: true
    )
    private var loadTask: Task<Void, Never>?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        // Soft bricks, not hard edges. `cornerRadius` re-applies this whenever
        // a host wants the softer pairing; the curve stays continuous either
        // way, which is what keeps a widened radius from reading as a stadium.
        contentView.layer.cornerRadius = cornerRadius
        contentView.layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.pin(to: contentView)

        // The badge sits over media of any brightness: a soft shadow instead
        // of a scrim keeps the thumbnail unobstructed.
        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: contentView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8)
        }

        // Views lead, reactions follow — reach first, then resonance.
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: contentView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // A recycled cell must come back VISIBLE. A hero flight hides the tile
        // it is flying from, and that hide lives on the cell — so a cell
        // recycled while hidden carries the invisibility to whatever post it is
        // next bound to, and nothing on the reuse path would ever put it back.
        // One tile lost per flight whose cell got recycled before its unhide,
        // which is what made the gallery thin out over repeated round trips.
        isHidden = false
        alpha = 1
        // Hand the player back BEFORE anything else: a recycled cell that kept
        // its loan would show the previous post's video under the new post's
        // still. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    /// Puts a cover on the tile immediately, without waiting for the async load
    /// that is already in flight to come back.
    ///
    /// Closes a race the autoplay gate would otherwise lose: `configure` asks
    /// the cache once, and if the image lands *after* that (from the prefetch)
    /// the cache has it while this cell is still showing nothing. A gate that
    /// consulted the cache would pass, and the tile would start playing with a
    /// blank face anyway — which is the exact failure the gate exists to
    /// prevent.
    public func applyCover(_ image: UIImage) {
        guard imageView.image == nil else { return }
        imageView.image = image
        loadedVideoRenderView?.setPoster(image)
    }

    /// Fired when the cover lands from an async load.
    ///
    /// Autoplay is gated on the cover being present, and the gate is evaluated
    /// by a reconcile that normally only runs on scroll. Without this, a tile
    /// whose cover arrives while the grid is sitting still would fail the gate
    /// once and never be asked again — it would simply never play.
    public var onCoverLoaded: (() -> Void)?

    /// Reveals the video surface once a player has been attached. The still
    /// stays underneath as the poster, so the first frame replaces it rather
    /// than flashing black.
    public func beginVideoPreview() {
        let view = makeVideoRenderViewIfNeeded()
        view.setPoster(imageView.image)
        // The cover keeps the tile until there is video to replace it with.
        // Unhiding here put an empty surface over the cover for the whole
        // decode start-up — measured at ~1.2s on a cold tile — which is a tile
        // going dark at rest, before any transition is involved.
        view.revealOnFirstFrame()
        #if DEBUG
        // Whether the tile had a cover AT THE MOMENT playback started. Holding
        // the surface back is only worth anything if there is something behind
        // it; a nil here means the tile is black no matter what the renderer
        // does, and the fix belongs in the cover pipeline rather than here.
        if ProcessInfo.processInfo.arguments.contains("-avsbdl-log") {
            print(String(format: "[avsbdl] %.3f tile beginVideoPreview cover=%@",
                         CACurrentMediaTime(), imageView.image == nil ? "NIL" : "present"))
        }
        #endif
    }

    /// Back to a still tile.
    public func endVideoPreview() {
        // Faded, not switched off. This runs for every tile `beginHandoff`
        // stops as a flight leaves, and a binary hide snaps each of their
        // covers back in a single frame — several thumbnails popping at once,
        // on the grid, at exactly the moment the viewer is watching the flight.
        loadedVideoRenderView?.hideCrossFading()
    }

    public func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        playBadge.isHidden = post.kind != .video
        // Video tiles keep a dark floor: their poster may be unrenderable
        // (or plain black in the simulator), and the glyph needs a stage.
        contentView.backgroundColor = post.kind == .video ? .darkGray : .secondarySystemBackground

        reactions.set(post.reactionCount)
        views.set(post.viewCount)

        imageView.image = nil
        guard let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            guard let self else { return }
            UIView.transition(
                with: self.imageView, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.imageView.image = image
            }
            // A tile can start playing before its cover arrives, and
            // `beginVideoPreview` reads the cover exactly once — so a cover
            // that lands afterwards never reached the surface, leaving it with
            // no poster to fall back on for the rest of its life. That is the
            // difference between a cold flight showing the thumbnail and
            // showing nothing.
            self.loadedVideoRenderView?.setPoster(image)
            self.onCoverLoaded?()
        }
    }
}

extension PostGridTileCell: GridPlaybackCell {}
