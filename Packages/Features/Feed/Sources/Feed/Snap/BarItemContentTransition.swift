import CoreImage
import UIKit

/// Changes what a bar item's custom view DRAWS through a blur — the old
/// content blurs out, the new blurs in — while the item itself, its glass
/// platter and its identifier stay put.
///
/// ⚠️ WHY NOT THE BAR'S OWN TRANSITION. The feed's author pill and audio
/// capsule used to be a fresh item per content under a per-content
/// `identifier` (#277, #295), so iOS 26 ran its native item replacement: the
/// glass MORPHED between the two platters while the contents blurred. The
/// morph was the part that read as UIKit machinery rather than the screen's
/// own — the capsule itself visibly changed shape on every page. So each slot
/// is ONE item now, under one stable identifier, and only its content
/// transitions, here.
///
/// ⚠️ PUBLIC API ONLY, and why it is snapshots. Core Animation's `filters`
/// (a live Gaussian blur on a layer) are private on iOS, and a
/// `UIVisualEffectView` over the content would blur the GLASS behind it too
/// and lay its own material over the platter. What is left is a blurred
/// BITMAP of each state: the live content is rendered (`CALayer.render`),
/// blurred with Core Image, and the two stills are cross-faded against the
/// live content —
///
///   live old ──fades──▶ blurred old ──▶ blurred new ──fades──▶ live new
///
/// — with the content swapped at the midpoint, when nothing live is showing.
///
/// ⚠️ EVERY FADE IS ON A CONTAINER. A toolbar platter renders a LABEL's
/// partial alpha as opaque (vibrant content — memory
/// `platter-flattens-label-alpha`), so a fade written on the labels would read
/// as a one-frame switch. The live content is faded through the host's
/// `content` container and each still sits in a plain container of its own,
/// and a container's group opacity survives the platter.
///
/// Reduce Motion drops the stills: the same timeline, as a plain fade.
@MainActor
final class BarItemContentTransition {
    /// The two halves of the timeline. Together about the length of iOS 26's
    /// own item replacement (~270ms measured), so the swap reads at the pace
    /// the bar's other transitions set.
    static let fadeOutDuration: TimeInterval = 0.12
    static let fadeInDuration: TimeInterval = 0.2
    /// The blur of the stills, in points. Enough to dissolve a caption-sized
    /// line; a heavier blur smears into the glass as a grey bar.
    static let blurRadius: CGFloat = 4

    private unowned let host: UIView
    private unowned let content: UIView

    /// Resizes the bar item for content that has just been swapped in: with a
    /// duration it glides (the new content is invisible for the whole glide),
    /// with nil it lands at once. Called in the same turn as the swap.
    var remeasure: ((_ duration: TimeInterval?) -> Void)?
    /// After the swap has been applied — immediately for an unanimated change,
    /// at the midpoint of an animated one. For host decisions that read the
    /// content (a width budget computed off the labels).
    var didApply: (() -> Void)?
    /// Once a transition has fully landed (live content sharp and opaque).
    var didSettle: (() -> Void)?

    /// Bumped by every start and every interruption, so a completion from a
    /// timeline that has been superseded does nothing.
    private var generation = 0
    /// Changes waiting for the midpoint: everything asked for while the old
    /// content is fading out lands in ONE swap.
    private var pending: [() -> Void] = []
    private var isFadingOut = false
    /// The stills on the host right now.
    private var stills: [UIView] = []

    /// - Parameters:
    ///   - host: the bar item's custom view; the stills are added to it.
    ///   - content: the container, edge-pinned inside `host`, holding every
    ///     live subview the change touches.
    init(host: UIView, content: UIView) {
        self.host = host
        self.content = content
    }

    /// Whether a swap is under way.
    var isRunning: Bool { isFadingOut || !stills.isEmpty }

    /// Applies `change` to the live content — through the blur when `animated`
    /// and the host is on screen, at once otherwise.
    ///
    /// A change asked for while the old content is still fading out joins that
    /// swap. One asked for later interrupts: the running timeline jumps to its
    /// end and a new one starts from the sharp content, which is the one frame
    /// a feed paged faster than 0.3s a page can show.
    func perform(animated: Bool, _ change: @escaping () -> Void) {
        if isFadingOut {
            pending.append(change)
            return
        }
        finish()
        guard animated, host.window != nil, content.bounds.width > 0 else {
            change()
            didApply?()
            remeasure?(nil)
            didSettle?()
            return
        }
        generation += 1
        let generation = generation
        let old = still(of: content)
        pending = [change]
        isFadingOut = true
        UIView.animate(
            withDuration: Self.fadeOutDuration, delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            self.content.alpha = 0
            old?.alpha = 1
        } completion: { _ in
            guard generation == self.generation else { return }
            self.swap(generation: generation, old: old)
        }
    }

    /// Runs `change` with the NEW content: at the midpoint when a swap is
    /// fading the old content out (so a late arrival — a picture fetched for
    /// the new author — is never drawn onto the old one), at once otherwise.
    func afterSwap(_ change: @escaping () -> Void) {
        if isFadingOut {
            pending.append(change)
        } else {
            change()
        }
    }

    /// Jumps any running swap to its end state: pending changes applied, the
    /// stills gone, the live content opaque.
    func finish() {
        generation += 1
        if isFadingOut {
            isFadingOut = false
            let changes = pending
            pending = []
            changes.forEach { $0() }
            didApply?()
            remeasure?(nil)
        }
        content.layer.removeAllAnimations()
        content.alpha = 1
        stills.forEach { $0.removeFromSuperview() }
        stills = []
    }

    private func swap(generation: Int, old: UIView?) {
        isFadingOut = false
        let changes = pending
        pending = []
        changes.forEach { $0() }
        didApply?()
        // The item takes its new width FIRST, so the new content is laid out
        // — and its still rendered — at the size it will land at. The glide
        // runs while only stills are showing.
        remeasure?(Self.fadeInDuration)
        host.layoutIfNeeded()
        let new = still(of: content)
        UIView.animateKeyframes(
            withDuration: Self.fadeInDuration, delay: 0,
            options: [.allowUserInteraction, .calculationModeLinear]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.4) {
                old?.alpha = 0
                new?.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.4, relativeDuration: 0.6) {
                new?.alpha = 0
                self.content.alpha = 1
            }
        } completion: { _ in
            guard generation == self.generation else { return }
            self.stills.forEach { $0.removeFromSuperview() }
            self.stills = []
            self.didSettle?()
        }
    }

    /// A blurred still of `view` as it draws now, added to the host at alpha 0
    /// — or nil under Reduce Motion, or for a view with nothing to draw.
    ///
    /// Pinned to the LEADING edge at its own size, never stretched: the item's
    /// width glides under it while it shows, and everything in these pills is
    /// leading-aligned, so the still stays over what it pictures.
    private func still(of view: UIView) -> UIView? {
        guard !UIAccessibility.isReduceMotionEnabled,
              let (image, frame) = Self.blurredSnapshot(of: view, radius: Self.blurRadius) else { return nil }
        let container = UIView(frame: view.convert(frame, to: host))
        container.isUserInteractionEnabled = false
        container.alpha = 0
        container.autoresizingMask = host.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .flexibleLeftMargin : .flexibleRightMargin
        let imageView = UIImageView(image: image)
        imageView.frame = container.bounds
        container.addSubview(imageView)
        host.addSubview(container)
        stills.append(container)
        return container
    }

    // MARK: - Rendering

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `view` rendered as it draws now and blurred by `radius` points, with the
    /// frame (in `view`'s own space) the image covers: its bounds, grown so the
    /// blur fades out instead of being cut at the edge.
    ///
    /// Rendered from the LAYER tree (`CALayer.render`), which needs no window
    /// and no screen update. The view is drawn opaque whatever its alpha is
    /// mid-fade, and every layer is displayed first, so text set in this very
    /// turn — or a colour that just changed with the bar's theme — is what
    /// gets pictured.
    static func blurredSnapshot(of view: UIView, radius: CGFloat) -> (UIImage, CGRect)? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        view.layoutIfNeeded()
        displayTree(view.layer)
        let pad = ceil(radius * 3)
        let canvas = bounds.insetBy(dx: -pad, dy: -pad)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.preferredRange = .standard
        let alpha = view.alpha
        view.alpha = 1
        let sharp = UIGraphicsImageRenderer(size: canvas.size, format: format).image { context in
            context.cgContext.translateBy(x: -canvas.minX, y: -canvas.minY)
            view.layer.render(in: context.cgContext)
        }
        view.alpha = alpha
        guard let cgImage = sharp.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let blurred = input.applyingGaussianBlur(sigma: Double(radius * sharp.scale)).cropped(to: input.extent)
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        return (UIImage(cgImage: output, scale: sharp.scale, orientation: .up), canvas)
    }

    private static func displayTree(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(displayTree)
    }
}

/// Re-measures a bar item's custom view after its content changed — the one
/// width path both pills share.
///
/// ⚠️ THE ITEM IS NEVER RE-HANDED FOR IT. Re-handing a kept item leaves UIKit's
/// custom-view wrapper at a width that drifts from the view's (memory
/// `bar-item-wrapper-drift`); what is asked for here is a LAYOUT of the bar
/// that hosts the wrapper, so the bar measures the view again.
///
/// ⚠️ THE TOOLBAR'S GLASS IS NOT IN `UIToolbar` on iOS 26/27: its platters are
/// hosted in a floating-bar container directly under the navigation
/// controller's view (see `SnapFeedViewController.toolbarGlassHost`). So the
/// walk stops at a bar, or else at the ancestor whose superview is a view
/// controller's root view — public API only, no private class names.
@MainActor
enum BarItemRemeasure {
    static func run(_ view: UIView, duration: TimeInterval?) {
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        var host: UIView = view
        var current: UIView? = view.superview
        while let parent = current {
            parent.setNeedsLayout()
            host = parent
            if parent is UINavigationBar || parent is UIToolbar { break }
            if let above = parent.superview, above.next is UIViewController { break }
            current = parent.superview
        }
        // Unanimated: the bar's next pass measures it. Forcing that pass here
        // would lay a bar out from inside whatever transition owns it.
        guard let duration else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            host.layoutIfNeeded()
        }
    }
}
