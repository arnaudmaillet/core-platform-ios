import Testing
import UIKit
@testable import DesignSystem

/// A cut toast's whole message (#1449): a tap on a toast whose one line is
/// cut opens it in a bottom sheet; a toast that fits behaves as before. Cut
/// is measured at the label's width now, the toast waits while the sheet is
/// up, and acting from the sheet runs the toast's action.
@MainActor
@Suite(.serialized)
struct ToastFullMessageTests {
    private static let long = "Couldn't ask to follow @ava.moreau because the server said no"

    /// A window with a screen, on a manual clock. The sheet's presentation
    /// is caught by each test (a test host's modals never complete).
    private func hosting(_ body: (UIView) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
        }
        try body(window.rootViewController!.view)
    }

    private func barToast(_ message: String, action: ToastView.Action? = nil, width: CGFloat, in container: UIView) -> ToastView {
        let toast = ToastView.makeForBar(ToastView.Content(
            message: message, symbol: "exclamationmark.circle.fill", style: .warning, action: action,
            undoable: nil, id: nil
        ))
        container.addSubview(toast)
        toast.sizeInBar(width: width)
        toast.layoutIfNeeded()
        toast.startInBar()
        return toast
    }

    // MARK: - Cut, measured

    /// The same words: whole in a wide slot, cut in a narrow one.
    @Test func cutIsMeasuredAtTheLabelsWidth() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 100))
        let wide = barToast("Couldn't follow @ava", width: 360, in: container)
        let narrow = barToast("Couldn't follow @ava", width: 110, in: container)
        #expect(!wide.isMessageTruncated, "a message that fits read as cut")
        #expect(narrow.isMessageTruncated, "a cut message read as whole")
    }

    // MARK: - The tap

    /// Cut, with an action: the body's tap opens the sheet and does NOT run
    /// the action; the toast waits while the sheet is up, and the sheet
    /// offers the same action, which runs once and takes the toast away.
    @Test func aCutToastsTapOpensTheSheetNotTheAction() throws {
        var caught: [UIViewController] = []
        let previous = ToastView.presentFullMessage
        ToastView.presentFullMessage = { sheet, _ in caught.append(sheet) }
        defer { ToastView.presentFullMessage = previous }
        try hosting { container in
            var runs = 0
            let toast = barToast(Self.long, action: ToastView.Action("Retry") { runs += 1 }, width: 180, in: container)
            try #require(toast.isMessageTruncated)
            toast.debugTap()
            #expect(runs == 0, "the body's tap ran the action")
            let sheet = try #require((caught.first as? UINavigationController)?.viewControllers.first as? ToastMessageSheet, "no sheet")
            sheet.loadViewIfNeeded()
            #expect(sheet.messageLabel.text == Self.long)
            #expect(sheet.messageLabel.numberOfLines == 0)
            #expect(sheet.actionButton != nil, "the sheet does not offer the action")
            // The owner's layout (2026-10-19): a ✕ in the bar, a large glyph,
            // the action alone in the toolbar, in neutral glass.
            #expect(sheet.navigationItem.rightBarButtonItem === sheet.closeItem, "no ✕ in the bar")
            #expect(sheet.glyphView?.preferredSymbolConfiguration == UIImage.SymbolConfiguration(
                pointSize: ToastMessageSheet.glyphPointSize, weight: .regular
            ))
            #expect(ToastMessageSheet.glyphPointSize >= 44, "the glyph is not large")
            #expect(sheet.toolbarItems?.count == 1 && sheet.toolbarItems?.first?.customView === sheet.actionButton)
            #expect(sheet.navigationController?.isToolbarHidden == false, "the action's toolbar is hidden")
            #expect(sheet.actionButton?.configuration?.baseForegroundColor == .label, "the action is not neutral")
            #expect(toast.countdown?.holds.contains(.sheet) == true, "the toast's time ran under the sheet")

            sheet.debugAct()
            #expect(runs == 1)
            #expect(toast.isDismissing, "acting from the sheet left the toast up")
            #expect(toast.countdown?.holds.contains(.sheet) != true)
        }
    }

    /// Closed without acting: the toast is as it was, its time running again.
    @Test func closingTheSheetLeavesTheToastAsItWas() throws {
        var caught: [UIViewController] = []
        let previous = ToastView.presentFullMessage
        ToastView.presentFullMessage = { sheet, _ in caught.append(sheet) }
        defer { ToastView.presentFullMessage = previous }
        try hosting { container in
            let toast = barToast(Self.long, width: 180, in: container)
            toast.debugTap()
            let sheet = try #require((caught.first as? UINavigationController)?.viewControllers.first as? ToastMessageSheet)
            sheet.loadViewIfNeeded()
            #expect(sheet.actionButton == nil, "an action offered for a toast that has none")
            #expect(sheet.navigationController?.isToolbarHidden == true, "a toolbar with nothing in it")
            sheet.debugClose()
            #expect(!toast.isDismissing)
            #expect(toast.countdown?.holds.isEmpty == true)
            #expect(toast.countdown?.isRunning == true, "the time did not resume")
        }
    }

    /// Whole: the tap runs the action as before, and no sheet.
    @Test func aToastThatFitsBehavesAsBefore() {
        var caught: [UIViewController] = []
        let previous = ToastView.presentFullMessage
        ToastView.presentFullMessage = { sheet, _ in caught.append(sheet) }
        defer { ToastView.presentFullMessage = previous }
        hosting { container in
            var runs = 0
            let toast = barToast("Couldn't send", action: ToastView.Action("Retry") { runs += 1 }, width: 300, in: container)
            #expect(!toast.isMessageTruncated)
            toast.debugTap()
            #expect(caught.isEmpty, "a sheet for a message that fits")
            #expect(runs == 1)
        }
    }

    /// A collapsed bar toast: the first tap brings it forward, no sheet.
    @Test func aCollapsedBarToastsFirstTapBringsItForward() {
        var caught: [UIViewController] = []
        let previous = ToastView.presentFullMessage
        ToastView.presentFullMessage = { sheet, _ in caught.append(sheet) }
        defer { ToastView.presentFullMessage = previous }
        hosting { container in
            let toast = barToast(Self.long, width: 180, in: container)
            var forwarded = 0
            toast.onBarTap = { _ in forwarded += 1 }
            toast.isCollapsedInBar = true
            toast.layoutIfNeeded()
            toast.debugTap()
            #expect(forwarded == 1)
            #expect(caught.isEmpty)
        }
    }

    /// Over the content too: a cut capsule opens the sheet.
    @Test func aCutCapsuleOpensTheSheet() throws {
        var caught: [UIViewController] = []
        let previous = ToastView.presentFullMessage
        ToastView.presentFullMessage = { sheet, _ in caught.append(sheet) }
        defer { ToastView.presentFullMessage = previous }
        try hosting { container in
            let message = Array(repeating: Self.long, count: 3).joined(separator: " ")
            let toast = ToastView.present(message, symbol: nil, style: .failure, action: nil, position: .bottom, in: container)
            container.layoutIfNeeded()
            try #require(toast.isMessageTruncated, "a three-sentence toast fits on one line")
            toast.debugTap()
            #expect(caught.count == 1)
        }
    }

    /// A toast fired while a full-message sheet is up never lands in the
    /// sheet: its host is the screen under it (the ✕ stays the sheet's).
    @Test func aToastNeverTakesItsSheetAsHost() {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.isHidden = false
        defer { window.isHidden = true }
        let sheet = ToastMessageSheet(message: Self.long, glyph: nil, glyphTint: .label, actionTitle: nil)
        let wrapped = sheet.wrappedInSheet()
        #expect(Feedback.isToastMessageSheet(wrapped))
        #expect(!Feedback.isToastMessageSheet(UINavigationController(rootViewController: UIViewController())))
        #expect(Feedback.host(for: screen) === screen)
    }

    // MARK: - VoiceOver

    /// "Show Full Message" while cut, ahead of the toast's own actions; not
    /// otherwise.
    @Test func voiceOverOffersTheFullMessageWhileCut() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 100))
        let cut = barToast(Self.long, width: 180, in: container)
        let whole = barToast("Copied", width: 300, in: container)
        #expect(cut.accessibilityCustomActions?.first?.name == "Show Full Message")
        #expect(cut.accessibilityCustomActions?.contains { $0.name == "Dismiss" } == true)
        #expect(whole.accessibilityCustomActions?.contains { $0.name == "Show Full Message" } == false)
    }
}
