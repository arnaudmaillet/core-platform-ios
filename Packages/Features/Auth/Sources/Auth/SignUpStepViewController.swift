import DesignSystem
import UIKit

/// The shape every sign-up step shares (guest mode B4): the flow's hero
/// header, the step's own rows, and one full-width primary button — on the
/// bottom-anchored table the credential screens use, so a step sits above
/// the keyboard like the rest of the flow.
class SignUpStepViewController: BottomAnchoredTableViewController {
    private let emoji: String
    private let heading: String
    private let subtitle: String
    /// The step's rows, in one card. Set by the subclass in `viewDidLoad`
    /// before `super`'s table loads.
    var rows: [UITableViewCell] = []
    /// Rows under the button (a link, a note).
    var trailingRows: [UITableViewCell] = []
    var onTrailingRowSelected: ((Int) -> Void)?

    private let feedback = HapticNotification()

    lazy var primaryButton: UIButton = {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .primaryActionTriggered)
        return button
    }()

    private lazy var buttonCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        primaryButton.constrain(in: cell.contentView) { parent in
            primaryButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            primaryButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            primaryButton.topAnchor.constraint(equalTo: parent.topAnchor)
            primaryButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        return cell
    }()

    init(emoji: String, title: String, subtitle: String, buttonTitle: String) {
        self.emoji = emoji
        self.heading = title
        self.subtitle = subtitle
        super.init(style: .insetGrouped)
        primaryButton.configuration?.title = buttonTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The step's action. Subclasses override.
    func primaryTapped() {}

    /// Spinner on the button, back disabled, inputs locked — while a call runs.
    func setWorking(_ working: Bool) {
        primaryButton.configuration?.showsActivityIndicator = working
        primaryButton.isEnabled = !working && canContinue
        navigationItem.hidesBackButton = working
        view.isUserInteractionEnabled = !working
        if working {
            feedback.prepare()
            view.endEditing(true)
        }
    }

    /// Whether the step's input is complete. Subclasses override.
    var canContinue: Bool { true }

    func refreshButton() {
        primaryButton.isEnabled = canContinue
    }

    func present(error: Error) {
        feedback.notificationOccurred(.error)
        let message = (error as? AuthError).map(LoginViewModel.message(for:)) ?? "Something went wrong. Try again."
        let alert = UIAlertController(title: "Couldn\u{2019}t Continue", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshButton()
    }

    // MARK: - Table

    private enum Section: Int, CaseIterable { case rows, button, trailing }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .rows: rows.count
        case .button: 1
        case .trailing: trailingRows.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .rows: rows[indexPath.row]
        case .button: buttonCell
        case .trailing: trailingRows[indexPath.row]
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .trailing else { return }
        onTrailingRowSelected?(indexPath.row)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard Section(rawValue: section) == .rows else { return nil }
        return makeHeroHeader(emoji: emoji, title: heading, subtitle: subtitle)
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .rows: UITableView.automaticDimension
        case .button: Spacing.lg - Self.collapsedFooterHeight
        case .trailing: trailingRows.isEmpty ? Self.collapsedFooterHeight : Spacing.md - Self.collapsedFooterHeight
        }
    }
}
