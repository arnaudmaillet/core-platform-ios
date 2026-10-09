import Testing
import UIKit
@testable import DesignSystem

/// The state-change button (#726): content through a blur, a spring resize,
/// a native press.
@MainActor
struct MorphingButtonTests {
    private static func capsule(_ title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.title = title
        return configuration
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func hosted(_ button: MorphingButton) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        window.addSubview(host)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.layoutIfNeeded()
        return (window, host)
    }

    /// The content changes under a blur, and the capsule takes its new
    /// title's width — one line, always.
    @Test func aMorphBlursTheContentAndResizesToTheNewTitle() async {
        let button = MorphingButton(configuration: Self.capsule("Follow"))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        let narrow = button.bounds.width

        button.morph(to: Self.capsule("Follow Back"), animated: true)
        #expect(button.isMorphing)
        #expect(button.veilEffect != nil, "the content did not go through a blur")
        #expect(button.configuration?.title == "Follow", "the title changed before the blur covered it")

        #expect(await settle { !button.isMorphing }, "the morph never finished")
        host.layoutIfNeeded()
        #expect(button.configuration?.title == "Follow Back")
        #expect(button.veilEffect == nil, "the blur stayed")
        #expect(button.bounds.width > narrow, "the capsule kept the old title's width: \(narrow) → \(button.bounds) intrinsic \(button.intrinsicContentSize)")
        let fitting = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(abs(button.bounds.width - fitting.width) < 1, "the capsule is not its title's width")
        #expect(button.bounds.height < 44, "the title wrapped: \(button.bounds)")
    }

    /// Off screen, or not animated, the change is immediate.
    @Test func anUnanimatedMorphIsImmediate() {
        let button = MorphingButton(configuration: Self.capsule("Follow"))
        button.morph(to: Self.capsule("Following"), animated: true)
        #expect(button.configuration?.title == "Following", "an off-screen button waited for a transition")
        #expect(!button.isMorphing)
    }

    /// A press scales the button down; a release bounces it back.
    @Test func aPressScalesDownAndTheReleaseBouncesBack() async {
        let button = MorphingButton(configuration: Self.capsule("Follow"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.isHighlighted = true
        #expect(abs(button.transform.a - MorphingButton.pressScale) < 0.001, "a press did not scale it down")
        #expect(await settle { button.isLongPressed }, "a held press did not count as a long press")
        #expect(abs(button.transform.a - MorphingButton.longPressScale) < 0.001)
        button.isHighlighted = false
        #expect(button.transform.isIdentity, "the release did not bring it home")
        #expect(!button.isLongPressed)
    }
}
