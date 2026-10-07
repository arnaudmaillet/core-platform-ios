import CoreModels
import Testing
import UIKit
@testable import Auth

// The sign-in sheet sized to its step (#563).

private struct NoLogin: LoginPerforming {
    func login(username: String, password: String) async throws -> LoginOutcome { .signedIn }
    func completeLogin(_ challenge: SecondStepChallenge, code: String) async throws {}
}

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
        let flow = LoginFlowCoordinator(loginService: NoLogin()).start(prompt: nil) {}
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

    /// A step that is not a table (a placeholder page) has no content height
    /// to report either.
    @Test func aStepThatIsNotATableHasNoHeight() {
        let navigation = ContentFittingNavigationController(rootViewController: UIViewController())
        #expect(navigation.fittedHeight == nil)
    }
}
