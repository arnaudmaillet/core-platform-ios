import DesignSystem
import Testing
import UIKit
@testable import HeroPage

/// A profile's and a place's ground (#2243; the only style since #2290): both
/// pages are vertical post lists, and their banner melts into the same tone
/// the page lies on (`HeroPageViewController.viewDidLoad`, the banner's veil
/// and ramp all read `HeroPageGround`).
@MainActor
struct HeroPageGroundTests {
    /// The plain page, in every build — white in the light, black in the dark.
    @Test func theGroundIsThePlainPage() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        #expect(HeroPageGround.color == Surface.plainPage)
        #expect(HeroPageGround.color.resolvedColor(with: light) == UIColor.systemBackground.resolvedColor(with: light))
    }
}
