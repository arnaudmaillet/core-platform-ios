import Testing
import UIKit
@testable import DesignSystem

/// Toasts as navigation bar items (#1058): they replace the screen's
/// trailing items and give them back; the oldest collapse to a glyph bubble
/// when they do not all fit, never the front; no visible bar, the overlay.
@MainActor
@Suite(.serialized)
struct NavigationBarToastsTests {
    private final class Screen: UIViewController {
        let share = UIBarButtonItem(systemItem: .action)
        let search = UIBarButtonItem(systemItem: .search)
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            navigationItem.rightBarButtonItems = [search, share]
        }
    }

    private func hosting(barHidden: Bool = false, _ body: (Screen) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = Screen()
        let navigation = UINavigationController(rootViewController: screen)
        navigation.setNavigationBarHidden(barHidden, animated: false)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        let previousHaptic = Feedback.playHaptic
        ToastClock.current = clock
        Feedback.playHaptic = { _ in }
        defer {
            ToastClock.current = previousClock
            Feedback.playHaptic = previousHaptic
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(screen)
    }

    private func toasts(in screen: UIViewController) -> [ToastView] {
        (screen.navigationItem.rightBarButtonItems ?? []).compactMap { $0.customView as? ToastView }
    }

    // MARK: - The arithmetic

    /// All whole while they fit.
    @Test func everyToastIsWholeWhileTheyFit() {
        let fit = NavigationBarToasts.fit(ideals: [80, 100], budget: 400)
        #expect(fit.widths == [80, 100])
        #expect(fit.collapsed == [false, false])
    }

    /// Too many: the oldest collapse first, to a glyph bubble — never the
    /// front, which takes what is left.
    @Test func theOldestCollapseFirstAndTheFrontTakesTheRest() {
        let bubble = ToastView.Metrics.barHeight
        let budget: CGFloat = 250
        let fit = NavigationBarToasts.fit(ideals: [150, 150, 200], budget: budget)
        #expect(fit.collapsed == [true, true, false])
        #expect(fit.widths[0] == bubble && fit.widths[1] == bubble)
        let spacing = NavigationBarToasts.spacing(3)
        #expect(fit.widths[2] == min(200, budget - spacing - 2 * bubble))
        #expect(fit.widths.reduce(0, +) + spacing <= budget, "the trailing group fits: no •••")
    }

    /// It stops collapsing as soon as the rest fits.
    @Test func onlyAsManyCollapseAsNeeded() {
        let fit = NavigationBarToasts.fit(ideals: [150, 60, 100], budget: 330)
        #expect(fit.collapsed == [true, false, false])
        #expect(fit.widths == [ToastView.Metrics.barHeight, 60, 100])
    }

    // MARK: - In the bar

    /// A toast takes the trailing items' place, and they come back when it
    /// leaves.
    @Test func aToastReplacesTheTrailingItemsAndGivesThemBack() throws {
        try hosting { screen in
            let own = screen.navigationItem.rightBarButtonItems ?? []
            let toast = Feedback.info("Link copied", from: screen)
            #expect(toasts(in: screen).map(ObjectIdentifier.init) == [ObjectIdentifier(toast)])
            #expect(toast.chrome == .barItem)
            toast.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.elementsEqual(own, by: ===))
        }
    }

    /// Newest at the trailing edge; past three the oldest leaves.
    @Test func newestTrailingAndAtMostThree() {
        hosting { screen in
            let first = Feedback.info("One", from: screen)
            _ = Feedback.info("Two", from: screen)
            _ = Feedback.warning("Three", from: screen)
            let fourth = Feedback.info("Four", from: screen)
            let shown = toasts(in: screen)
            #expect(shown.count == 3)
            #expect(shown.first === fourth, "the first right item sits at the trailing edge")
            #expect(first.isDismissing)
        }
    }

    /// The same id updates the toast in place, in the bar too.
    @Test func anUpdateByIdStaysOneItem() {
        hosting { screen in
            let posting = Feedback.loading("Posting…", id: "post", from: screen)
            let posted = Feedback.success("Posted", from: screen, id: "post")
            #expect(posted === posting)
            #expect(toasts(in: screen).count == 1)
            #expect(posted.message == "Posted")
        }
    }

    /// Collapsed, a toast keeps its leading mark — a loading one its spinner
    /// — and nothing else.
    @Test func aCollapsedLoadingToastKeepsItsSpinner() throws {
        try hosting { screen in
            let toast = Feedback.loading("Posting…", id: "post", from: screen)
            toast.isCollapsedInBar = true
            let spinner = try #require(Self.views(of: UIActivityIndicatorView.self, in: toast).first)
            #expect(!spinner.isHidden)
            let shownLabels = Self.views(of: UILabel.self, in: toast).filter { !$0.isHidden }
            #expect(shownLabels.isEmpty)
        }
    }

    private static func views<View: UIView>(of type: View.Type, in view: UIView) -> [View] {
        view.subviews.flatMap { ($0 as? View).map { [$0] } ?? views(of: type, in: $0) }
    }

    /// Undo in the bar: the ring alone, no "Undo" label.
    @Test func theBarsUndoIsTheRingAlone() throws {
        try hosting { screen in
            let toast = Feedback.undoable("Unfollowed @ava", from: screen, commit: {}, undo: {})
            let ring = try #require(toast.undoButton)
            #expect(!ring.showsTitle)
            #expect(ring.accessibilityLabel == "Undo")
        }
    }

    /// A pop takes the screen away, not its toasts: they move to the bar of
    /// the screen now on top, and the popped one gets its items back.
    ///
    /// Async — the move waits a main-queue turn — so it swaps NO global
    /// state (the live clock; a toast lasts 4 s, this looks after 0.3 s).
    @Test func toastsFollowTheScreenOnTopAfterAPop() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = Screen()
        let navigation = UINavigationController(rootViewController: root)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let pushed = Screen()
        navigation.pushViewController(pushed, animated: false)
        window.layoutIfNeeded()
        let pushedOwn = pushed.navigationItem.rightBarButtonItems ?? []
        let toast = Feedback.info("Post deleted", from: pushed)
        #expect(toasts(in: pushed).first === toast)

        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        for _ in 0..<60 where toasts(in: root).first !== toast {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(toasts(in: root).first === toast, "followed to the screen on top")
        #expect((pushed.navigationItem.rightBarButtonItems ?? []).elementsEqual(pushedOwn, by: ===))
        #expect(!toast.isDismissing)
        toast.dismiss(animated: false)
    }

    /// A screen that sets its own trailing items while a toast is up does
    /// not push the toast out: the toast is placed again, and the screen's
    /// NEW items come back when it leaves (#1375).
    ///
    /// Async like the pop test: the re-placing waits a main-queue turn.
    @Test func aScreensOwnItemsNeverPushALiveToastOut() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = Screen()
        let navigation = UINavigationController(rootViewController: screen)
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        let toast = Feedback.info("Post deleted", from: screen)
        window.layoutIfNeeded()
        #expect(toasts(in: screen).first === toast)

        let fresh = [UIBarButtonItem(systemItem: .add)]
        screen.navigationItem.setRightBarButtonItems(fresh, animated: false)
        window.layoutIfNeeded()
        for _ in 0..<60 where toasts(in: screen).first !== toast {
            try await Task.sleep(for: .milliseconds(5))
            window.layoutIfNeeded()
        }
        #expect(toasts(in: screen).first === toast, "placed again over the screen's write")
        #expect(!toast.isDismissing)

        toast.dismiss(animated: false)
        let back = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(back.elementsEqual(fresh, by: ===), "the screen's new items come back")
    }

    /// No visible bar: the overlay draws it, and the items are untouched.
    @Test func noBarMeansTheOverlay() {
        hosting(barHidden: true) { screen in
            let own = screen.navigationItem.rightBarButtonItems ?? []
            let toast = Feedback.info("Link copied", from: screen)
            #expect(toast.chrome == .capsule)
            #expect((screen.navigationItem.rightBarButtonItems ?? []).elementsEqual(own, by: ===))
        }
    }

    /// `-toast-overlay` (off): the overlay everywhere.
    @Test func offMeansTheOverlay() {
        hosting { screen in
            let previous = NavigationBarToasts.isEnabled
            NavigationBarToasts.isEnabled = false
            defer { NavigationBarToasts.isEnabled = previous }
            let toast = Feedback.info("Link copied", from: screen)
            #expect(toast.chrome == .capsule)
            #expect(toasts(in: screen).isEmpty)
        }
    }
}
