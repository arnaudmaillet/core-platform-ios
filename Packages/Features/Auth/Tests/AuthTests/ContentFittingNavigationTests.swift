import CoreModels
import Testing
import UIKit
@testable import Auth

// The sign-in sheet sized to its step (#563), and its two stages and
// protected swipe (#1811).

/// A step with a fixed number of fixed-height rows.
private final class FixedRowsStep: UITableViewController {
    var rows = 3

    init() { super.init(style: .plain) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.rowHeight = 44
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    }
}

@MainActor
struct ContentFittingNavigationTests {
    /// The flow's stack is the fitting one, so the app can size its sheet.
    @Test func theFlowIsAContentFittingStack() {
        let flow = LoginFlowCoordinator().start()
        #expect(flow is ContentFittingNavigationController)
    }

    /// ONE detent: a sheet holding two is always draggable between them, which
    /// is how the old sheet could be pulled to full height over a short step.
    @Test func fittingASheetInstallsOneSelectedDetent() throws {
        let navigation = ContentFittingNavigationController(rootViewController: FixedRowsStep())
        navigation.modalPresentationStyle = .pageSheet
        let sheet = try #require(navigation.sheetPresentationController)

        navigation.fit(sheet, fallback: 540)

        #expect(sheet.detents.count == 1)
        #expect(sheet.selectedDetentIdentifier == sheet.detents.first?.identifier)
        #expect(navigation.onFittedHeightChange != nil)
    }

    /// Off screen, the bars add no safe area yet, so any answer would be short
    /// by both bands: the stack has none to give, and the sheet's fallback
    /// serves.
    @Test func offScreenTheStackHasNoHeightToGive() {
        let step = FixedRowsStep()
        let navigation = ContentFittingNavigationController(rootViewController: step)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        navigation.view.layoutIfNeeded()
        step.tableView.layoutIfNeeded()

        #expect(step.tableView.contentSize.height > 0)
        #expect(navigation.fittedHeight == nil)
    }

    /// The sheet is the step's height; the fallback serves while there is
    /// none; and content taller than the screen (largest text, a small phone)
    /// is capped at the maximum, where it scrolls.
    @Test func theDetentIsTheStepsHeightCappedAtTheScreen() {
        #expect(ContentFittingNavigationController.detentHeight(fitted: 546, fallback: 540, maximum: 800) == 546)
        #expect(ContentFittingNavigationController.detentHeight(fitted: nil, fallback: 540, maximum: 800) == 540)
        #expect(ContentFittingNavigationController.detentHeight(fitted: 1_200, fallback: 540, maximum: 800) == 800)
        #expect(ContentFittingNavigationController.detentHeight(fitted: nil, fallback: 540, maximum: 500) == 500)
    }

    /// The fitted height ends where the step's last section does — not at
    /// the grouped table's `contentSize`, whose trailing padding was a second
    /// bottom margin under the legal line (#1908) — less the bottom inset the
    /// sheet adds back (none in a test window).
    @Test func theFittedHeightEndsAtTheLastSection() throws {
        let methods = MethodSelectionViewController(methods: SignInMethod.offered(passkeys: false))
        let navigation = ContentFittingNavigationController(rootViewController: methods)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        methods.tableView.layoutIfNeeded()
        let table = methods.tableView!
        let end = table.rectForFooter(inSection: table.numberOfSections - 1).maxY
        let fitted = try #require(navigation.fittedHeight)
        #expect(abs(fitted - (end - window.safeAreaInsets.bottom).rounded(.up)) < 1)
        #expect(fitted <= table.contentSize.height, "the trailing padding is still counted")
    }

    /// The steps lay their content from the TOP (#1908): no inset pushes it
    /// down to the bottom, so the keyboard's arrival moves nothing.
    @Test func aStepLaysItsContentFromTheTop() {
        let methods = MethodSelectionViewController(methods: SignInMethod.offered(passkeys: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = methods
        window.isHidden = false
        defer { window.isHidden = true }
        methods.view.layoutIfNeeded()
        #expect(methods.tableView.contentInset.top == 0, "the content was pushed to the bottom")
    }

    /// A step that is not a table (a placeholder page) has no content height
    /// to report either.
    @Test func aStepThatIsNotATableHasNoHeight() {
        let navigation = ContentFittingNavigationController(rootViewController: UIViewController())
        #expect(navigation.fittedHeight == nil)
    }

    // MARK: - #1811: two stages, a protected swipe

    /// The list's stack is fitted whatever is on top; the form's own stack is
    /// at full height from its first step (#1908).
    @Test func theListIsFittedAndTheFormIsLarge() {
        let root = FixedRowsStep()
        let list = ContentFittingNavigationController(rootViewController: root)
        let form = ContentFittingNavigationController(rootViewController: FixedRowsStep(), isForm: true)

        #expect(list.stage(for: root) == .fitted)
        #expect(form.stage(for: form.viewControllers[0]) == .large)
    }

    /// The list's ONE detent is its fitted height and stays so whatever is
    /// pushed; the form's own sheet has `.large()` alone, so it can never be
    /// dragged down to the list's height (#1908).
    @Test func eachSheetKeepsItsOneDetent() throws {
        let list = ContentFittingNavigationController(rootViewController: FixedRowsStep())
        list.modalPresentationStyle = .pageSheet
        let listSheet = try #require(list.sheetPresentationController)
        list.fit(listSheet, fallback: 540)
        list.navigationController(list, willShow: list.viewControllers[0], animated: false)
        #expect(list.shownStage == .fitted)
        #expect(listSheet.selectedDetentIdentifier?.rawValue == "fittedContent")

        let form = ContentFittingNavigationController(rootViewController: FixedRowsStep(), isForm: true)
        form.modalPresentationStyle = .pageSheet
        let formSheet = try #require(form.sheetPresentationController)
        form.fit(formSheet, fallback: 0)
        let next = FixedRowsStep()
        form.pushViewController(next, animated: false)
        form.navigationController(form, willShow: next, animated: false)
        #expect(form.shownStage == .large)
        #expect(formSheet.detents.count == 1)
        #expect(formSheet.selectedDetentIdentifier == .large)
    }

    /// A swipe closes the sheet at once until the flow protects the step on
    /// top; then the sheet asks first (`isModalInPresentation`).
    @Test func theSwipeIsProtectedOnlyWhereTheFlowSaysSo() {
        let navigation = ContentFittingNavigationController(rootViewController: FixedRowsStep())
        let protected = FixedRowsStep()
        navigation.protectsInput = { $0 === protected }
        #expect(!navigation.isModalInPresentation)

        navigation.pushViewController(protected, animated: false)
        #expect(navigation.isModalInPresentation)
        navigation.popViewController(animated: false)
        #expect(!navigation.isModalInPresentation)
    }

    /// The confirmation's words (the owner, 2026-10-28): neutral, with Keep
    /// going and Stop.
    @Test func leavingAsksOnceInNeutralWords() throws {
        let navigation = ContentFittingNavigationController(rootViewController: FixedRowsStep())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }

        navigation.confirmLeaving()
        let alert = try #require(navigation.topViewController?.presentedViewController as? UIAlertController)
        #expect(alert.title == "Leave now?")
        #expect(alert.message == "What you\u{2019}ve entered won\u{2019}t be kept.")
        #expect(alert.actions.map(\.title) == ["Keep going", "Stop"])
        #expect(alert.actions.map(\.style) == [.cancel, .destructive])
    }
}
