import Testing
import UIKit
@testable import DesignSystem

/// Taps in a bar's area reach nothing behind it, on every screen, with nothing
/// for the screen to remember (#562, #1145): the guard's decisions and the
/// audit, over a real screen — a tab bar, a navigation stack, a scrolling
/// list, and a floating pill row of the screen's own.
@MainActor
struct BarTapShieldTests {
    /// A floating row the way screens build them: no ground of its own, only
    /// its pill takes a touch — a tap beside the pill falls to the list.
    final class PillRow: UIView {
        let pill = UIButton(type: .system)

        override init(frame: CGRect) {
            super.init(frame: frame)
            pill.setTitle("Filter", for: .normal)
            addSubview(pill)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            pill.frame = CGRect(x: bounds.midX - 50, y: 8, width: 100, height: bounds.height - 16)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    final class Screen: UIViewController {
        let list = UIScrollView()
        let row = PillRow()

        override func viewDidLoad() {
            super.viewDidLoad()
            list.contentSize = CGSize(width: 10, height: 4_000)
            view.addSubview(list)
            view.addSubview(row)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            list.frame = view.bounds
            row.frame = CGRect(x: 0, y: view.bounds.height - 260, width: view.bounds.width, height: 56)
        }
    }

    /// A visible window over the screen, taken down after each test (a
    /// visible window freed by a suite crashes the host).
    @MainActor
    final class Rig {
        let window = AppWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = Screen()
        let tabs = UITabBarController()

        init() {
            let navigation = UINavigationController(rootViewController: screen)
            screen.title = "Screen"
            tabs.viewControllers = [navigation]
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
            screen.view.layoutIfNeeded()
        }

        /// The row's centre line, `x` points in, in window coordinates.
        func onRow(x: CGFloat) -> CGPoint {
            let frame = screen.row.convert(screen.row.bounds, to: window)
            return CGPoint(x: x, y: frame.midY)
        }

        func takeDown() {
            window.rootViewController = nil
            window.isHidden = true
        }
    }

    private func hosting(_ body: (Rig) throws -> Void) rethrows {
        let rig = Rig()
        defer { rig.takeDown() }
        try body(rig)
    }

    // MARK: - A screen's own floating bar

    @Test func aDeclaredBarSwallowsATapBesideItsControls() throws {
        try hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            let beside = rig.onRow(x: 60)
            let hit = try #require(rig.window.hitTest(beside, with: nil))
            #expect(hit.isDescendant(of: rig.screen.list), "guard: beside the pill, the list is what a tap reaches")
            #expect(BarTouchGuard.bar(replacing: hit, at: beside, in: rig.window) === rig.screen.row)
        }
    }

    @Test func aDeclaredBarsControlsTakeTheirTaps() throws {
        try hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            let onPill = rig.onRow(x: rig.window.bounds.midX)
            let hit = try #require(rig.window.hitTest(onPill, with: nil))
            #expect(hit.isDescendant(of: rig.screen.row.pill), "guard: the pill is hit")
            #expect(BarTouchGuard.bar(replacing: hit, at: onPill, in: rig.window) == nil, "the pill is never shielded")
        }
    }

    /// A band laid behind controls the screen placed itself (the camera's
    /// shutter row): the controls it names take their taps, the gaps do not.
    @Test func aBandsNamedItemsTakeTheirTaps() throws {
        try hosting { rig in
            let band = rig.screen.row
            let button = UIButton(type: .system)
            let frame = band.convert(band.bounds, to: rig.screen.view)
            button.frame = CGRect(x: 20, y: frame.minY + 8, width: 60, height: frame.height - 16)
            rig.screen.view.addSubview(button)
            BarTouchGuard.declareBar(band, items: [button])

            let onButton = rig.onRow(x: 50)
            let hit = try #require(rig.window.hitTest(onButton, with: nil))
            #expect(hit.isDescendant(of: button), "guard: the button is hit")
            #expect(BarTouchGuard.bar(replacing: hit, at: onButton, in: rig.window) == nil, "a named item is never shielded")

            let gap = rig.onRow(x: 110)
            let gapHit = try #require(rig.window.hitTest(gap, with: nil))
            #expect(BarTouchGuard.bar(replacing: gapHit, at: gap, in: rig.window) === band, "the gap beside it is")
        }
    }

    /// What declaring is for: the same row, undeclared, leaks.
    @Test func anUndeclaredFloatingRowLeaks() throws {
        try hosting { rig in
            let beside = rig.onRow(x: 60)
            let hit = try #require(rig.window.hitTest(beside, with: nil))
            #expect(BarTouchGuard.bar(replacing: hit, at: beside, in: rig.window) == nil)
        }
    }

    /// The left strip is no longer left alone: a tap there is a tap.
    @Test func theLeftEdgeIsGuardedToo() throws {
        try hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            let edge = rig.onRow(x: 8)
            let hit = try #require(rig.window.hitTest(edge, with: nil))
            #expect(BarTouchGuard.bar(replacing: hit, at: edge, in: rig.window) === rig.screen.row)
        }
    }

    /// A view over the bar that is not its screen's content — a sheet, an
    /// overlay — is not under the bar.
    @Test func whatCoversTheBarIsNotItsContent() throws {
        try hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            let cover = UIView(frame: rig.window.bounds)
            rig.window.addSubview(cover)
            defer { cover.removeFromSuperview() }
            let point = rig.onRow(x: 60)
            let hit = try #require(rig.window.hitTest(point, with: nil))
            #expect(hit === cover, "guard: the cover takes the touch")
            #expect(BarTouchGuard.bar(replacing: hit, at: point, in: rig.window) == nil)
        }
    }

    @Test func aHiddenDeclaredBarGuardsNothing() throws {
        try hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            rig.screen.row.isHidden = true
            let point = rig.onRow(x: 60)
            let hit = try #require(rig.window.hitTest(point, with: nil))
            #expect(BarTouchGuard.bar(replacing: hit, at: point, in: rig.window) == nil, "no dead zone where it was")
        }
    }

    // MARK: - The audit

    /// Every bar on the screen, the declared one and the left edge included:
    /// taps reach the content without the shield (raw), none with it.
    @Test func theAuditFindsNoLeak() {
        hosting { rig in
            BarTouchGuard.declareBar(rig.screen.row)
            let measurements = BarTouchAudit.measure(in: rig.window)
            let declared = measurements.first { $0.name.hasPrefix("declared") }
            #expect(declared != nil, "the audit probes the declared bar: \(measurements)")
            #expect((declared?.raw ?? 0) > 0, "guard: its probes reach the list without the shield")
            for measurement in measurements {
                #expect(measurement.guarded == 0, "\(measurement)")
            }
        }
    }

    /// The audit is what would catch a leak: an undeclared row is not probed,
    /// a declared one is counted with its leak closed.
    @Test func theAuditProbesOnlyDeclaredBars() {
        hosting { rig in
            #expect(!BarTouchAudit.measure(in: rig.window).contains { $0.name.hasPrefix("declared") })
        }
    }

    // MARK: - The window

    @Test func everyAppWindowCarriesTheShield() {
        #expect(AppWindow(frame: .zero).carriesBarTapShield)
    }

    // MARK: - The recogniser's decision

    @Test func aStillFingerIsATapAndAMovingOneAPan() {
        #expect(BarTapShield.outcome(moved: 2, after: 0.1, lifted: true) == .swallowed)
        #expect(BarTapShield.outcome(moved: 2, after: BarTapShield.longPressDelay, lifted: false) == .swallowed)
        #expect(BarTapShield.outcome(moved: BarTapShield.slop + 1, after: 0.05, lifted: false) == .passed)
        #expect(BarTapShield.outcome(moved: 2, after: 0.1, lifted: false) == .undecided)
    }
}
