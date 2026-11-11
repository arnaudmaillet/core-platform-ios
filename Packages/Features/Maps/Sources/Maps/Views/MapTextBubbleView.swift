import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit
import VoiceKitUI

/// The text bubble (#2203, the owner, 2026-11-09): the text marker nearest the
/// map's centre opens a bubble round it — display first, the words where the
/// post is. It unfolds out of the marker, both ways, the marker sliding to
/// its LEFT end and the words appearing on its right (`MapFeaturedHalo`); it
/// moves with the map, as the marker does, and the whole of it opens the
/// post.
///
/// ```
///   ╭──────────────────────────────────────╮
///   │ (◉)  Ava Moreau · 2h                 │
///   │      Golden hour at the pier, the    │
///   │      light hit the water and eve…    │
///   ╰──────────────────────────────────────╯
/// ```
///
/// - **Its author over its words** (the owner, 2026-11-09): the name, then
///   the post's age; the words on two lines at most, cut at the second's
///   end, the post's blank lines folded.
/// - **A voice post (#2208, behind `-voice-posts`)** keeps the bubble: the
///   shared voice component's compact panel (#2241) across the column, in
///   the words' place under the author — play / pause, the waveform, the
///   timer — its words under it.
///   The voice's taps are its own; the rest of the bubble opens the post. It
///   stops when the bubble folds (the voice leaves the window).
/// - **A channel's showcase (#2216, behind `-channels`)** keeps the bubble
///   too: the shared embed card, full size, under the author's words —
///   Join, Request to Join, Open from the map. Only its action button takes
///   a touch; the rest of the bubble still opens the post.
/// - **Liquid Glass**, the system's own, its round end concentric with the
///   round marker. No shadow: a shadow renders a glass or a blur offscreen,
///   cut off from the map it samples (a blur came out flat).
final class MapTextBubbleView: UIView {
    /// What the bubble says.
    struct Content: Equatable {
        let postID: PostID
        let authorName: String
        let age: String
        let caption: String
        /// The caption's voice (#2208), with `-voice-posts` on.
        var voice: PostVoice? = nil
        /// A showcase's card (#2216), with `-channels` on. It outranks a
        /// voice, as on every surface.
        var embed: PostEmbed? = nil

        /// The bubble's words for `post`, its age read against `now`.
        /// `pinEmbed` is the marker's own read of the card, for a post read
        /// without one (#2216).
        static func of(
            _ post: GalleryPost, now: Date = Date(), showsVoice: Bool = VoicePostDisplay.areDrawn,
            pinEmbed: PostEmbed? = nil, showsEmbed: Bool = PostEmbeds.areDrawn
        ) -> Content {
            let name = post.authorName ?? post.authorHandle.map { "@\($0)" } ?? ""
            let published = Date(timeIntervalSince1970: TimeInterval(post.publishedAtMS) / 1000)
            let isText = post.kind == .text
            let embed: PostEmbed? = isText ? PostEmbeds.shown(post.embed ?? pinEmbed, drawn: showsEmbed) : nil
            return Content(
                postID: post.id,
                authorName: name,
                age: post.publishedAtMS > 0 ? RelativeAgeFormatter.short(from: published, to: now) : "",
                caption: post.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                voice: showsVoice && isText && embed == nil ? post.voice : nil,
                embed: embed
            )
        }
    }

    /// The words' widest, beside the marker.
    static let textWidth: CGFloat = 200
    static let maxLines = 2
    /// Round the words: the glass's margins on their right, top and bottom.
    static let insets = UIEdgeInsets(top: 8, left: 11, bottom: 8, right: 12)
    /// The glass's margin round the marker, and the gap to the words.
    static let markerPadding: CGFloat = 5
    static let markerGap: CGFloat = 8
    /// Between the author's line and the words.
    static let lineGap: CGFloat = 1

    /// The grown marker's diameter, set by the halo.
    var markerSide: CGFloat = 44 {
        didSet { if markerSide != oldValue { setNeedsLayout() } }
    }

    let authorLabel = UILabel()
    let label = UILabel()
    /// A voice post's voice, between the author and the words: the compact
    /// panel (#2241, the issue's table) across the column — its drags are
    /// its own (#2275): a sideways drag on it scrubs, and the map's pan
    /// waits for it.
    let voiceCaption = VoicePostCaptionView()
    /// A showcase's card, full size, under the words (#2216).
    let embedCard = PostEmbedView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    /// The author's line and the words, laid out as one column.
    private let column = UIView()

    /// The glass's vibrancy, for the voice: the label's ink, the bars'
    /// unplayed share of it, the timer's secondary grey — and the panel's
    /// ground, derived from the label's ink (`Inks.panel`, #2241), the glass
    /// showing through it.
    static let voiceInks = VoiceView.Inks(
        played: UIColor.label.withAlphaComponent(0.8), unplayed: UIColor.label.withAlphaComponent(0.28),
        timer: .secondaryLabel
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Only the voice takes a touch (`hitTest`): the rest of the bubble is
        // its marker's, which opens the post.
        isUserInteractionEnabled = true
        backgroundColor = .clear
        // The words outside a bubble still unfolding stay hidden.
        glass.clipsToBounds = true
        addSubview(glass)
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        label.font = .appFont(forTextStyle: .subheadline)
        label.textColor = .label
        label.numberOfLines = Self.maxLines
        label.lineBreakMode = .byTruncatingTail
        column.addSubview(authorLabel)
        column.addSubview(voiceCaption)
        voiceCaption.inks = Self.voiceInks
        column.addSubview(label)
        column.addSubview(embedCard)
        glass.contentView.addSubview(column)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The bubble's words: the author's name and the post's age over its
    /// start, its blank lines folded.
    func setContent(_ content: Content) {
        let name = NSMutableAttributedString(string: content.authorName, attributes: [
            .font: UIFont.scaledFont(forTextStyle: .footnote, weight: .semibold), .foregroundColor: UIColor.label,
        ])
        if !content.age.isEmpty {
            name.append(NSAttributedString(string: " · \(content.age)", attributes: [
                .font: UIFont.appFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        authorLabel.attributedText = name
        label.text = Self.shownText(of: content.caption)
        if let voice = content.voice {
            voiceCaption.show(
                postID: content.postID.rawValue, url: voice.url, duration: voice.duration, levels: voice.waveform,
                author: content.authorName.isEmpty ? nil : content.authorName, size: Self.voiceDisplaySize,
                dragsAreOwn: Self.voiceDragsAreOwn
            )
        } else {
            voiceCaption.clear()
        }
        if let embed = content.embed {
            embedCard.show(embed, size: .full, pipeline: imagePipeline)
        } else {
            embedCard.clear()
        }
        sizeToFit()
        setNeedsLayout()
    }

    /// A post's words as the bubble shows them: trimmed, its runs of line
    /// breaks folded into one, so a blank line never spends one of the two.
    /// Pure.
    static func shownText(of text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The column's size: the author's line over the words, as wide as the
    /// wider of the two, `textWidth` at most.
    private var columnSize: CGSize {
        let room = CGSize(width: Self.textWidth, height: .greatestFiniteMagnitude)
        let author = authorLabel.sizeThatFits(room)
        let words = hasWords ? label.sizeThatFits(room) : .zero
        let voice = voiceSize
        let voiceBlock = voice.height > 0 ? Self.voiceGap + voice.height : 0
        let wordsBlock = hasWords ? Self.lineGap + ceil(words.height) : 0
        let card = embedHeight
        // A card takes the column's whole width: its button runs edge to edge.
        let cardBlock = card > 0 ? Self.embedGap + card : 0
        let widest = card > 0 ? Self.textWidth : max(author.width, words.width, voice.width)
        let height: CGFloat = ceil(author.height) + voiceBlock + wordsBlock + cardBlock
        return CGSize(width: ceil(min(Self.textWidth, widest)), height: height)
    }

    /// Between the words and a showcase's card.
    static let embedGap: CGFloat = 6

    /// What a showcase card's photo loads through: its marker's pipeline,
    /// handed over by the halo; nil draws the channel's initials.
    var imagePipeline: ImagePipeline?

    /// The card's height at the column's width, zero without one.
    private var embedHeight: CGFloat {
        guard !embedCard.isHidden else { return 0 }
        return ceil(embedCard.systemLayoutSizeFitting(
            CGSize(width: Self.textWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    /// Between the author's line and the voice, and the voice and the words.
    static let voiceGap: CGFloat = 4

    /// Whether the words show: always with neither a voice nor a card (as
    /// before), only when there are any with one.
    private var hasWords: Bool {
        (voiceCaption.isHidden && embedCard.isHidden) || !(label.text ?? "").isEmpty
    }

    /// The size the bubble gives a voice (#2241's table).
    static let voiceDisplaySize: VoicePostDisplay.Size = .compact
    /// ⚠️ ITS DRAGS ARE ITS OWN, compact as it is (#2275): a sideways drag
    /// on the panel scrubs and the map doesn't pan (`WaveformBars.yields`:
    /// the map's pan waits for the panel's); a vertical one, or one off the
    /// panel, still pans the map.
    static let voiceDragsAreOwn = true

    /// The voice's size, zero without one: the column's whole width — the
    /// panel is one width whatever the length (#2241) — at its panel's
    /// height.
    private var voiceSize: CGSize {
        guard !voiceCaption.isHidden, voiceCaption.voiceView != nil else { return .zero }
        let width = Self.textWidth
        let height = voiceCaption.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        let panel: CGFloat = VoiceView.panelHeight(for: .compact)
        return CGSize(width: width, height: ceil(max(height, panel)))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = columnSize
        let width = Self.markerPadding + markerSide + Self.markerGap + text.width + Self.insets.right
        let height = max(markerSide + 2 * Self.markerPadding, text.height + Self.insets.top + Self.insets.bottom)
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        // Round about the marker: its end concentric with the disc, a circle
        // while the bubble is still folded.
        glass.cornerConfiguration = .corners(radius: .fixed(min(markerSide / 2 + Self.markerPadding, bounds.height / 2)))
        // The column keeps its unfolded size, held to the marker's right: an
        // unfolding bubble shows it, it never reflows it.
        let text = columnSize
        column.frame = CGRect(
            x: Self.markerPadding + markerSide + Self.markerGap, y: (bounds.height - text.height) / 2,
            width: text.width, height: text.height
        )
        let author = ceil(authorLabel.sizeThatFits(CGSize(width: text.width, height: .greatestFiniteMagnitude)).height)
        authorLabel.frame = CGRect(x: 0, y: 0, width: text.width, height: author)
        let voice = voiceSize
        voiceCaption.frame = CGRect(x: 0, y: author + Self.voiceGap, width: voice.width, height: voice.height)
        let wordsTop = voice.height > 0 ? voiceCaption.frame.maxY + Self.lineGap : author + Self.lineGap
        label.isHidden = !hasWords
        let card = embedHeight
        let wordsBottom = text.height - (card > 0 ? Self.embedGap + card : 0)
        label.frame = CGRect(x: 0, y: wordsTop, width: text.width, height: max(0, wordsBottom - wordsTop))
        let cardTop = hasWords ? label.frame.maxY + Self.embedGap : author + Self.embedGap
        embedCard.frame = CGRect(x: 0, y: cardTop, width: text.width, height: card)
    }

    /// Only the voice takes a touch — its play button, its waveform, its
    /// speed chip, and (its drags being its own, #2275) the rest of its
    /// panel, so a sideways drag anywhere on it is the panel's — and only
    /// while the words show; anywhere else the marker under it takes it and
    /// opens the post (#2208). A tap on the panel's ground still opens the
    /// post: the marker's tap leaves only the voice's own presses alone
    /// (`VoicePostCaptionView.keepsTouch`).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard column.alpha > 0.01 else { return nil }
        // A showcase's card: its action button alone (#2216).
        if !embedCard.isHidden {
            let hit = embedCard.hitTest(convert(point, to: embedCard), with: event)
            return PostEmbedView.keepsTouch(on: hit) ? hit : nil
        }
        guard let player = voiceCaption.voiceView, !voiceCaption.isHidden else { return nil }
        let local = convert(point, to: player)
        let onPanel = player.dragsAreOwn && player.keepsDrag(at: local)
        guard player.keepsPress(at: local) || onPanel else { return nil }
        return player.hitTest(local, with: event)
    }

    /// Where the marker's centre stands in the bubble: its left end.
    var markerCentre: CGPoint {
        CGPoint(x: Self.markerPadding + markerSide / 2, y: bounds.midY)
    }

    /// The glass on or off — set inside an animation, the system's own
    /// materialising (the owner, 2026-11-09: the bubble came and went flat).
    func setGlass(_ on: Bool) {
        glass.effect = on ? UIGlassEffect() : nil
    }

    /// The words, the author's line with them, faded in or out.
    func setWordsShown(_ shown: Bool) {
        column.alpha = shown ? 1 : 0
    }

    #if DEBUG
    var debugIsGlass: Bool { glass.effect is UIGlassEffect && layer.shadowOpacity == 0 }
    var debugHasGlass: Bool { glass.effect != nil }
    /// The words' column, in the bubble.
    var debugColumnFrame: CGRect { column.frame }
    /// The voice shown, nil for none (#2208).
    var debugVoice: VoicePostCaptionView? { voiceCaption.isHidden ? nil : voiceCaption }
    /// The showcase's card shown, nil for none (#2216).
    var debugEmbed: PostEmbedView? { embedCard.isHidden ? nil : embedCard }
    #endif
}
