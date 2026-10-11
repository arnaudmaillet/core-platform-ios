import Foundation
import QuartzCore

/// Whether a post page is announcing a wait for its media — the spinner over
/// a picture that has not arrived — moved out of `SnapFeedCell` (#857).
///
/// The page says whether it has its own picture (`hasItsOwnMedia`: the image
/// landed, or the clip's surface decoded a frame), and calls `refresh()` from
/// every place that answer can change; this decides when the spinner goes up
/// and down. A missing picture is announced only after `grace`, and asked
/// AGAIN when the grace runs out.
///
/// Kept free of views: the page's answer, the loader's state and the switch
/// are closures, so the rule is tested with plain values
/// (`SnapMediaWaitTests`).
@MainActor
final class SnapMediaWait {
    /// How long a page may be missing its media before it says so.
    ///
    /// ⚠️ NOT ZERO, and the number is the whole design. A cached picture lands
    /// within a frame or two of `configure`, so a spinner shown the instant a
    /// page has nothing would flash on almost every page change — motion that
    /// means "waiting" appearing where there was no wait is worse than the
    /// silence it replaces. A quarter of a second is long enough that anything
    /// still missing is a real fetch, and short enough that a real fetch is
    /// announced before the viewer wonders.
    static let grace: TimeInterval = {
        #if DEBUG
        // `-media-wait-grace <ms>`: shortens (or removes) the delay, so the
        // state can be filmed. It is otherwise close to unreachable in the
        // simulator — the transition hands a page the picture it flew in with,
        // and the warm window has the neighbours ready — which is the system
        // working, and also why "I could not see it" is not evidence that it
        // does not work.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-media-wait-grace"),
           position + 1 < arguments.count, let milliseconds = Double(arguments[position + 1]) {
            return milliseconds / 1000
        }
        #endif
        return 0.25
    }()

    /// Whether the media area has the post's OWN picture on it.
    private let hasItsOwnMedia: () -> Bool
    /// Whether the spinner is up right now.
    private let isShowingLoader: () -> Bool
    /// Puts the spinner up, or takes it down.
    private let setLoading: (Bool) -> Void

    #if DEBUG
    /// The media's file name, for the `-media-log` trace.
    var debugSubject: () -> String = { "nil" }
    #endif

    private var timer: Timer?

    /// Whether the grace is running.
    var isArmed: Bool { timer != nil }

    init(
        hasItsOwnMedia: @escaping () -> Bool,
        isShowingLoader: @escaping () -> Bool,
        setLoading: @escaping (Bool) -> Void
    ) {
        self.hasItsOwnMedia = hasItsOwnMedia
        self.isShowingLoader = isShowingLoader
        self.setLoading = setLoading
    }

    /// Re-decides whether the page is announcing a wait.
    ///
    /// Called from every place the answer can change — the bind, the image
    /// landing, the first decoded frame, a carousel page turn — rather than
    /// polled: this is a fact the media surfaces already know, and asking them
    /// on a timer would be inventing a signal that exists.
    func refresh() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-media-log") {
            print(String(format: "[media-wait] %.3f decide own=%@ armed=%@ showing=%@ url=%@",
                         CACurrentMediaTime(), hasItsOwnMedia() ? "Y" : "n",
                         timer == nil ? "n" : "Y",
                         isShowingLoader() ? "Y" : "n",
                         debugSubject()))
        }
        #endif
        guard !hasItsOwnMedia() else {
            timer?.invalidate()
            timer = nil
            setLoading(false)
            return
        }
        guard timer == nil, !isShowingLoader() else { return }
        let armed = Timer.scheduledTimer(
            withTimeInterval: Self.grace, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                // Asked AGAIN at the end of the grace, never assumed: the whole
                // point of waiting is that the answer may have changed.
                self.setLoading(!self.hasItsOwnMedia())
            }
        }
        timer = armed
    }

    /// Drops the wait entirely — the recycle path.
    func cancel() {
        timer?.invalidate()
        timer = nil
        setLoading(false)
    }

    #if DEBUG
    /// Runs the grace out now, so a spec does not have to sleep for it.
    func debugElapseGrace() {
        timer?.invalidate()
        timer = nil
        setLoading(!hasItsOwnMedia())
    }
    #endif
}
