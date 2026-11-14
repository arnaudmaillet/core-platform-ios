#if DEBUG
import LaunchArguments
import UIKit

/// `-pull-refresh-trace` (#2235): where each pull to refresh fills its ring,
/// ticks and fires, on every screen, in the same two units.
///
/// The owner felt the profile and For You fire "as soon as I slide down from
/// the top", and Messages only once the pull has gone far. Nobody had
/// measured either distance, so the rule was argued from the code. This
/// prints, for every pull:
/// - `full`, `tick`, `trigger`: the moment the ring is full, the tick sounds
///   and the refresh fires. `trigger` names who fired it: `rule` (the shared
///   decision, `PullRefreshRule`), `native` (UIKit's own `UIRefreshControl`
///   distance) or `release` (a drag ended past the threshold);
/// - `release`: the finger lifting, with the deepest overscroll of the pull;
/// - for each: the content's overscroll past the list's top (`overscroll`,
///   what the threshold is expressed in), the finger's travel since the
///   content crossed its top (`finger`, larger because of the rubber band),
///   the drag's whole travel (`drag`) and whether a finger was down.
///
/// One line per moment, `[pull-refresh] <screen> <moment> …`, the screen
/// being the nearest view controller's type.
@MainActor
final class PullRefreshTrace {
    static let isEnabled = DebugFlags.isOn("-pull-refresh-trace")

    enum Moment: String {
        case full, tick, trigger, release
    }

    private weak var view: UIView?
    private lazy var screen: String = {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return String(describing: type(of: controller)) }
            responder = current.next
        }
        return view.map { String(describing: type(of: $0)) } ?? "?"
    }()
    /// The pan's translation when the content crossed its top under the
    /// finger — where the finger's travel of the pull starts.
    private var topTranslation: CGFloat?
    private var deepest: CGFloat = 0
    private var wasTracking = false
    private var marked: Set<Moment> = []
    private var fired = false

    init(view: UIView) {
        self.view = view
    }

    /// Every reading of the pull.
    func follow(pulled: CGFloat, isTracking: Bool, threshold: CGFloat, scrollView: UIScrollView?) {
        guard Self.isEnabled else { return }
        if wasTracking, !isTracking {
            mark(.release, pulled: pulled, isTracking: false, scrollView: scrollView,
                 note: String(format: " deepest=%.1f fired=%d", deepest, fired ? 1 : 0))
            topTranslation = nil
        }
        if isTracking, !wasTracking {
            // A drag began: a new pull.
            marked = []
            fired = false
            deepest = 0
            topTranslation = pulled >= 0 ? translation(scrollView) : nil
        } else if !isTracking, pulled <= 0 {
            // At rest again, or a bounce over: the next overscroll is a new
            // pull too.
            marked = []
            fired = false
            deepest = 0
        }
        if isTracking, topTranslation == nil, pulled >= 0 { topTranslation = translation(scrollView) }
        wasTracking = isTracking
        deepest = max(deepest, pulled)
        if pulled >= threshold, !marked.contains(.full) {
            mark(.full, pulled: pulled, isTracking: isTracking, scrollView: scrollView)
        }
    }

    /// A moment of the pull, once per pull.
    func mark(_ moment: Moment, pulled: CGFloat, isTracking: Bool, scrollView: UIScrollView?, note: String = "") {
        guard Self.isEnabled else { return }
        guard moment == .release || !marked.contains(moment) else { return }
        marked.insert(moment)
        if moment == .trigger { fired = true }
        let drag = translation(scrollView)
        let finger = topTranslation.map { drag - $0 } ?? 0
        print(String(
            format: "[pull-refresh] %@ %@ overscroll=%.1f finger=%.1f drag=%.1f tracking=%d%@",
            screen, moment.rawValue, pulled, finger, drag, isTracking ? 1 : 0, note
        ))
    }

    /// The finger's travel since the drag began, in the window's space: the
    /// scroll view's own space moves with its offset.
    private func translation(_ scrollView: UIScrollView?) -> CGFloat {
        scrollView?.panGestureRecognizer.translation(in: nil).y ?? 0
    }
}
#endif
