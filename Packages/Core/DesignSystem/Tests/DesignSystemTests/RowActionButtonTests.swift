import Testing
import UIKit
@testable import DesignSystem

/// The row-action button (#885): UIKit's system button, its press UIKit's
/// own, a change of content cross-faded.
@MainActor
struct RowActionButtonTests {
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func hosted(_ button: UIButton) -> (UIWindow, UIView) {
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

    /// Every animation key in the button's layer tree.
    private func animationKeys(in layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animationKeys(in: $0) }
    }

    /// The touch-down handlers wired to a control: one per press effect.
    private func touchDownHandlers(_ control: UIControl) -> Int {
        var count = 0
        control.enumerateEventHandlers { _, _, event, _ in
            if event.contains(.touchDown) { count += 1 }
        }
        return count
    }

    /// ⚠️ WHY THE SUBCLASS EXISTS. A plain `UIButton` given a new
    /// configuration re-renders its title at once — nothing in its layer tree
    /// animates. If a future UIKit animates this itself, this fails, and
    /// `setConfiguration(_:animated:)` can go.
    @Test func aPlainSystemButtonDoesNotAnimateATitleChange() {
        let button = UIButton(configuration: RowActionButton.configuration(title: "Follow", prominence: .prominent))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        #expect(animationKeys(in: button.layer).isEmpty)

        button.configuration = RowActionButton.configuration(title: "Following", prominence: .secondary)
        host.layoutIfNeeded()
        #expect(animationKeys(in: button.layer).isEmpty, "UIKit animated it: \(animationKeys(in: button.layer))")

        button.configurationUpdateHandler = { button in
            button.configuration = RowActionButton.configuration(title: "Requested", prominence: .secondary)
        }
        button.setNeedsUpdateConfiguration()
        host.layoutIfNeeded()
        #expect(button.configuration?.title == "Requested")
        #expect(animationKeys(in: button.layer).isEmpty, "UIKit animated it: \(animationKeys(in: button.layer))")
    }

    /// Follow → Following cross-fades, and the capsule ends at its new
    /// title's width on one line.
    @Test func aChangeCrossFadesAndSettlesAtTheNewTitlesWidth() async {
        let button = RowActionButton(configuration: RowActionButton.configuration(title: "Follow", prominence: .prominent))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        let narrow = button.bounds.width

        button.setConfiguration(RowActionButton.configuration(title: "Following", prominence: .secondary), animated: true)
        #expect(button.isTransitioning)
        #expect(button.configuration?.title == "Following", "the title waited for the fade")
        #expect(animationKeys(in: button.layer).isEmpty == false, "the change did not animate")

        #expect(await settle { !button.isTransitioning }, "the fade never finished")
        host.layoutIfNeeded()
        #expect(button.bounds.width > narrow, "the capsule kept the old title's width: \(narrow) → \(button.bounds)")
        let fitting = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        #expect(abs(button.bounds.width - fitting.width) < 1, "the capsule is not its title's width")
        #expect(button.bounds.height < 44, "the title wrapped: \(button.bounds)")
    }

    /// Off screen, unanimated, or the same configuration again: nothing to
    /// fade.
    @Test func anUnanimatedOrOffScreenOrSameChangeIsImmediate() {
        let offScreen = RowActionButton(configuration: RowActionButton.configuration(title: "Follow", prominence: .prominent))
        offScreen.setConfiguration(RowActionButton.configuration(title: "Following", prominence: .secondary), animated: true)
        #expect(offScreen.configuration?.title == "Following", "an off-screen button waited for a transition")
        #expect(!offScreen.isTransitioning)

        let button = RowActionButton(configuration: RowActionButton.configuration(title: "Follow", prominence: .prominent))
        let (window, _) = hosted(button)
        defer { window.isHidden = true }
        button.setConfiguration(RowActionButton.configuration(title: "Follow", prominence: .prominent), animated: true)
        #expect(!button.isTransitioning, "the same configuration faded")
        button.setConfiguration(RowActionButton.configuration(title: "Requested", prominence: .secondary), animated: false)
        #expect(!button.isTransitioning)
        #expect(button.configuration?.title == "Requested")
    }

    /// The two looks are UIKit's system styles: a filled capsule that
    /// invites, a grey one that states a fact.
    @Test func theLooksAreSystemCapsules() {
        func system(_ base: UIButton.Configuration, _ title: String) -> UIButton.Configuration {
            var configuration = base
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: UIFont.appFont(forTextStyle: .subheadline)
            ]))
            return configuration
        }
        #expect(RowActionButton.configuration(title: "Accept", prominence: .prominent) == system(.filled(), "Accept"))
        #expect(RowActionButton.configuration(title: "Following", prominence: .secondary) == system(.gray(), "Following"))
        #expect(RowActionButton.configuration(title: "Follow", prominence: .prominent)
            != RowActionButton.configuration(title: "Follow", prominence: .secondary))
    }

    /// ⚠️ THE PRESS IS UIKIT'S (#885). No `PressFeedback`, nothing on
    /// touch-down, nothing scaled however long the finger stays: the
    /// highlight the configuration resolves is the whole press — one state,
    /// never a second step.
    @Test func thePressIsUIKitsOwnHighlightAndNothingElse() {
        let button = RowActionButton(configuration: RowActionButton.configuration(title: "Follow", prominence: .prominent))
        let (window, host) = hosted(button)
        defer { window.isHidden = true }
        #expect(PressFeedback.attached(to: button) == nil, "a custom press is attached")
        #expect(touchDownHandlers(button) == 0, "something is wired to touch-down")

        button.isHighlighted = true
        button.sendActions(for: .touchDown)
        host.layoutIfNeeded()
        #expect(button.transform.isIdentity, "the press scaled the button")
        #expect(button.layer.animation(forKey: "transform") == nil)
        // Held, the finger wandering inside: still one state.
        button.isHighlighted = false
        button.isHighlighted = true
        button.sendActions(for: .touchDragEnter)
        #expect(button.transform.isIdentity, "a held press took a second step")
        #expect(button.state.contains(.highlighted))

        button.isHighlighted = false
        button.sendActions(for: .touchUpInside)
        #expect(button.transform.isIdentity)
        #expect(!button.state.contains(.highlighted))
    }
}
