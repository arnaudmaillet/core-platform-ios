import DesignSystem
import UIKit

/// The verification card presented as a native sheet after the SMS
/// dispatch: a single code field with `.oneTimeCode` content type, so
/// incoming SMS codes surface in the keyboard AutoFill bar on device.
/// Verification auto-fires when the full code is typed.
final class OTPVerificationViewController: UITableViewController {
    var onVerify: ((String) -> Void)?

    private static let codeLength = 6

    private let phoneDisplay: String
    private let codeCell = TextFieldCell()
    private var hasSubmitted = false

    private lazy var verifyButton = BarItems.title(id: Self.verifyID, title: "Verify", prominent: true) { [weak self] in
        self?.verifyTapped()
    }
    static let verifyID = "auth.otp.verify"

    #if DEBUG
    /// Sim QA hook: the code typed ~1s after appear (auto-verifies at full
    /// length like real input).
    var qaAutoVerify: String?
    #endif

    init(phoneDisplay: String) {
        self.phoneDisplay = phoneDisplay
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Enter Code"
        // A titled header: the soft blur covers the bar (#1591) — see
        // `applyTopEdge(for:)`.
        tableView.applyTopEdge(for: .titled)
        setOwnTrailingBarItems([verifyButton], animated: false)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.leftBarButtonItem?.identifier = "auth.otp.cancel"
        verifyButton.isEnabled = false

        let field = codeCell.textField
        field.placeholder = "Code"
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.textAlignment = .center
        field.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeCell.textField.becomeFirstResponder()
        #if DEBUG
        if let code = qaAutoVerify {
            qaAutoVerify = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.codeCell.textField.text = code
                self?.codeChanged()
            }
        }
        #endif
    }

    private var code: String {
        String((codeCell.textField.text ?? "").filter(\.isNumber).prefix(Self.codeLength))
    }

    private func codeChanged() {
        let code = code
        codeCell.textField.text = code
        verifyButton.isEnabled = code.count == Self.codeLength
        if code.count == Self.codeLength {
            verifyTapped()
        }
    }

    private func verifyTapped() {
        guard !hasSubmitted, code.count == Self.codeLength else { return }
        hasSubmitted = true
        // At work (#1775): the word becomes the kit's loader, under its
        // identifier, until the flow answers.
        setOwnTrailingBarItems([BarItems.busy(id: Self.verifyID, label: "Verifying")], animated: view.window != nil)
        onVerify?(code)
    }

    #if DEBUG
    /// Internal for tests: whether Verify is its busy twin.
    var debugVerifyIsBusy: Bool { ownTrailingBarItems.first?.customView != nil }
    /// Internal for tests: types `code` as the field would.
    func debugType(_ code: String) {
        codeCell.textField.text = code
        codeChanged()
    }
    #endif

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        codeCell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Sent to \(phoneDisplay)"
    }
}
