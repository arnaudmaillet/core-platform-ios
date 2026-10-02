import CoreStorage
import DesignSystem
import UIKit

/// Anything that draws a post's like as a STAKE — what `PostCardStaking`
/// binds. The list's card (`PostGridListRowCell`) was the only one; a mosaic
/// tile and For You's compact cards wear `PostStakeChipView` and answer the
/// same five things.
///
/// The view never touches a wallet: it reports amounts (`onStake`, the menu)
/// and renders what the host answers (`setViewerStake` and the three
/// receipts) — the rule every stake control in the app keeps.
@MainActor
public protocol PostCardStakeTarget: UIView {
    /// A tap's stake (`stakeTapAmount`), or a menu pick's amount. Nil leaves
    /// the like a counter.
    var onStake: ((Int) -> Void)? { get set }
    /// The amount a plain tap stakes. Set with `onStake`.
    var stakeTapAmount: Int { get set }
    /// The menu a held like raises (`StakeMenu`), built when raised.
    var stakeMenu: (() -> UIMenu?)? { get set }
    /// What the VIEWER has staked on the post: the heart turns the points'
    /// red once there is any. The count stays the post's.
    func setViewerStake(_ total: Int)
    /// The stake landed: "+N" rising in red, the heart popping.
    func playStakeConfirmation(amount: Int)
    /// An undo: "−N" sinking, in grey.
    func playStakeRefund(amount: Int)
    /// The wallet refused: the like shakes its head.
    func playStakeDenied()
}

extension PostGridListRowCell: PostCardStakeTarget {}

/// The like of a COMPACT card — a mosaic tile, a For You Following card — as
/// a stake: the card's own plain action (`PostCardPillView`, no ground, the
/// press drawing its capsule), holding one heart and the post's count.
///
/// The list's card draws the same control inside its closing line; these
/// cards have no line, so the chip stands alone on the card's corner. It
/// spends through the SAME pieces: `ActionAffordance` (one press, the wash,
/// a hold that freezes the screen and raises `StakeMenu`), `PostCardStaking`
/// (the wallet, the receipts' amounts, the undo window).
///
/// ## Two grounds
///
/// - `.media`: over a picture. White ink under the tile counter's soft shadow
///   and its FILLED heart — exactly the readout a tile has always drawn, so a
///   tile that becomes pressable looks the same at rest.
/// - `.card`: on a card's own fill (a text post). The closing line's outline
///   heart in the line's one ink (`PostCardPillView.ink`).
///
/// Staked, both draw the points' red heart (`PointsSymbol`).
public final class PostStakeChipView: PostCardPillView {
    public enum Ground: Sendable {
        case media
        case card
    }

    /// The air either side of the ink — what a host hangs the chip out by to
    /// put the INK, not the invisible box, where it wants it.
    public static let inkInset: CGFloat = 8
    /// The air above and below the ink. Less than the closing line's 7: a
    /// compact card's corner is small, and the press capsule must stay
    /// inside it.
    static let verticalInset: CGFloat = 5

    public let ground: Ground
    let metric: PostMetricLabel
    private var baseCount: Int64?
    private(set) var viewerStake = 0

    /// Where the "+N" floats are drawn: the card's content view, which the
    /// chip — clipped to its own box — cannot draw outside of. Falls back to
    /// the chip's superview.
    public weak var receiptHost: UIView?

    public var onStake: ((Int) -> Void)? {
        didSet { applyWiring() }
    }

    public var stakeTapAmount = WalletStore.Policy.defaultStakeAmount

    public var stakeMenu: (() -> UIMenu?)? {
        didSet { setMenuProvider(stakeMenu) }
    }

    /// - Parameter font: the count's type — the tile's caption2 on a tile,
    ///   the author line's on a Following card, so the chip reads as part of
    ///   the line it closes.
    public init(ground: Ground, font: UIFont) {
        self.ground = ground
        metric = PostMetricLabel(
            symbol: ground == .media ? PointsSymbol.glyph : PostGridListRowCell.ActionSymbol.like,
            font: font,
            color: ground == .media ? .white : PostCardPillView.ink,
            shadowed: ground == .media
        )
        // A like with no count yet is still a heart to press.
        metric.keepsGlyphWhenEmpty = true
        let inset = Self.inkInset
        super.init(
            contents: [metric], spacing: 0,
            insets: NSDirectionalEdgeInsets(
                top: Self.verticalInset, leading: inset, bottom: Self.verticalInset, trailing: inset
            )
        )
        // Required, so it wins over the declared 999 height every card pill
        // carries (`PostMetaPillView.height`): the line's 32pt does not fit a
        // tile's corner, and the chip is sized by its own type instead.
        heightAnchor.constraint(equalToConstant: Self.height(for: font)).isActive = true
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The chip's height for a count drawn in `font`.
    public static func height(for font: UIFont) -> CGFloat {
        ceil(font.lineHeight) + verticalInset * 2
    }

    /// The chip's size for what it shows now — for a host that lays it out by
    /// frames (`ForYouCardCaptionOverlay`).
    public var fittedSize: CGSize {
        let size = systemLayoutSizeFitting(
            CGSize(width: UIView.layoutFittingCompressedSize.width, height: bounds.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The post's own count. Nil draws the heart alone.
    public func setCount(_ count: Int64?) {
        baseCount = count
        apply()
    }

    public func setViewerStake(_ total: Int) {
        guard total != viewerStake else { return }
        viewerStake = total
        apply()
    }

    /// Back to an unwired, unstaked heart — a recycled card's.
    public func reset() {
        onStake = nil
        stakeMenu = nil
        stakeTapAmount = WalletStore.Policy.defaultStakeAmount
        setViewerStake(0)
    }

    public func playStakeConfirmation(amount: Int) {
        floatReceipt("+\(amount)", color: PointsSymbol.tint, rising: true)
        StakeReceipt.pop(metric.icon)
    }

    public func playStakeRefund(amount: Int) {
        floatReceipt("−\(amount)", color: .secondaryLabel, rising: false)
    }

    public func playStakeDenied() {
        StakeReceipt.shake(self)
    }

    private func floatReceipt(_ text: String, color: UIColor, rising: Bool) {
        guard let host = receiptHost ?? superview, !isHidden, window != nil else { return }
        StakeReceipt.float(text, color: color, rising: rising, from: self, in: host)
    }

    private func applyWiring() {
        let stakes = onStake != nil
        setTapHandler(stakes ? { [weak self] in
            guard let self else { return }
            onStake?(stakeTapAmount)
        } : nil)
        accessibilityLabel = stakes ? "Like, stakes \(StakeMenu.points(stakeTapAmount))" : nil
        apply()
    }

    private func apply() {
        metric.set(baseCount)
        let staked = viewerStake > 0
        metric.setGlyph(
            systemName: staked
                ? PointsSymbol.glyph
                : (ground == .media ? PointsSymbol.glyph : PostGridListRowCell.ActionSymbol.like),
            color: staked ? PointsSymbol.tint : (ground == .media ? .white : PostCardPillView.ink)
        )
        accessibilityValue = baseCount.map(PostMetadata.count)
    }

    #if DEBUG
    /// Whether the heart is the points' red.
    public var debugIsStaked: Bool { viewerStake > 0 }
    /// The count as drawn — nil while there is none.
    public var debugCountText: String? { metric.debugText }
    #endif
}

/// The receipts a stake control plays — one implementation for the list's
/// card (`PostGridListRowCell`) and the compact cards' chip.
@MainActor
enum StakeReceipt {
    /// A number floating off `chip`, then dissolving, drawn in `host` (the
    /// card's content view) because the chip clips to its own box. Pure
    /// theatre over state the wallet already changed.
    static func float(_ text: String, color: UIColor, rising: Bool, from chip: UIView, in host: UIView) {
        let label = UILabel()
        label.text = text
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .heavy)
        label.textColor = color
        label.sizeToFit()
        let frame = chip.convert(chip.bounds, to: host)
        label.center = CGPoint(x: frame.midX, y: rising ? frame.minY - 4 : frame.maxY + 4)
        label.alpha = 0
        label.isUserInteractionEnabled = false
        host.addSubview(label)
        let step: CGFloat = rising ? -1 : 1
        let moves = !UIAccessibility.isReduceMotionEnabled
        UIView.animateKeyframes(withDuration: 0.9, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                label.alpha = 1
                if moves { label.center.y += step * 14 }
            }
            UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.55) {
                if moves { label.center.y += step * 18 }
            }
            UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                label.alpha = 0
            }
        } completion: { _ in
            // UIKit calls an animation's completion on the main thread.
            MainActor.assumeIsolated { label.removeFromSuperview() }
        }
    }

    /// The heart pops: the rail's confirmation, on a card.
    static func pop(_ icon: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        icon.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            icon.transform = .identity
        }
    }

    /// The control shakes its head. Additive, so it composes with the press
    /// still springing back.
    static func shake(_ view: UIView) {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.isAdditive = true
        shake.values = [0, -6, 6, -4, 4, 0]
        shake.duration = 0.35
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer.add(shake, forKey: "stakeDenied")
    }
}
