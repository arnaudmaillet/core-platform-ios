import CoreModels
import DesignSystem
import PostGrid
import UIKit

/// `-map-text-bubble` (the owner, 2026-11-09): the text marker nearest the
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

        /// The bubble's words for `post`, its age read against `now`.
        static func of(_ post: GalleryPost, now: Date = Date()) -> Content {
            let name = post.authorName ?? post.authorHandle.map { "@\($0)" } ?? ""
            let published = Date(timeIntervalSince1970: TimeInterval(post.publishedAtMS) / 1000)
            return Content(
                postID: post.id,
                authorName: name,
                age: post.publishedAtMS > 0 ? RelativeAgeFormatter.short(from: published, to: now) : "",
                caption: post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    /// The author's line and the words, laid out as one column.
    private let column = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
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
        column.addSubview(label)
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
        let words = label.sizeThatFits(room)
        return CGSize(
            width: ceil(min(Self.textWidth, max(author.width, words.width))),
            height: ceil(author.height) + Self.lineGap + ceil(words.height)
        )
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
        label.frame = CGRect(x: 0, y: author + Self.lineGap, width: text.width, height: text.height - author - Self.lineGap)
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
    #endif
}
