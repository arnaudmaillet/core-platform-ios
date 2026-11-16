import Testing
import UIKit
@testable import MediaCore

/// The launch screen faded out over the shell (#1812); it lifts as soon as
/// the shell is in since the app opens on the map (#2453).
@MainActor
@Suite(.serialized)
struct LaunchCurtainTests {
    private func shell() -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, root)
    }

    private func settle(looks: Int = 200, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The curtain covers the window's whole bounds over the shell, which is
    /// never hidden under it, fades out at once, and leaves the window once
    /// faded.
    @Test func theCurtainFadesOutOverTheShellAndLeaves() async {
        let (window, root) = shell()
        defer { window.isHidden = true }
        let curtain = UIView()

        LaunchCurtain.lift(curtain, over: window, owner: NSObject())

        #expect(curtain.superview === window)
        #expect(curtain.frame == window.bounds)
        #expect(!root.view.isHidden && root.view.alpha == 1, "the shell was hidden under the curtain")
        #expect(curtain.alpha == 0, "the fade did not start at once")
        #expect(await settle { curtain.superview == nil }, "the curtain stayed in the window after its fade")
    }

    /// What drives the curtain's loader lives until the fade is over.
    @Test func theOwnerLivesUntilTheFadeIsOver() async {
        let (window, _) = shell()
        defer { window.isHidden = true }
        let curtain = UIView()
        weak var weakOwner: NSObject?
        do {
            let owner = NSObject()
            weakOwner = owner
            LaunchCurtain.lift(curtain, over: window, owner: owner)
        }

        #expect(weakOwner != nil, "the owner went before the fade")
        #expect(await settle { curtain.superview == nil })
        #expect(await settle { weakOwner == nil }, "the owner outlived the fade")
    }
}
