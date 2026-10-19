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
            let spinner = try #require(Self.views(of: AppLoaderView.self, in: toast).first)
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

    /// ⚠️ A screen that EDITS the bar's list while a toast is up (#1420) —
    /// builds its new list from `rightBarButtonItems`, which holds the
    /// toast's item — keeps that item in. Once the toast goes, nothing of it
    /// is left in the bar: the screen's edit comes back, the toast's item
    /// dropped.
    @Test func aScreenThatEditsTheBarsListNeverLeavesAToastBehind() throws {
        try hosting { screen in
            let toast = Feedback.info("Notifications muted", from: screen)
            let bell = UIBarButtonItem(systemItem: .add)
            let edited = [bell] + (screen.navigationItem.rightBarButtonItems ?? [])
            #expect(edited.contains(where: NavigationBarToasts.isToastItem), "guard: the edit kept the toast's item")
            screen.navigationItem.setRightBarButtonItems(edited, animated: false)

            toast.dismiss(animated: false)
            let back = screen.navigationItem.rightBarButtonItems ?? []
            #expect(!back.contains(where: NavigationBarToasts.isToastItem), "a dead toast stayed in the bar")
            #expect(back.elementsEqual([bell], by: ===), "the screen's edit did not come back")
        }
    }

    /// Through its OWN items (#1420), a screen edits what comes back and
    /// leaves the bar to the toasts: never a mixed trailing group, so never
    /// one too wide for the bar.
    @Test func aScreenEditingItsOwnItemsLeavesTheBarToTheToasts() throws {
        try hosting { screen in
            let own = screen.navigationItem.rightBarButtonItems ?? []
            let toast = Feedback.info("Notifications muted", from: screen)
            #expect(screen.ownTrailingBarItems.elementsEqual(own, by: ===), "the toasts hid the screen's own items")

            let bell = UIBarButtonItem(systemItem: .add)
            screen.setOwnTrailingBarItems([bell] + screen.ownTrailingBarItems, animated: false)
            let shown = screen.navigationItem.rightBarButtonItems ?? []
            #expect(shown.count == 1 && shown.allSatisfy(NavigationBarToasts.isToastItem),
                    "the screen's items joined the toast in the bar")

            toast.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.elementsEqual([bell] + own, by: ===), "the screen's new items did not come back")
        }
    }

    /// No toast up: the screen's own items are the bar's, set straight.
    @Test func withNoToastTheOwnItemsAreTheBars() {
        hosting { screen in
            let bell = UIBarButtonItem(systemItem: .add)
            screen.setOwnTrailingBarItems([bell], animated: false)
            #expect((screen.navigationItem.rightBarButtonItems ?? []).elementsEqual([bell], by: ===))
            #expect(screen.ownTrailingBarItems.elementsEqual([bell], by: ===))
        }
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

    // MARK: - A confirmed control (#1447)

    /// Records every list the bar was handed.
    private final class RecordingItem: UINavigationItem {
        var handed: [[UIBarButtonItem]] = []
        override var rightBarButtonItems: [UIBarButtonItem]? {
            get { super.rightBarButtonItems }
            set {
                handed.append(newValue ?? [])
                super.rightBarButtonItems = newValue
            }
        }
        override func setRightBarButtonItems(_ items: [UIBarButtonItem]?, animated: Bool) {
            handed.append(items ?? [])
            super.setRightBarButtonItems(items, animated: animated)
        }
    }

    private final class RecordingScreen: UIViewController {
        let recording = RecordingItem(title: "")
        override var navigationItem: UINavigationItem { recording }
    }

    private func hostingRecording(_ body: (RecordingScreen) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = RecordingScreen()
        let navigation = UINavigationController(rootViewController: screen)
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

    /// The bar goes from the old look straight to the toast, and the new
    /// look comes back when it leaves: never handed before (bell → toast →
    /// bell.slash).
    @Test func aConfirmedControlsNewLookComesBackWithTheToastsLeaving() throws {
        try hostingRecording { screen in
            let bell = UIBarButtonItem(image: UIImage(systemName: "bell"))
            screen.setOwnTrailingBarItems([bell], animated: false)
            let mutedBell = UIBarButtonItem(image: UIImage(systemName: "bell.slash"))
            screen.recording.handed = []
            var revealed = false
            let toast = Feedback.success("Notifications muted", from: screen, revealing: {
                revealed = true
                screen.setOwnTrailingBarItems([mutedBell], animated: true)
            })
            #expect(revealed)
            #expect(screen.recording.handed.count == 1, "the bar was handed more than the toast: \(screen.recording.handed)")
            #expect(screen.recording.handed.allSatisfy { $0.allSatisfy(NavigationBarToasts.isToastItem) },
                    "the new look reached the bar before the toast")
            #expect(screen.ownTrailingBarItems.elementsEqual([mutedBell], by: ===))

            toast.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.elementsEqual([mutedBell], by: ===), "the new look did not come back")
        }
    }

    /// A screen that sets its bar itself in the reveal: what it set is what
    /// comes back.
    @Test func aRevealSetOnTheBarItselfComesBack() throws {
        try hostingRecording { screen in
            screen.navigationItem.rightBarButtonItems = [UIBarButtonItem(systemItem: .add)]
            let mutedBell = UIBarButtonItem(image: UIImage(systemName: "bell.slash"))
            let toast = Feedback.success("Notifications muted", from: screen, revealing: {
                screen.navigationItem.setRightBarButtonItems([mutedBell], animated: true)
            })
            #expect(toasts(in: screen) == [toast])
            toast.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.elementsEqual([mutedBell], by: ===))
        }
    }

    /// A toast already up: the reveal under the next one still waits for the
    /// last to leave.
    @Test func aRevealUnderToastsAlreadyUpWaitsForTheLast() throws {
        try hostingRecording { screen in
            let bell = UIBarButtonItem(image: UIImage(systemName: "bell"))
            screen.setOwnTrailingBarItems([bell], animated: false)
            let first = Feedback.info("Link copied", from: screen)
            let mutedBell = UIBarButtonItem(image: UIImage(systemName: "bell.slash"))
            screen.recording.handed = []
            let undo = Feedback.undoable(
                "Notifications muted", from: screen,
                revealing: { screen.setOwnTrailingBarItems([mutedBell], animated: true) },
                commit: {}, undo: {}
            )
            #expect(screen.recording.handed.allSatisfy { $0.allSatisfy(NavigationBarToasts.isToastItem) })
            first.dismiss(animated: false)
            #expect(!(screen.navigationItem.rightBarButtonItems ?? []).contains { $0 === mutedBell })
            undo.dismiss(animated: false)
            let back = try #require(screen.navigationItem.rightBarButtonItems)
            #expect(back.elementsEqual([mutedBell], by: ===))
        }
    }

    /// No bar: the control changes as its toast appears, not before.
    @Test func overTheContentTheRevealComesWithTheToast() {
        hosting(barHidden: true) { screen in
            var revealedBeforeReturn = false
            let toast = Feedback.success("Notifications muted", from: screen, revealing: {
                revealedBeforeReturn = true
            })
            #expect(toast.chrome == .capsule)
            #expect(revealedBeforeReturn)
        }
    }
}
