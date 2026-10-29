import UIKit

/// THE WHEEL FOLDS WITH THE LIKE (#1872, the owner on a device): RECURSIVE.
/// The like is to the wheel's emotes what the anchor is to the column's
/// bubbles — same rules, no glass. Ported from the liquidglass lab's
/// `EmoteRailView` (`collapse`, `reveal`, `follow`):
/// - **collapse**: each visible emote retracts towards the like's centre,
///   to 0.2×, fading and blurring (10 pt × (1 − opacity)), on the measured
///   spring (k 260, ζ 0.75, 0.03 s start) — at the same time as the bubbles;
/// - **reveal**: the resting window's emotes are born in the like's centre
///   at 0.2×, blurred and clear, and go to their places on the same spring;
/// - **follow**: the wheel hangs on the like AS DRAWN
///   (`SnapGlassColumn.presentedFace(of:)`): when the like folds into the
///   sound, the emotes folding into it are carried along; on the reveal, the
///   wheel waits for the like to be born (at the split of the column's
///   capsule) to bring its emotes out of it. The like's opacity is not
///   taken: multiplied by the emotes' own, they would go out twice as fast.
/// During a fold the wheel's mask is off: the emotes reach the like's centre
/// instead of being cut at its edge.
@MainActor
final class SnapWheelFold {
    /// Springs of an emote in a fold: offset from its place, scale, opacity.
    struct Morph {
        var dx = Spring(0), dy = Spring(0), s = Spring(1), a = Spring(1)

        mutating func aim(dx x: CGFloat, dy y: CGFloat, s scale: CGFloat, a alpha: CGFloat) {
            dx.target = x
            dy.target = y
            s.target = scale
            a.target = alpha
        }

        mutating func step(_ h: Double) {
            let k = SnapGlassColumn.springK
            let zeta = SnapGlassColumn.springZeta
            dx.step(h, k: k, zeta: zeta)
            dy.step(h, k: k, zeta: zeta)
            s.step(h, k: k, zeta: zeta)
            a.step(h, k: k, zeta: zeta)
        }

        var settled: Bool { dx.settled && dy.settled && s.settled && a.settled }
    }

    struct Spring {
        var x: CGFloat
        var v: CGFloat = 0
        var target: CGFloat
        init(_ x: CGFloat) {
            self.x = x
            target = x
        }

        mutating func step(_ h: Double, k: Double, zeta: Double) {
            let a = CGFloat(k) * (target - x) - CGFloat(2 * zeta * sqrt(k)) * v
            v += a * CGFloat(h)
            x += v * CGFloat(h)
        }

        var settled: Bool { abs(target - x) < 0.01 && abs(v) < 0.05 }
    }

    var morphs: [Int: Morph] = [:]
    /// The blurred pictures the folding emotes are drawn as.
    var pictures: [Int: SnapWheelEmotePicture] = [:]
    var isCollapsed = false
    /// A reveal waiting for the like to be born.
    var waitsForLike = false
    var holdUntil: CFTimeInterval = 0
    var lastTick: CFTimeInterval = 0
    var link: CADisplayLink?

    var isFolding: Bool { !morphs.isEmpty }
}

extension SnapShortcutRailView {
    /// The like at rest, in the wheel's content: the bottom strip's middle —
    /// the heart, where the emotes fold to and are born from.
    private var heartInContent: CGPoint {
        CGPoint(x: bounds.width / 2, y: bounds.origin.y + bounds.height - bottomReservedInset / 2)
    }

    /// An emote's shown opacity at rest: its top exit and the bottom mask.
    private func shownAlpha(_ icon: UIView) -> CGFloat {
        let y = icon.center.y - bounds.origin.y
        let solidEnd = bounds.height - bottomReservedInset - Self.edgeFadeLength
        let mask = max(0, min(1, 1 - (y - solidEnd) / max(Self.edgeFadeLength, 1)))
        return icon.alpha * mask
    }

    /// The visible emotes fold into the like.
    func collapseEmotes(animated: Bool) {
        let fold = self.fold
        fold.waitsForLike = false
        guard !fold.isCollapsed else { return }
        let start = icons.enumerated().map { ($0.offset, shownAlpha($0.element), $0.element.transform.a) }
        fold.isCollapsed = true
        isUserInteractionEnabled = false
        setContentOffset(contentOffset, animated: false)
        guard animated, window != nil else {
            endFold()
            applyFollow()
            return
        }
        let heart = heartInContent
        for (index, alpha, scale) in start {
            var morph: SnapWheelFold.Morph
            if let current = fold.morphs[index] {
                morph = current
            } else {
                guard alpha > 0.02 else { continue }
                morph = SnapWheelFold.Morph()
                morph.s = SnapWheelFold.Spring(scale)
                morph.a = SnapWheelFold.Spring(alpha)
                makePicture(for: index)
            }
            let icon = icons[index]
            morph.aim(dx: heart.x - icon.center.x, dy: heart.y - icon.center.y, s: SnapGlassColumn.bornScale, a: 0)
            fold.morphs[index] = morph
        }
        fold.holdUntil = CACurrentMediaTime() + SnapGlassColumn.startDelay
        startFoldLink()
        setNeedsLayout()
    }

    /// The resting window's emotes come out of the like — once it is born.
    func revealEmotes(animated: Bool) {
        let fold = self.fold
        guard fold.isCollapsed else { return }
        guard animated, window != nil else {
            fold.isCollapsed = false
            fold.waitsForLike = false
            endFold()
            isUserInteractionEnabled = true
            contentOffset.y = -contentInset.top
            setNeedsLayout()
            applyFollow()
            return
        }
        if let follow, follow() == nil {
            fold.waitsForLike = true
            startFoldLink()
        } else {
            beginReveal()
        }
    }

    private func beginReveal() {
        let fold = self.fold
        fold.waitsForLike = false
        fold.isCollapsed = false
        isUserInteractionEnabled = true
        if fold.morphs.isEmpty {
            // From rest: the window's emotes are born in the like.
            contentOffset.y = -contentInset.top
            let heart = heartInContent
            for index in 0..<min(Self.restingIconCount, icons.count) {
                let icon = icons[index]
                var morph = SnapWheelFold.Morph()
                morph.dx = SnapWheelFold.Spring(heart.x - icon.center.x)
                morph.dy = SnapWheelFold.Spring(heart.y - icon.center.y)
                morph.s = SnapWheelFold.Spring(SnapGlassColumn.bornScale)
                morph.a = SnapWheelFold.Spring(0)
                fold.morphs[index] = morph
                makePicture(for: index)
            }
        }
        // An interrupted fold: the same emotes go back from where they are.
        for index in fold.morphs.keys { fold.morphs[index]?.aim(dx: 0, dy: 0, s: 1, a: 1) }
        fold.holdUntil = CACurrentMediaTime() + SnapGlassColumn.startDelay
        startFoldLink()
        setNeedsLayout()
    }

    private func makePicture(for index: Int) {
        guard fold.pictures[index] == nil, index < tiles.count else { return }
        dressForFold(index)
        let picture = SnapWheelEmotePicture(
            levels: SnapGlassColumn.blurLevels(of: tiles[index], size: CGSize(width: Self.iconDiameter, height: Self.iconDiameter))
        )
        addSubview(picture)
        fold.pictures[index] = picture
    }

    /// Drops every fold picture and spring.
    private func endFold() {
        fold.morphs.removeAll()
        for picture in fold.pictures.values { picture.removeFromSuperview() }
        fold.pictures.removeAll()
        setNeedsLayout()
    }

    /// Draws the folding emotes as their pictures (called from layout).
    func layoutFoldPictures() {
        for (index, picture) in fold.pictures {
            guard let morph = fold.morphs[index], index < icons.count else { continue }
            let icon = icons[index]
            let alpha = max(0, min(1, morph.a.x))
            let scale = max(morph.s.x, 0.01)
            picture.center = CGPoint(x: icon.center.x + morph.dx.x, y: icon.center.y + morph.dy.x)
            picture.transform = CGAffineTransform(scaleX: scale, y: scale)
            picture.alpha = alpha
            picture.blur = SnapGlassColumn.maxBlur * (1 - alpha)
        }
    }

    private func startFoldLink() {
        guard fold.link == nil else { return }
        fold.lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: FoldTick(self), selector: #selector(FoldTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        fold.link = link
    }

    fileprivate func foldTick(_ link: CADisplayLink) {
        let fold = self.fold
        let now = link.targetTimestamp
        let dt = min(max(0, now - max(fold.lastTick, fold.holdUntil)), 0.05)
        fold.lastTick = now
        if fold.waitsForLike, follow?() != nil { beginReveal() }
        if !fold.morphs.isEmpty {
            let steps = max(1, Int(ceil(dt / 0.004)))
            for _ in 0..<steps {
                for index in fold.morphs.keys { fold.morphs[index]?.step(dt / Double(steps)) }
            }
            if fold.morphs.values.allSatisfy(\.settled) {
                endFold()
                // Folded: at rest, every emote hidden.
                if fold.isCollapsed { contentOffset.y = -contentInset.top }
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        let following = applyFollow()
        if fold.morphs.isEmpty, !fold.waitsForLike, !following {
            link.invalidate()
            fold.link = nil
        }
    }

    /// Hangs the wheel on the like as drawn. True while the like is not at
    /// rest in its place.
    ///
    /// A point p of the wheel (in its superview) goes to C + s (p − R), R the
    /// like's centre at rest — the PILL's centre: the like is a pill, taller
    /// than the wheel's strip.
    @discardableResult
    func applyFollow() -> Bool {
        guard let follow else { return false }
        guard let like = follow() else {
            alpha = 0
            return false
        }
        let origin = center
        let rest = CGPoint(
            x: origin.x,
            y: origin.y + bounds.height / 2 - bottomReservedInset + max(capsule.likeHeight, bottomReservedInset) / 2
        )
        let scale = like.scale
        let t = CGPoint(
            x: like.centre.x - scale * rest.x - (1 - scale) * origin.x,
            y: like.centre.y - scale * rest.y - (1 - scale) * origin.y
        )
        let atRest = abs(t.x) < 0.25 && abs(t.y) < 0.25 && abs(scale - 1) < 0.002
        transform = atRest
            ? .identity
            : CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: max(scale, 0.01), y: max(scale, 0.01))
        alpha = 1
        return !atRest
    }
}

/// Holds the wheel for its fold's display link without keeping it alive.
@MainActor
private final class FoldTick: NSObject {
    weak var rail: SnapShortcutRailView?
    init(_ rail: SnapShortcutRailView) { self.rail = rail }

    @objc func tick(_ link: CADisplayLink) {
        guard let rail else { return link.invalidate() }
        rail.foldTick(link)
    }
}

/// A folding emote: its picture blurred at six levels, the shown blur
/// between two of them (the column's items do the same).
final class SnapWheelEmotePicture: UIView {
    private let lower = UIImageView()
    private let upper = UIImageView()
    private let levels: [UIImage]
    private var shownLevel = -1

    var blur: CGFloat = 0 {
        didSet {
            guard levels.count > 1, blur != oldValue || shownLevel < 0 else { return }
            let position = max(0, min(1, blur / SnapGlassColumn.maxBlur)) * CGFloat(levels.count - 1)
            let index = min(Int(position), levels.count - 2)
            let fraction = position - CGFloat(index)
            if index != shownLevel {
                lower.image = levels[index]
                upper.image = levels[index + 1]
                shownLevel = index
            }
            lower.alpha = 1 - fraction
            upper.alpha = fraction
        }
    }

    init(levels: [UIImage]) {
        self.levels = levels
        let size = levels.first?.size ?? .zero
        super.init(frame: CGRect(origin: .zero, size: size))
        isUserInteractionEnabled = false
        for view in [lower, upper] {
            view.frame = bounds
            view.contentMode = .center
            addSubview(view)
        }
        lower.image = levels.first
        upper.alpha = 0
        shownLevel = levels.isEmpty ? -1 : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
