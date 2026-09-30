import QuartzCore
import UIKit

/// What lies under what the collapsed sound sheet is for fades in as the
/// sheet grows from collapsed toward its expanded detent, and out as it comes
/// back down: under a Popular row, the "Recent" title and its grid, as one;
/// with "Recent" alone, its rows after the first
/// (`SoundSheetViewController.revealLine`).
///
/// **FAINT AT COLLAPSED, NEVER GONE** (`restingOpacity`): what lies under the
/// line stands over and behind the toolbar at the collapsed detent, there but
/// not yet read — what says the sheet has more below (asked for, 2026-09-30:
/// "barely visible" at collapsed).
///
/// **A MASK ON THE SHEET'S SCREEN, NOT AN ALPHA PER CELL.** Two opaque bands:
/// everything above `line` (the sound, the Popular row or the first row of
/// "Recent") always shows; the band below shows at `opacity(progress:)`. A collection view re-applies its
/// layout
/// attributes' alpha to a cell on every layout pass, and cells come and go
/// as rows scroll — so an alpha per cell would be fought over by the layout
/// and rebuilt per cell. The mask is one layer, whatever is under it. At
/// `progress` 1 it is taken off, so a sheet at its expanded detent pays no offscreen pass.
/// Nothing here is native chrome: the toolbar lives in the navigation
/// controller's view, not in the masked one.
///
/// **DRIVEN BY THE HEIGHT THE SHEET IS DRAWN AT, FRAME BY FRAME.** A
/// `CADisplayLink` reads the screen's PRESENTATION layer (`measure`): the
/// finger's drag moves the model frame, but the spring after the release is
/// a Core Animation of it, whose in-between heights only the presentation
/// layer knows. The link sleeps whenever the height is still: it is woken by
/// what can move the sheet (`wake` — a layout pass, a detent change,
/// appearing) and goes back to sleep after `restFrames` still frames.
///
/// ⚠️ **IT WRITES AN OPACITY ON ONE LAYER AND NOTHING ELSE.** No frame, no
/// constraint, no detent: nothing it does can lay the sheet out, so the
/// layout pass that wakes it cannot be re-entered by it — the recursion that
/// crashed #296 (a detent re-measured from a layout) has no path here.
@MainActor
final class SoundSheetReveal: NSObject {
    /// How far toward its expanded detent the sheet must travel for the lower
    /// sections to be whole: at 60% of the way they are, so they read before
    /// the sheet lands rather than as it lands.
    static let reach: CGFloat = 0.6
    /// Still frames before the link sleeps (~0.25s at 120Hz).
    static let restFrames = 30
    /// The fading band's opacity at progress 0 — the collapsed detent.
    static let restingOpacity: CGFloat = 0.25

    /// The fading band's opacity at `progress`: `restingOpacity` at 0, whole
    /// at 1, linear between.
    static func opacity(progress: CGFloat) -> CGFloat {
        restingOpacity + (1 - restingOpacity) * min(1, max(0, progress))
    }

    /// 0 at the collapsed detent (and below it, as the sheet leaves), 1 from
    /// `reach` of the way to the expanded detent up — linear in the sheet's
    /// height, so the content follows the finger. A PURE function of the
    /// height: the same height always reads the same.
    static func progress(height: CGFloat, collapsed: CGFloat, expanded: CGFloat) -> CGFloat {
        let span = (expanded - collapsed) * reach
        guard span > 1 else { return height > collapsed ? 1 : 0 }
        return min(1, max(0, (height - collapsed) / span))
    }

    private(set) var progress: CGFloat = 0
    /// The progress the sheet's drawn height says now; nil when it cannot be
    /// read (no window).
    var measure: (() -> CGFloat?)?
    /// A new progress was applied — the trace's hook.
    var onChange: ((CGFloat) -> Void)?

    private let mask = CALayer()
    private let shown = CALayer()
    private let fading = CALayer()
    private weak var host: UIView?
    private var link: CADisplayLink?
    private var stillFrames = 0

    /// Taller than any sheet: the fading band must still cover the screen
    /// while a spring draws it taller than its model frame.
    private static let reachDown: CGFloat = 10_000

    override init() {
        super.init()
        for band in [shown, fading] {
            band.backgroundColor = UIColor.black.cgColor
            mask.addSublayer(band)
        }
    }

    func attach(to view: UIView) {
        host = view
        apply()
    }

    /// Where the always-shown part ends, in the host's coordinates — it moves
    /// with the content's scroll.
    func setLine(_ line: CGFloat, width: CGFloat) {
        let y = max(0, line)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: Self.reachDown)
        shown.frame = CGRect(x: 0, y: 0, width: width, height: y)
        fading.frame = CGRect(x: 0, y: y, width: width, height: Self.reachDown - y)
        CATransaction.commit()
    }

    /// Sets the progress outright — a detent reached, a test.
    func set(_ progress: CGFloat) {
        guard progress != self.progress else { return }
        self.progress = progress
        apply()
        onChange?(progress)
    }

    /// Something may move the sheet: watch its height until it is still.
    func wake() {
        stillFrames = 0
        guard link == nil, host?.window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func sleep() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let measured = measure?() else {
            sleep()
            return
        }
        if abs(measured - progress) > 0.001 {
            stillFrames = 0
            set(measured)
        } else {
            stillFrames += 1
            if stillFrames >= Self.restFrames { sleep() }
        }
    }

    private func apply() {
        guard let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fading.opacity = Float(Self.opacity(progress: progress))
        let masked = progress < 1
        if masked, host.layer.mask !== mask {
            host.layer.mask = mask
        } else if !masked, host.layer.mask === mask {
            host.layer.mask = nil
        }
        CATransaction.commit()
    }

    /// Whether the mask is on the screen — what a test reads.
    var isMasking: Bool { host?.layer.mask === mask }
    /// The fading band's opacity — what a test reads.
    var fadingOpacity: Float { fading.opacity }
}
