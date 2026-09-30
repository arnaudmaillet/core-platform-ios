#if DEBUG
import UIKit

/// `-list-jump-trace`: where a pushed list's first row is, frame by frame,
/// across a post's open and close — the instrument for "the list jumps when I
/// come back from a post" (2026-09-30, Following / Friends / the mosaic).
///
/// A jump is a change in ONE number — the first visible row's top edge in the
/// window — and the three that decide it (`ForYouGridPage.debugInsetState`:
/// offset, adjusted inset, whether it is pinned). `mark` prints them once;
/// `begin` also follows them on every display frame for a while and prints a
/// line only when one of them changes, so a quiet return prints one line and a
/// jump prints the frame it happened on.
@MainActor
enum PushedListJumpTrace {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-list-jump-trace")
    }

    /// One reading, now.
    static func mark(_ label: String, page: ForYouGridPage, host: UIView) {
        guard isEnabled else { return }
        print("[list-jump] \(label) \(reading(page: page, host: host))")
    }

    /// A reading now, then one per frame whenever it changes, for `seconds`.
    static func begin(_ label: String, page: ForYouGridPage, host: UIView, seconds: CFTimeInterval = 2) {
        guard isEnabled else { return }
        mark(label, page: page, host: host)
        Follower(label: label, page: page, host: host, until: CACurrentMediaTime() + seconds).start()
    }

    fileprivate static func reading(page: ForYouGridPage, host: UIView) -> String {
        let row = host.window.flatMap { page.debugFirstVisibleItem(in: $0) }
        let top = row.map { String(format: "%@@%.1f", $0.id, $0.minY) } ?? "none"
        return String(
            format: "row=%@ safeTop=%.1f window=%@ %@",
            top, host.safeAreaInsets.top, host.window == nil ? "N" : "Y", page.debugInsetState
        )
    }

    /// Holds itself alive through the display link until its deadline.
    @MainActor
    private final class Follower: NSObject {
        let label: String
        weak var page: ForYouGridPage?
        weak var host: UIView?
        let until: CFTimeInterval
        var last: String?
        var link: CADisplayLink?
        var retained: Follower?

        init(label: String, page: ForYouGridPage, host: UIView, until: CFTimeInterval) {
            self.label = label
            self.page = page
            self.host = host
            self.until = until
        }

        func start() {
            retained = self
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc func tick() {
            guard let page, let host, CACurrentMediaTime() < until else {
                link?.invalidate()
                link = nil
                retained = nil
                return
            }
            let now = PushedListJumpTrace.reading(page: page, host: host)
            guard now != last else { return }
            last = now
            print(String(format: "[list-jump] %@ +%.3f %@", label, CACurrentMediaTime(), now))
        }
    }
}
#endif
