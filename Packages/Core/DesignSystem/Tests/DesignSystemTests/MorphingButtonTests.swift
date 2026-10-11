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

    /// The handlers registered for touch-down: one per press effect wired to
    /// the button.
    private func touchDownHandlers(_ control: UIControl) -> Int {
        var count = 0
        control.enumerateEventHandlers { _, _, event, _ in
            if event.contains(.touchDown) { count += 1 }
        }
        return count
    }

    /// ⚠️ ONE PRESS, THE APP'S (#866). A long press used to shrink in two
    /// steps — 0.94 on touch-down, then 0.88 once a timer saw it held — because
    /// the button scaled ITS OWN `transform` from `isHighlighted`. Its press is
    /// `PressFeedback` now: one give, decided once, held for as long as the
    /// finger stays, and nothing written to the model however the highlight
    /// toggles.
    @Test func aPressIsOneSharedPressThatNeverTakesASecondStep() throws {
        let button = MorphingButton(configuration: Self.capsule("Follow"))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        let press = try #require(PressFeedback.attached(to: button), "the button has no shared press")
        #expect(press.debugTarget === button, "the press moves something else")
        #expect(touchDownHandlers(button) == 1, "more than one press is wired to touch-down")

        let expected = MotionPreference.reducesMotion ? 1 : PressFeedback.pressedScale(for: button.bounds.size)
        // What UIKit does at touch-down: the highlight, then the event.
        button.isHighlighted = true
        button.sendActions(for: .touchDown)
        #expect(press.isPressed)
        #expect(press.scale == expected, "the press is not the shared depth: \(press.scale)")
        #expect(button.transform.isIdentity, "the button scaled itself under the press")

        // A finger held long, wandering inside: the highlight flickers, the
        // press does not take a second step.
        button.isHighlighted = false
        button.isHighlighted = true
        button.sendActions(for: .touchDragEnter)
        #expect(button.transform.isIdentity, "a held press wrote a second scale")
        let presses = press.debugEvents.filter { if case .pressed = $0 { true } else { false } }
        #expect(presses.count == 1, "the press was decided more than once: \(press.debugEvents)")

        button.isHighlighted = false
        button.sendActions(for: .touchUpInside)
        #expect(!press.isPressed && press.scale == 1, "the release did not bring it home")
        #expect(button.transform.isIdentity)
    }
}
