import DesignSystem
import Testing
import UIKit
@testable import HeroPage

/// A profile's and a place's ground follow the post lists' style (#2243):
/// both pages are vertical post lists, and their banner melts into the same
/// tone the page lies on (`HeroPageViewController.viewDidLoad`, the banner's
/// veil and ramp all read `HeroPageGround`).
@MainActor
struct HeroPageGroundTests {
    /// The ground is the launch's list style's — today's grey page by
    /// default, the plain white one under flat rows.
    @Test func theGroundIsTheListStylesPage() {
        #expect(HeroPageGround.color == PostListStyle.current.pageGround)
    }
}
