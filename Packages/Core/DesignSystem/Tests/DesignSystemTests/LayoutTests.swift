import Testing
import UIKit
@testable import DesignSystem

@MainActor
struct LayoutTests {
    @Test func pinAddsSubviewAndActivatesFourEdgeConstraints() {
        let parent = UIView()
        let child = UIView()

        child.pin(to: parent, insets: .init(top: 1, leading: 2, bottom: 3, trailing: 4))

        #expect(child.superview === parent)
        #expect(child.translatesAutoresizingMaskIntoConstraints == false)
        #expect(parent.constraints.count == 4)
    }
}
