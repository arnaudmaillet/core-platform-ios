import DesignSystem
import Testing
import UIKit
@testable import CoreNavigation

/// What covers the screens of a window (#1970): a cover above a host's level
/// takes its share to 0, and the share its other sources give comes back
/// when the cover ends. (A package test host never completes a modal, so
/// presentations are read through the default table and the chain's levels;
/// covers are driven here by tokens. The UI test drives a real sheet.)
@MainActor
struct ScreenCoversTests {
    /// A window whose root screen holds a clip host, and the host's share.
    private func hostedShare() -> (UIWindow, ViewportShare, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let host = UIView(frame: root.view.bounds)
        root.view.addSubview(host)
        return (window, ViewportShare(host: host), host)
    }

    /// A cover takes the share to 0; its end gives back what the sources
    /// say — a share they moved meanwhile included.
    @Test func aCoverSetsTheShareToZeroAndItsEndRestoresTheSources() {
        let (window, share, host) = hostedShare()
        defer { window.isHidden = true }
        var plays: [Bool] = []
        share.onPlaysChange = { plays.append($0) }

        let token = ScreenCovers.of(window).begin(covers: true)
        #expect(share.isCovered)
        #expect(share.share == 0)
        share.report(0.7)
        #expect(share.share == 0, "a source moved the share of a covered host")
        token.end()
        #expect(!share.isCovered)
        #expect(abs(share.share - 0.7) < 0.001, "the sources' share did not come back")
        #expect(plays == [false, true])
        _ = host
    }

    /// Two covers: the share comes back only when both have ended.
    @Test func twoCoversBothHaveToEnd() {
        let (window, share, host) = hostedShare()
        defer { window.isHidden = true }
        let registry = ScreenCovers.of(window)
        let first = registry.begin(covers: true)
        let second = registry.begin(covers: true)
        first.end()
        #expect(share.isCovered, "one cover ended and the other was forgotten")
        second.covers = false
        #expect(!share.isCovered)
        second.covers = true
        #expect(share.isCovered, "a token covering again was not heard")
        second.end()
        #expect(!share.isCovered)
        _ = host
    }

    /// A token that goes away without ending ends with it.
    @Test func aReleasedTokenEnds() async {
        let (window, share, host) = hostedShare()
        defer { window.isHidden = true }
        var token: ScreenCovers.Token? = ScreenCovers.of(window).begin(covers: true)
        #expect(share.isCovered)
        token = nil
        for _ in 0..<50 where share.isCovered {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!share.isCovered, "a released token kept covering")
        _ = (token, host)
    }

    /// A host out of the window is never held covered: it fails open.
    @Test func aHostOutOfTheWindowIsNeverHeldCovered() {
        let (window, share, host) = hostedShare()
        defer { window.isHidden = true }
        let token = ScreenCovers.of(window).begin(covers: true)
        #expect(share.isCovered)
        host.removeFromSuperview()
        token.covers = true
        ScreenCovers.of(window).refresh()
        #expect(!share.isCovered)
    }

    /// A screen's level is the deepest screen of the chain holding it: the
    /// sound sheet's gallery sits at the sheet's level, so the sheet never
    /// covers it.
    @Test func aHostsLevelIsTheDeepestScreenHoldingIt() {
        let root = UIViewController()
        let sheet = UIViewController()
        let inRoot = UIView()
        let inSheet = UIView()
        root.view.addSubview(inRoot)
        sheet.view.addSubview(inSheet)
        let chain = [root, sheet]
        #expect(ScreenCovers.level(of: inRoot, in: chain) == 0)
        #expect(ScreenCovers.level(of: inSheet, in: chain) == 1)
        #expect(ScreenCovers.level(of: UIView(), in: chain) == 0, "a stray view")
    }

    // MARK: - The default table

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

    private func presented(_ style: UIModalPresentationStyle) -> UIViewController {
        let screen = UIViewController()
        screen.modalPresentationStyle = style
        return screen
    }

    @Test func fullScreenCovers() {
        #expect(ScreenCovers.covers(presented(.fullScreen), in: bounds))
        #expect(ScreenCovers.covers(presented(.overFullScreen), in: bounds))
    }

    @Test func aSheetCoversOnlyAtLarge() throws {
        let large = presented(.pageSheet)
        try #require(large.sheetPresentationController).detents = [.large()]
        #expect(ScreenCovers.covers(large, in: bounds))

        let medium = presented(.pageSheet)
        try #require(medium.sheetPresentationController).detents = [.medium()]
        #expect(!ScreenCovers.covers(medium, in: bounds))

        let fitted = presented(.pageSheet)
        try #require(fitted.sheetPresentationController).detents = [
            .custom(identifier: .init("fitted")) { _ in 300 }
        ]
        #expect(!ScreenCovers.covers(fitted, in: bounds))

        // Two heights, the smaller selected: it covers once at large.
        #expect(!ScreenCovers.coversAsSheet(selected: .medium, detents: [.medium, .large]))
        #expect(ScreenCovers.coversAsSheet(selected: .large, detents: [.medium, .large]))
        #expect(!ScreenCovers.coversAsSheet(selected: nil, detents: [.medium, .large]), "UIKit shows the first")
        #expect(ScreenCovers.coversAsSheet(selected: nil, detents: []), "a sheet with no detents is large")
    }

    @Test func popoversAndAlertsDoNotCover() {
        #expect(!ScreenCovers.covers(presented(.popover), in: bounds))
        let alert = UIAlertController(title: "t", message: nil, preferredStyle: .alert)
        #expect(!ScreenCovers.covers(alert, in: bounds))
        let sheet = UIAlertController(title: "t", message: nil, preferredStyle: .actionSheet)
        #expect(!ScreenCovers.covers(sheet, in: bounds))
    }

    /// A declaration wins over the table — on the screen itself, or on the
    /// root of the stack presented.
    @Test func aDeclarationWins() {
        let declared = Declared()
        declared.modalPresentationStyle = .fullScreen
        declared.covers = false
        #expect(!ScreenCovers.covers(declared, in: bounds))
        declared.covers = true
        let stack = UINavigationController(rootViewController: declared)
        stack.modalPresentationStyle = .pageSheet
        stack.sheetPresentationController?.detents = [.medium()]
        #expect(ScreenCovers.covers(stack, in: bounds), "the stack's root declared it covers")
    }
}

@MainActor
private final class Declared: UIViewController, ScreenCovering {
    var covers = true
    var coversScreen: Bool { covers }
}
