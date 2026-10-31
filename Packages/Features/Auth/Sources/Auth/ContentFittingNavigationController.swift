import UIKit

/// The sign-in flow's navigation stacks, and the sheets they are presented
/// in (#563, #1811, #1908): a short sheet for the method choice, and the form
/// in a full-height sheet of its own over it.
///
/// - THE METHOD LIST is a content-fitted sheet over what the guest was doing
///   (#563): every step is a table, and a table knows its content's height
///   (`contentSize`); the sheet asks `fittedHeight` — navigation bar + that
///   content — through one custom detent, so it is exactly as tall as the
///   list and can never be dragged taller. Sign in with Apple and passkeys
///   finish here, through the system's own sheets.
/// - THE FORM (email or phone, then the code and the steps after it) is a
///   SECOND SHEET at `.large()`, presented over the list (#1908, the owner
///   2026-10-30): up to six steps, most with the keyboard up, need the full
///   height (#1811) — and the list's own sheet, grown with a push, resized
///   oddly under the viewer's finger. Picking a method presents the form;
///   its steps push inside it; a swipe down takes it away, back to the list
///   (`isForm`).
///
/// ⚠️ THE HEIGHT IS READ, NEVER PUSHED FROM LAYOUT. The share sheet crashed
/// measuring in `viewDidLayoutSubviews` and invalidating from there: dragging
/// the sheet relayouts every frame and recursed. Here the detent only reads
/// a stored answer, and the answer changes only when the top step's
/// `contentSize` does — which a sheet resize never touches (the bottom
/// anchoring moves the content inset, not the content). The change is
/// reported on the next turn, outside the layout pass that produced it.
///
/// THE WAY OUT: the list's × (#1969) and the swipe (#1811). Before a code is
/// sent a swipe closes the sheet at once; once one has (`protectsInput`), a
/// swipe — or VoiceOver's escape — asks one confirmation first, so what was
/// typed is never thrown away by accident. The form's way out is back to
/// the list.
public final class ContentFittingNavigationController: UINavigationController, UINavigationControllerDelegate,
    UISheetPresentationControllerDelegate {
    /// The top step's height changed: the sheet should ask `fittedHeight`
    /// again.
    public var onFittedHeightChange: (() -> Void)?

    /// Whether leaving at `step` would lose what was typed: the code was sent
    /// (#1811). Set by the flow; nil protects nothing.
    var protectsInput: ((UIViewController) -> Bool)?

    /// The sheet's two heights.
    enum Stage: Equatable {
        /// Content-fitted: the method list.
        case fitted
        /// Full height: the form.
        case large
    }

    /// Whether this stack is the form's, in its own full-height sheet over
    /// the list's (#1908).
    let isForm: Bool

    /// The form's stack, presented over this list's sheet; nil while none is.
    weak var formStack: ContentFittingNavigationController?

    /// The form's sheet went away by itself (a swipe): the flow forgets it.
    var onDismissed: (() -> Void)?

    /// The list is fitted; the form is large, whatever step is on top.
    func stage(for step: UIViewController) -> Stage {
        isForm ? .large : .fitted
    }

    private var contentObservation: NSKeyValueObservation?
    private var lastReportedHeight: CGFloat?
    private weak var sheet: UISheetPresentationController?
    private var fallback: CGFloat = 0
    /// The stage the sheet's detents were last set to.
    private(set) var shownStage: Stage = .fitted

    public override convenience init(rootViewController: UIViewController) {
        self.init(rootViewController: rootViewController, isForm: false)
    }

    init(rootViewController: UIViewController, isForm: Bool) {
        self.isForm = isForm
        super.init(rootViewController: rootViewController)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        observeContent(of: topViewController)
    }

    /// The sheet height the top step needs, excluding the bottom safe area
    /// the sheet adds back. Nil while the step is not a table, is not on
    /// screen (off-window, the bar adds no safe area yet and the answer would
    /// be short by its band), or has not been laid out.
    public var fittedHeight: CGFloat? {
        guard let step = topViewController as? UITableViewController,
              step.viewIfLoaded?.window != nil,
              step.tableView.contentSize.height > 0 else { return nil }
        let table: UITableView = step.tableView
        // The bar's band as the step sees it: what it adds to its safe area
        // over the stack's own — the method list's title bar (#1969).
        // ⚠️ NOT the bar's frame, which carries the sheet's top padding
        // unevenly.
        let bar = max(0, step.view.safeAreaInsets.top - view.safeAreaInsets.top)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sheet-fit-trace") {
            print("[sheet-fit] bar=\(bar) content=\(table.contentSize.height) "
                + "inset=\(table.contentInset.top) step=\(type(of: topViewController!))")
        }
        #endif
        // ⚠️ THE CONTENT'S END, AND NO SECOND BOTTOM MARGIN (#1908, the
        // owner: ~60 pt under the legal line against ~20 at the sides). The
        // grouped table's `contentSize` carries ~20 pt of trailing padding
        // past its last section, and the floating sheet adds the bottom
        // safe area on top of the answer, though it already stands clear of
        // the home indicator. So: the last section's end, less the inset the
        // sheet will add back — the legal line's own padding is the gap.
        let sections = table.numberOfSections
        let end = sections > 0 ? table.rectForFooter(inSection: sections - 1).maxY : table.contentSize.height
        let added = view.window?.safeAreaInsets.bottom ?? 0
        return max(0, bar + end - added).rounded(.up)
    }

    private static let fittedIdentifier = UISheetPresentationController.Detent.Identifier("fittedContent")

    /// Presents the flow in `sheet`: the method list exactly as tall as its
    /// content — ONE content-sized detent, capped at the screen's maximum
    /// (taller content scrolls), re-asked whenever the step's height changes
    /// — and the form at full height. `fallback` serves while the list has no
    /// height to give.
    public func fit(_ sheet: UISheetPresentationController, fallback: CGFloat) {
        self.sheet = sheet
        self.fallback = fallback
        sheet.delegate = self
        sheet.prefersGrabberVisible = true
        shownStage = topViewController.map(stage(for:)) ?? .fitted
        applyDetents(for: shownStage, to: sheet)
        onFittedHeightChange = { [weak sheet] in
            guard let sheet else { return }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// One detent per stage, so the list can never be dragged to full height
    /// nor the form down to the list's.
    private func applyDetents(for stage: Stage, to sheet: UISheetPresentationController) {
        switch stage {
        case .fitted:
            let fallback = fallback
            sheet.detents = [
                .custom(identifier: Self.fittedIdentifier) { [weak self] context in
                    Self.detentHeight(fitted: self?.fittedHeight, fallback: fallback, maximum: context.maximumDetentValue)
                }
            ]
            sheet.selectedDetentIdentifier = Self.fittedIdentifier
        case .large:
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
        }
    }

    /// Moves the sheet to `step`'s stage, in the push's (or the pop's)
    /// animation.
    private func moveSheet(to step: UIViewController) {
        let next = self.stage(for: step)
        guard next != shownStage, let sheet else { return }
        shownStage = next
        sheet.animateChanges { applyDetents(for: next, to: sheet) }
    }

    /// The detent's answer: the step's height, or the fallback while it has
    /// none, never past the screen's maximum — taller content scrolls inside
    /// a sheet capped there. Pure, for tests.
    static func detentHeight(fitted: CGFloat?, fallback: CGFloat, maximum: CGFloat) -> CGFloat {
        min(fitted ?? fallback, maximum)
    }

    // MARK: - Leaving (#1811)

    /// What a swipe asks: nothing to lose, the sheet closes; something
    /// typed, it stays and asks (`presentationControllerDidAttemptToDismiss`).
    /// The sheet's own presented controller forwards to this.
    public override var isModalInPresentation: Bool {
        get { topViewController.map { protectsInput?($0) ?? false } ?? false }
        set {}
    }

    public func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmLeaving()
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismissed?()
    }

    /// The list's × (#1969): the swipe's exit — the sheet closes at once, and
    /// its container answers the gate as it does for a swipe.
    func close() {
        leave()
    }

    /// VoiceOver's escape, the only non-visual way out with no close button:
    /// the same rule as the swipe.
    public override func accessibilityPerformEscape() -> Bool {
        guard presentingViewController != nil else { return false }
        if isModalInPresentation {
            confirmLeaving()
        } else {
            leave()
        }
        return true
    }

    /// The confirmation's words (the owner, 2026-10-28): neutral — leaving
    /// keeps nothing typed, and deletes nothing that exists.
    static let leaveTitle = "Leave now?"
    static let leaveMessage = "What you\u{2019}ve entered won\u{2019}t be kept."
    static let keepGoingTitle = "Keep going"
    static let stopTitle = "Stop"

    /// Asks once: Keep going leaves the sheet and the step as they were;
    /// Stop closes the sheet.
    func confirmLeaving() {
        let host = topViewController ?? self
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: Self.leaveTitle, message: Self.leaveMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Self.keepGoingTitle, style: .cancel))
        alert.addAction(UIAlertAction(title: Self.stopTitle, style: .destructive) { [weak self] _ in self?.leave() })
        host.present(alert, animated: true)
    }

    /// Closes the sheet: whatever presented it answers the exit (the shell's
    /// gate hears it from the sheet's own disappearance). The form's sheet
    /// closes back to the list.
    private func leave() {
        if isForm {
            dismiss(animated: true)
            onDismissed?()
        } else {
            (parent ?? self).dismiss(animated: true)
        }
    }

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        observeContent(of: viewController)
        moveSheet(to: viewController)
        // A step already laid out (a pop) reports at once, alongside the
        // transition; a new one reports when its first layout sizes it.
        reportIfChanged()
    }

    // MARK: - Content

    private func observeContent(of viewController: UIViewController?) {
        contentObservation = (viewController as? UITableViewController)?.tableView.observe(
            \.contentSize, options: [.new]
        ) { [weak self] _, _ in
            // Next turn, outside the layout pass that changed it.
            Task { @MainActor [weak self] in self?.reportIfChanged() }
        }
    }

    private func reportIfChanged() {
        guard shownStage == .fitted, let height = fittedHeight, height != lastReportedHeight else { return }
        lastReportedHeight = height
        onFittedHeightChange?()
    }
}
