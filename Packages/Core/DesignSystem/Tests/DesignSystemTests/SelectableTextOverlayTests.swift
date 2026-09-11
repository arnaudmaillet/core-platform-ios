import Testing
import UIKit
@testable import DesignSystem

/// Select Text over a label: the overlay carries the label's text and look,
/// the label steps aside by alpha, and `end()` puts everything back.
@MainActor
@Suite("Selectable text overlay")
struct SelectableTextOverlayTests {
    private func makeLabel() -> (UILabel, UIView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let label = UILabel()
        label.text = "Weekend build log"
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
        ])
        return (label, host)
    }

    @Test("Beginning lays the label's text over it and fades the label by alpha")
    func beginOverlaysTheLabel() {
        let (label, host) = makeLabel()
        let overlay = SelectableTextOverlay(label: label, host: host)
        overlay.begin()
        #expect(overlay.isActive)
        #expect(overlay.overlayTextView.text == "Weekend build log")
        #expect(overlay.overlayTextView.font == label.font)
        #expect(overlay.overlayTextView.isHidden == false)
        #expect(label.alpha == 0)
        #expect(label.isHidden == false, "hiding would collapse the row it sits in")
    }

    @Test("Ending restores the label and hides the overlay")
    func endRestoresTheLabel() {
        let (label, host) = makeLabel()
        let overlay = SelectableTextOverlay(label: label, host: host)
        overlay.begin()
        overlay.end()
        #expect(!overlay.isActive)
        #expect(overlay.overlayTextView.isHidden)
        #expect(label.alpha == 1)
    }

    @Test("A tap on the overlay counts as inside it, anything else does not")
    func containment() {
        let (label, host) = makeLabel()
        let overlay = SelectableTextOverlay(label: label, host: host)
        #expect(!overlay.contains(host), "nothing is inside an overlay that is not up")
        overlay.begin()
        #expect(overlay.contains(overlay.overlayTextView))
        #expect(!overlay.contains(host))
    }
}
