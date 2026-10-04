import Accelerate
import DesignSystem
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
/// blurred (vImage, at 1x), and the two stills are cross-faded against the
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
/// and a container's group opacity survives the platter. Filmed at 60fps on
/// iOS 27 (iPhone 18 Pro, light and dark, both bars, the follow badge): the
/// old content visibly blurs out over ~7 frames, the glass holds its shape,
/// and the new content sharpens over ~8. In the snap feed the glass does not
/// even change width — both pills are FIXED there (`SnapBarPillWidths`) — so
/// the width path below (`remeasure`) serves only the hosts whose pill still
/// hugs its content.
///
/// TWO DRIVERS, ONE MECHANISM.
/// - The CLOCK (`perform`): the timeline above, 0.12s out and 0.2s in — a
///   follow tap turning the "+" into the followed mark, a page reached
///   without a scroll (a jump, a landing).
/// - The SCROLL (`setScrubBlur`, asked 2026-09-30): the snap feed's paging
///   sets the blur amount frame by frame (`BarPillScrub`: rising from 30%,
///   full at the midpoint, gone at 70%) and the content swaps under the full
///   blur at the midpoint. Per frame only two container alphas are written;
///   a still is rendered when the scrub begins (or the drag that may start
///   one) and at each swap, never per frame.
///
/// Reduce Motion drops the stills: the same timelines, as a plain fade.
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

    // WEAK, not unowned: the fade's completion blocks retain this object, and
    // UIKit can run them after the bar item's view has gone (a screen torn
    // down mid-fade — a CI test did exactly that and trapped reading an
    // unowned reference). A transition whose views are gone does nothing.
    private weak var host: UIView?
    private weak var content: UIView?

    /// Resizes the bar item for content that has just been swapped in: with a
    /// duration it glides (the new content is invisible for the whole glide),
    /// with nil it lands at once. Called in the same turn as the swap. A host
    /// with a fixed width leaves it doing nothing.
    var remeasure: ((_ duration: TimeInterval?) -> Void)?
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
    var isRunning: Bool { isFadingOut || !stills.isEmpty || scrubBlur > 0 }

    /// Applies `change` to the live content — through the blur when `animated`
    /// and the host is on screen, at once otherwise.
    ///
    /// A change asked for while the old content is still fading out joins that
    /// swap. One asked for later interrupts: the running timeline jumps to its
    /// end and a new one starts from the sharp content, which is the one frame
    /// a feed paged faster than 0.3s a page can show.
    ///
    /// Under a scroll-driven blur (`setScrubBlur`) the change belongs to the
    /// SCROLL: it lands under that blur, whatever `animated` says.
    func perform(animated: Bool, _ change: @escaping () -> Void) {
        if scrubBlur > 0 {
            pending.append(change)
            scheduleScrubCommit()
            return
        }
        if isFadingOut {
            pending.append(change)
            return
        }
        finish()
        guard let host, let content else { return change() }
        guard animated, host.window != nil, content.bounds.width > 0 else {
            change()
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
            self.content?.alpha = 0
            old?.alpha = 1
        } completion: { _ in
            guard generation == self.generation else { return }
            self.swap(generation: generation, old: old)
        }
    }

    /// Runs `change` with the NEW content: at the midpoint when a swap is
    /// fading the old content out (so a late arrival — a picture fetched for
    /// the new author — is never drawn onto the old one), at once otherwise.
    /// Under a scroll-driven blur it lands like any change there — under the
    /// blur, with a fresh still — so the still never pictures a face the live
    /// content no longer draws.
    func afterSwap(_ change: @escaping () -> Void) {
        if scrubBlur > 0 {
            pending.append(change)
            scheduleScrubCommit()
        } else if isFadingOut {
            pending.append(change)
        } else {
            // A still prepared for a scrub pictures the content before this.
            dropPreparedScrub()
            change()
        }
    }

    /// Jumps any running swap to its end state: pending changes applied, the
    /// stills gone, the live content opaque.
    func finish() {
        generation += 1
        if !pending.isEmpty {
            let changes = pending
            pending = []
            changes.forEach { $0() }
            remeasure?(nil)
        }
        isFadingOut = false
        content?.layer.removeAllAnimations()
        content?.alpha = 1
        stills.forEach { $0.removeFromSuperview() }
        stills = []
        scrubStill = nil
        scrubBlur = 0
        scrubSwapped = false
    }

    // MARK: - Scroll-driven

    /// How blurred the content is under the scroll right now (`setScrubBlur`).
    private(set) var scrubBlur: CGFloat = 0
    /// The blurred still of what the live content draws while the scroll owns
    /// the blur — rendered ONCE per content (when the scrub begins, when the
    /// drag that may start one begins, or at a swap), never per frame.
    private var scrubStill: UIView?
    /// Whether this scrub swapped the content — so its end is a landing the
    /// host hears about (`didSettle`), and a scrub that only blurred and came
    /// back is not.
    private var scrubSwapped = false
    private var scrubCommitScheduled = false

    /// The two stills' cross-fade at a scroll-driven swap. The swap itself is
    /// the scroll's (at the midpoint, under the full blur); the hand-over
    /// between two blurred pictures is a short fade, because a hard cut
    /// between two stills of different lengths reads as a flash.
    static let scrubSwapCrossfade: TimeInterval = 0.1

    /// Renders the still a scroll-driven blur will show, ahead of the first
    /// frame that needs it — at the start of a drag, so the render is paid
    /// before the page moves rather than on a frame of the scroll. Invisible
    /// until `setScrubBlur` raises it; dropped by the scroll's end.
    func prepareScrub() {
        guard scrubStill == nil, scrubBlur == 0, !isFadingOut, stills.isEmpty,
              let host, host.window != nil, let content, content.bounds.width > 0 else { return }
        scrubStill = still(of: content)
    }

    private func dropPreparedScrub() {
        guard scrubBlur == 0, let prepared = scrubStill else { return }
        prepared.removeFromSuperview()
        stills.removeAll { $0 === prepared }
        scrubStill = nil
    }

    /// Blurs the content by `amount` (0 sharp … 1 fully blurred), set by the
    /// SCROLL rather than by a clock: the live content fades against a blurred
    /// still of itself, and nothing else runs per call — two alphas.
    ///
    /// A content change asked for while `amount > 0` (`perform`) is applied at
    /// the next call (or at the end of this turn, when no call follows), under
    /// the blur: the live content swaps and a still of the NEW content
    /// cross-fades over the old one. Back at 0 the
    /// stills go and the live content is alone again.
    ///
    /// A timed transition still running when the scroll starts blurring jumps
    /// to its end first: one owner at a time.
    func setScrubBlur(_ amount: CGFloat) {
        let amount = min(max(amount, 0), 1)
        guard amount != scrubBlur || !pending.isEmpty || (amount == 0 && scrubStill != nil) else { return }
        guard let host, let content else { return }
        if amount > 0, scrubBlur == 0 {
            // A timed swap mid-flight gives way to a fresh start from the
            // sharp content (its pending change applied).
            if isFadingOut || stills.contains(where: { $0 !== scrubStill }) { finish() }
            guard host.window != nil, content.bounds.width > 0 else { return }
            if scrubStill == nil { scrubStill = still(of: content) }
            scrubSwapped = false
        }
        commitScrub(to: amount)
    }

    private func scheduleScrubCommit() {
        guard !scrubCommitScheduled else { return }
        scrubCommitScheduled = true
        // A change that arrives with no scroll behind it (an answer landing
        // while a finger holds the blur) is not left waiting for the finger.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrubCommitScheduled = false
            guard !self.pending.isEmpty else { return }
            self.commitScrub(to: self.scrubBlur)
        }
    }

    private func commitScrub(to amount: CGFloat) {
        guard let host, let content else { return }
        if !pending.isEmpty {
            let changes = pending
            pending = []
            changes.forEach { $0() }
            scrubSwapped = true
            // The scroll drives only fixed-width pills (the snap feed's), so
            // this does nothing there; a hugging host lands its width at once.
            remeasure?(nil)
            if amount > 0 {
                host.layoutIfNeeded()
                let previous = scrubStill
                let next = still(of: content)
                scrubStill = next
                UIView.animate(
                    withDuration: Self.scrubSwapCrossfade, delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction]
                ) {
                    previous?.alpha = 0
                    next?.alpha = amount
                } completion: { [weak self] _ in
                    previous?.removeFromSuperview()
                    self?.stills.removeAll { $0 === previous }
                }
            }
        }
        scrubBlur = amount
        UIView.performWithoutAnimation {
            content.alpha = 1 - amount
            // A still being cross-faded in keeps its fade: an alpha written
            // under a running animation is what it lands on.
            scrubStill?.alpha = amount
        }
        guard amount == 0 else { return }
        stills.forEach { $0.removeFromSuperview() }
        stills = []
        scrubStill = nil
        if scrubSwapped {
            scrubSwapped = false
            didSettle?()
        }
    }

    private func swap(generation: Int, old: UIView?) {
        isFadingOut = false
        let changes = pending
        pending = []
        changes.forEach { $0() }
        // A hugging host's item takes its new width FIRST, so the new content
        // is laid out — and its still rendered — at the size it will land at.
        // The glide runs while only stills are showing: over the first HALF of
        // the fade-in, because a glide as long as the fade-in was filmed
        // clipping the sharpening labels of a wider author against a platter
        // still growing to fit them.
        remeasure?(Self.fadeInDuration / 2)
        guard let host, let content else { return }
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
                content.alpha = 1
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
    /// Pinned to the LEADING edge at its own size, never stretched: a hugging
    /// item's width glides under it while it shows, and everything in these pills is
    /// leading-aligned, so the still stays over what it pictures.
    private func still(of view: UIView) -> UIView? {
        guard let host, !MotionPreference.reducesMotion else { return nil }
        #if DEBUG
        let started = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.arguments.contains("-pill-probe") {
                print(String(format: "[pill-probe] still %@ %.2fms",
                             "\(type(of: host))", (CACurrentMediaTime() - started) * 1000))
            }
        }
        #endif
        guard let (image, frame) = Self.blurredSnapshot(of: view, radius: Self.blurRadius) else { return nil }
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

    /// Pixels per point of a still.
    ///
    /// ⚠️ ONE, NOT THE SCREEN'S THREE. A still is blurred by `blurRadius`
    /// points, which leaves nothing finer than a few points to sample, so a 3x
    /// render only paid 9x the pixels for detail the blur then erased — and
    /// the scroll-driven swap renders its stills on a frame of the drag.
    /// Measured on the iPhone 18 Pro simulator with `-pill-probe`: 14–20ms a
    /// still (one 61ms) at 3x through Core Image; see `blurredSnapshot` for
    /// what replaced it.
    static let stillScale: CGFloat = 1

    /// `view` rendered as it draws now and blurred by `radius` points, with the
    /// frame (in `view`'s own space) the image covers: its bounds, grown so the
    /// blur fades out instead of being cut at the edge.
    ///
    /// Rendered from the LAYER tree (`CALayer.render`), which needs no window
    /// and no screen update. The view is drawn opaque whatever its alpha is
    /// mid-fade, and every layer is displayed first, so text set in this very
    /// turn — or a colour that just changed with the bar's theme — is what
    /// gets pictured.
    ///
    /// Blurred on the CPU (vImage: three box passes, a Gaussian to the eye)
    /// rather than through Core Image, whose GPU round trip — and its cold
    /// first render — cost more than the whole blur of a pill-sized bitmap.
    static func blurredSnapshot(of view: UIView, radius: CGFloat) -> (UIImage, CGRect)? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        view.layoutIfNeeded()
        displayTree(view.layer)
        let scale = stillScale
        let pad = ceil(radius * 3)
        var canvas = bounds.insetBy(dx: -pad, dy: -pad)
        let width = Int(ceil(canvas.width * scale))
        let height = Int(ceil(canvas.height * scale))
        canvas.size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let data = context.data else { return nil }
        // UIKit's orientation: origin top-left, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        let alpha = view.alpha
        view.alpha = 1
        UIGraphicsPushContext(context)
        view.layer.render(in: context)
        UIGraphicsPopContext()
        view.alpha = alpha

        // Three box passes of width k approximate a Gaussian of variance
        // 3(k²−1)/12, so k ≈ √(4σ² + 1), odd.
        let sigma = radius * scale
        var kernel = UInt32(max(3, Int((4 * sigma * sigma + 1).squareRoot().rounded())))
        if kernel % 2 == 0 { kernel += 1 }
        guard let scratch = malloc(bytesPerRow * height) else { return nil }
        defer { free(scratch) }
        var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: bytesPerRow)
        var target = vImage_Buffer(data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: bytesPerRow)
        for _ in 0..<3 {
            vImageBoxConvolve_ARGB8888(&source, &target, nil, 0, 0, kernel, kernel, nil,
                                       vImage_Flags(kvImageEdgeExtend))
            Swift.swap(&source, &target)
        }
        // After an odd number of passes the result is in `scratch`.
        if source.data != data { memcpy(data, source.data, bytesPerRow * height) }
        guard let image = context.makeImage() else { return nil }
        return (UIImage(cgImage: image, scale: scale, orientation: .up), canvas)
    }

    private static func displayTree(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(displayTree)
    }
}

/// Re-measures a bar item's custom view after its size changed: a hugging
/// pill's new content, or a fixed pill's new width (its bar's geometry moved).
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
