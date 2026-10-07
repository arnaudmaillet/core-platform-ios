import UIKit

/// The sign-in flow's navigation stack, as tall as the step on top of it
/// (#563).
///
/// Every step is a table, and a table knows its content's height
/// (`contentSize`). The sheet this stack is presented in asks
/// `fittedHeight` — navigation bar + that content + toolbar band — through
/// one custom detent (`fit(_:fallback:)`), so the sheet is exactly as tall as
/// the step and can never be dragged taller. Pushing or popping a step, or a
/// step's content changing (an error row, the prompt header, a text size),
/// animates the sheet to the new height.
///
/// ⚠️ THE HEIGHT IS READ, NEVER PUSHED FROM LAYOUT. The share sheet crashed
/// measuring in `viewDidLayoutSubviews` and invalidating from there: dragging
/// the sheet relayouts every frame and recursed. Here the detent only reads
/// a stored answer, and the answer changes only when the top step's
/// `contentSize` does — which a sheet resize never touches (the bottom
/// anchoring moves the content inset, not the content). The change is
/// reported on the next turn, outside the layout pass that produced it.
public final class ContentFittingNavigationController: UINavigationController, UINavigationControllerDelegate {
    /// The top step's height changed: the sheet should ask `fittedHeight`
    /// again.
    public var onFittedHeightChange: (() -> Void)?

    private var contentObservation: NSKeyValueObservation?
    private var lastReportedHeight: CGFloat?

    public override init(rootViewController: UIViewController) {
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
    /// (the sheet adds it). Nil while the step is not a table, is not on
    /// screen (off-window, the bars add no safe area yet and the answer would
    /// be short by both bands), or has not been laid out.
    public var fittedHeight: CGFloat? {
        guard let step = topViewController as? UITableViewController,
              step.viewIfLoaded?.window != nil,
              step.tableView.contentSize.height > 0 else { return nil }
        let table: UITableView = step.tableView
        // The bars' bands as the step sees them: what they add to its safe
        // area over the stack's own. ⚠️ NOT the bars' frames — on iOS 27 the
        // floating toolbar's frame spans the whole view (874 pt measured),
        // and the navigation bar's carries the sheet's top padding unevenly.
        let bar = max(0, step.view.safeAreaInsets.top - view.safeAreaInsets.top)
        let toolbarBand = max(0, step.view.safeAreaInsets.bottom - view.safeAreaInsets.bottom)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sheet-fit-trace") {
            print("[sheet-fit] bar=\(bar) content=\(table.contentSize.height) toolbar=\(toolbarBand) "
                + "inset=\(table.contentInset.top) step=\(type(of: topViewController!))")
        }
        #endif
        return (bar + table.contentSize.height + toolbarBand).rounded(.up)
    }

    /// Makes `sheet` exactly as tall as the top step: ONE content-sized
    /// detent, capped at the screen's maximum (taller content scrolls), and
    /// re-asked whenever the step's height changes. `fallback` serves while
    /// the step has no height to give.
    public func fit(_ sheet: UISheetPresentationController, fallback: CGFloat) {
        let identifier = UISheetPresentationController.Detent.Identifier("fittedContent")
        sheet.detents = [
            .custom(identifier: identifier) { [weak self] context in
                Self.detentHeight(fitted: self?.fittedHeight, fallback: fallback, maximum: context.maximumDetentValue)
            }
        ]
        sheet.selectedDetentIdentifier = identifier
        onFittedHeightChange = { [weak sheet] in
            guard let sheet else { return }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// The detent's answer: the step's height, or the fallback while it has
    /// none, never past the screen's maximum — taller content scrolls inside
    /// a sheet capped there. Pure, for tests.
    static func detentHeight(fitted: CGFloat?, fallback: CGFloat, maximum: CGFloat) -> CGFloat {
        min(fitted ?? fallback, maximum)
    }

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        observeContent(of: viewController)
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
        guard let height = fittedHeight, height != lastReportedHeight else { return }
        lastReportedHeight = height
        onFittedHeightChange?()
    }
}
