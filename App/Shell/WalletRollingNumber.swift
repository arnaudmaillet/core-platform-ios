import UIKit

/// A balance that ROLLS to its new value (#1479): a claim counts up, a stake
/// counts down, over a short ease-out — the figure the viewer was looking at
/// becomes the new one rather than being swapped for it. Under Reduce
/// Motion, a plain cross-fade.
///
/// It owns nothing but `label`'s text: the caller keeps its font, its
/// accessibility label (the final value, at once), and any pop it adds.
@MainActor
final class WalletRollingNumber: NSObject {
    private weak var label: UILabel?
    /// The value the label shows, or is rolling to.
    private(set) var target: Int?
    private var origin = 0
    private var started: CFTimeInterval = 0
    private var link: CADisplayLink?

    static let duration: CFTimeInterval = 0.6

    init(label: UILabel) {
        self.label = label
    }

    /// Shows `value`: rolls to it from the value shown when `animated`, sets
    /// it otherwise (a first value, a screen off the window).
    func show(_ value: Int, animated: Bool) {
        guard let label, value != target else { return }
        let from = shownValue ?? value
        target = value
        guard animated, from != value else {
            stop()
            label.text = value.formatted()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            stop()
            UIView.transition(with: label, duration: 0.25, options: .transitionCrossDissolve) {
                label.text = value.formatted()
            }
            return
        }
        origin = from
        started = CACurrentMediaTime()
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// The value drawn now — mid-roll, where the roll has got to.
    private var shownValue: Int? {
        guard let target else { return nil }
        guard link != nil else { return target }
        return Self.value(from: origin, to: target, progress: progress(at: CACurrentMediaTime()))
    }

    private func progress(at now: CFTimeInterval) -> Double {
        min(1, max(0, (now - started) / Self.duration))
    }

    @objc private func step() {
        guard let label, let target else { return stop() }
        let reached = progress(at: CACurrentMediaTime())
        label.text = Self.value(from: origin, to: target, progress: reached).formatted()
        if reached >= 1 { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    /// The figure at `progress` (0…1) of a roll, eased out: quick at first,
    /// settling on the new value.
    nonisolated static func value(from: Int, to: Int, progress: Double) -> Int {
        let eased = 1 - pow(1 - min(1, max(0, progress)), 3)
        return from + Int((Double(to - from) * eased).rounded())
    }

    /// Whether a roll is running. QA.
    var isRolling: Bool { link != nil }
}
