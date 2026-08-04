import Testing
import UIKit
@testable import DesignSystem

@MainActor
struct EmptyStateViewTests {
    /// Everything the view draws, by kind, in stack order — the only way to
    /// assert what is actually on screen without a snapshot.
    private func visibleContent(of view: EmptyStateView) -> (labels: [String], hasIcon: Bool, buttons: [String]) {
        var labels: [String] = []
        var buttons: [String] = []
        var hasIcon = false
        func walk(_ v: UIView) {
            guard !v.isHidden else { return }
            if let button = v as? UIButton {
                buttons.append(button.configuration?.title ?? "")
                return
            }
            if let label = v as? UILabel, let text = label.text, !text.isEmpty { labels.append(text) }
            if let image = v as? UIImageView, image.image != nil { hasIcon = true }
            v.subviews.forEach(walk)
        }
        walk(view)
        return (labels, hasIcon, buttons)
    }

    private func laidOut(_ configure: (EmptyStateView) -> Void) -> EmptyStateView {
        let view = EmptyStateView()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        configure(view)
        view.layoutIfNeeded()
        return view
    }

    @Test func aTitleAloneDrawsOnlyATitle() {
        let view = laidOut { $0.configure(title: "No activity yet") }
        let content = visibleContent(of: view)
        #expect(content.labels == ["No activity yet"])
        #expect(content.hasIcon == false)
        #expect(content.buttons.isEmpty)
    }

    @Test func absentPartsAreHiddenRatherThanBlank() {
        // A hidden view still occupies its stack slot if it is only emptied, so
        // the difference between "no subtitle" and "an empty subtitle" is a
        // stray gap in the middle of the block.
        let view = laidOut { $0.configure(title: "Nothing here", subtitle: "") }
        #expect(visibleContent(of: view).labels == ["Nothing here"])
    }

    @Test func aSubtitleAndIconAppearWhenGiven() {
        let view = laidOut {
            $0.configure(symbolName: "tray", title: "No media yet.", subtitle: "Showing Work only.")
        }
        let content = visibleContent(of: view)
        #expect(content.labels == ["No media yet.", "Showing Work only."])
        #expect(content.hasIcon)
    }

    @Test func anActionNeedsBothATitleAndAHandler() {
        // A title with no handler is an offer the view cannot keep, so it is
        // not drawn at all rather than drawn inert.
        let titleOnly = laidOut { $0.configure(title: "Failed", actionTitle: "Try Again") }
        #expect(visibleContent(of: titleOnly).buttons.isEmpty)

        let handlerOnly = laidOut { $0.configure(title: "Failed", actionHandler: {}) }
        #expect(visibleContent(of: handlerOnly).buttons.isEmpty)

        let both = laidOut {
            $0.configure(title: "Failed", actionTitle: "Try Again", actionHandler: {})
        }
        #expect(visibleContent(of: both).buttons == ["Try Again"])
    }

    @Test func theActionCallsBack() {
        var fired = 0
        let view = laidOut {
            $0.configure(title: "Failed", actionTitle: "Try Again", actionHandler: { fired += 1 })
        }
        let button = view.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }.first
        button?.sendActions(for: .primaryActionTriggered)
        #expect(fired == 1)
    }

    @Test func reconfiguringReplacesTheWholeMessage() {
        // The failure this guards: a title from one condition left standing
        // beside a subtitle from another.
        let view = laidOut {
            $0.configure(symbolName: "tray", title: "First", subtitle: "Because of a filter")
        }
        view.configure(title: "Second")
        view.layoutIfNeeded()
        let content = visibleContent(of: view)
        #expect(content.labels == ["Second"])
        #expect(content.hasIcon == false)
    }

    @Test func theContentIsCentredInItsParent() {
        let view = laidOut {
            $0.configure(symbolName: "tray", title: "No activity yet", subtitle: "A reason")
        }
        let stack = view.subviews.compactMap { $0 as? UIStackView }.first
        let frame = try! #require(stack?.frame)
        #expect(abs(frame.midX - view.bounds.midX) < 0.5)
        #expect(abs(frame.midY - view.bounds.midY) < 0.5)
    }

    @Test func longTextWrapsInsteadOfRunningEdgeToEdge() {
        let view = laidOut {
            $0.configure(
                title: "No trending media yet.",
                subtitle: String(repeating: "A very long explanation. ", count: 6)
            )
        }
        let stack = view.subviews.compactMap { $0 as? UIStackView }.first
        let frame = try! #require(stack?.frame)
        // Bounded by the readable width, and never wider than the view itself.
        #expect(frame.width <= view.bounds.width)
        #expect(frame.width <= 320.5)
    }

    @Test func voiceOverReadsTheWholeMessageAsOneStatement() {
        let view = laidOut { $0.configure(title: "No activity yet", subtitle: "Showing Work only.") }
        #expect(view.accessibilityLabel == "No activity yet. Showing Work only.")
    }
}
