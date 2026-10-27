import Testing
import UIKit
@testable import DesignSystem

/// A row action under way wears the kit's loader at its trailing edge (#1775),
/// after the grace, and only while it is on screen.
@MainActor
struct RowBusyAccessoryTests {
    @Test func theLoaderWaitsItsGraceOnScreen() async {
        let view = RowBusyView()
        #expect(view.intrinsicContentSize.width > 0)
        let loader = view.subviews.compactMap { $0 as? AppLoaderView }.first
        #expect(loader?.isAnimating == false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        window.addSubview(view)
        #expect(loader?.isAnimating == false, "a loader before the grace")
        for _ in 0..<100 where loader?.isAnimating != true { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(loader?.isAnimating == true)
        view.removeFromSuperview()
        #expect(loader?.isAnimating == false, "a loader off screen still turns")
        window.isHidden = true
    }
}
