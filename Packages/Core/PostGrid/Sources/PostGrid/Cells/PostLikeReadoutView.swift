import DesignSystem
import UIKit

/// Anything that draws a post's like with the VIEWER's stake in it — the
/// heart turns the points' red once there is any. What `PostCardStaking`
/// keeps current from the wallet: the list's card, whose like chip stakes
/// (`bind`), and the compact cards, whose heart only reads (`bindReadout`).
@MainActor
public protocol PostCardLikeReadout: UIView {
    /// What the viewer has staked on the post. The count stays the post's.
    func setViewerStake(_ total: Int)
}

extension PostGridListRowCell: PostCardLikeReadout {}

/// The like of a COMPACT card — a For You Following card, a paired card — as
/// a READOUT: one heart and the post's count, red once the viewer has staked.
///
/// ⚠️ DISPLAY ONLY (product call, 3 October 2026). It began as a control
/// (#373: a tap staked, a hold raised `StakeMenu`); the hearts were kept and
/// the stake was taken out of them. It takes no touch at all, so a tap on it
/// is a tap on the card — it opens the post — and a hold is the card's own.
/// Staking stays where it was: the feed's rail, the list's full cards.
///
/// ## Two grounds
///
/// - `.media`: over a picture. White ink under the tile counter's soft shadow
///   and its FILLED heart — the readout a mosaic tile draws in its corner.
/// - `.card`: on a card's own fill (a text post). The closing line's outline
///   heart in the line's one ink (`PostCardPillView.ink`).
///
/// Staked, both draw the points' red heart (`PointsSymbol`).
public final class PostLikeReadoutView: UIView, PostCardLikeReadout {
    public enum Ground: Sendable {
        case media
        case card
    }

    public let ground: Ground
    let metric: PostMetricLabel
    private var count: Int64?
    private(set) var viewerStake = 0

    /// - Parameter font: the count's type — the author line's on a Following
    ///   card, so the heart reads as part of the line it closes.
    public init(ground: Ground, font: UIFont) {
        self.ground = ground
        metric = PostMetricLabel(
            symbol: ground == .media ? PointsSymbol.glyph : PostGridListRowCell.ActionSymbol.like,
            font: font,
            color: ground == .media ? .white : PostCardPillView.ink,
            shadowed: ground == .media
        )
        super.init(frame: .zero)
        // Scenery: the card under it takes the touch, and the card is the one
        // accessibility element.
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        metric.pin(to: self)
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The readout's size for what it shows now — for a host that lays it
    /// out by frames (`ForYouCardCaptionOverlay`). Zero with no count: the
    /// readout is absent, never an asserted zero (`PostMetricLabel`).
    public var fittedSize: CGSize {
        guard count != nil else { return .zero }
        let size = metric.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The post's own count. Nil hides the readout.
    public func setCount(_ count: Int64?) {
        self.count = count
        apply()
    }

    public func setViewerStake(_ total: Int) {
        guard total != viewerStake else { return }
        viewerStake = total
        apply()
    }

    private func apply() {
        metric.set(count)
        isHidden = count == nil
        let staked = viewerStake > 0
        metric.setGlyph(
            systemName: staked
                ? PointsSymbol.glyph
                : (ground == .media ? PointsSymbol.glyph : PostGridListRowCell.ActionSymbol.like),
            color: staked ? PointsSymbol.tint : (ground == .media ? .white : PostCardPillView.ink)
        )
    }

    #if DEBUG
    /// Whether the heart is the points' red.
    public var debugIsStaked: Bool { viewerStake > 0 }
    /// The count as drawn — nil while there is none.
    public var debugCountText: String? { isHidden ? nil : metric.debugText }
    #endif
}
