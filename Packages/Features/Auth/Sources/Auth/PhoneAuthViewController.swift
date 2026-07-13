import DesignSystem
import UIKit

/// Screen 3 of the sign-in flow: phone entry for the SMS OTP sequence,
/// Telegram-style — a ☎️ hero header, a country row over a split
/// prefix/number row (national digits live-formatted with the country's
/// zero-pattern placeholder), and a full-width Continue button. No
/// password: Continue initiates the SMS dispatch and hands off to the
/// verification sheet via the coordinator.
final class PhoneAuthViewController: BottomAnchoredTableViewController {
    /// Fired with the E.164 token and the human-readable display form.
    var onSendCode: ((_ e164: String, _ display: String) -> Void)?

    private let phoneCell = TextFieldCell()
    private let prefixLabel = UILabel()
    private var country = CountryDialCode.deviceDefault
    private var hasAutofocused = false

    private lazy var countryButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.md, leading: 0, bottom: Spacing.md, trailing: 0
        )
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Country")
        return button
    }()

    private lazy var countryCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        cell.accessoryType = .disclosureIndicator
        countryButton.constrain(in: cell.contentView) { parent in
            countryButton.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            countryButton.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            countryButton.topAnchor.constraint(equalTo: parent.topAnchor)
            countryButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        return cell
    }()

    private lazy var continueButton: UIButton = {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = "Continue"
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.continueTapped() }, for: .primaryActionTriggered)
        return button
    }()

    private lazy var continueCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        continueButton.constrain(in: cell.contentView) { parent in
            continueButton.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            continueButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            continueButton.topAnchor.constraint(equalTo: parent.topAnchor)
            continueButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        return cell
    }()

    #if DEBUG
    /// Sim QA hook: national digits typed on appear, Continue ~1s later.
    var qaAutoSend: String?
    #endif

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let field = phoneCell.textField
        field.keyboardType = .phonePad
        field.textContentType = .telephoneNumber
        field.leftViewMode = .always
        field.addAction(UIAction { [weak self] _ in self?.digitsChanged() }, for: .editingChanged)

        prefixLabel.font = .preferredFont(forTextStyle: .body)
        prefixLabel.adjustsFontForContentSizeCategory = true

        applyCountry(country)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAutofocused {
            hasAutofocused = true
            phoneCell.textField.becomeFirstResponder()
        }
        #if DEBUG
        if let digits = qaAutoSend {
            qaAutoSend = nil
            phoneCell.textField.text = digits
            digitsChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.continueTapped()
            }
        }
        #endif
    }

    private var nationalDigits: String {
        String((phoneCell.textField.text ?? "").filter(\.isNumber).prefix(country.maxNationalDigits))
    }

    /// The live formatter: strip to digits, cap at the country's maximum
    /// (malformed input can't accumulate), regroup. Programmatic `text`
    /// assignment doesn't re-fire `editingChanged`, so this doesn't recurse.
    private func digitsChanged() {
        let digits = nationalDigits
        phoneCell.textField.text = country.format(digits)
        continueButton.isEnabled = country.isValidNationalNumber(digits)
    }

    private func applyCountry(_ selected: CountryDialCode) {
        country = selected

        countryButton.configuration?.title = "\(selected.flag) \(selected.name)"
        countryButton.menu = UIMenu(children: CountryDialCode.all.map { candidate in
            UIAction(
                title: candidate.displayName,
                state: candidate == selected ? .on : .off
            ) { [weak self] _ in
                self?.applyCountry(candidate)
            }
        })

        prefixLabel.text = selected.prefix
        phoneCell.textField.leftView = makePrefixView()
        // Telegram-style zero pattern ("0 00 00 00 00") from the country's
        // own grouping.
        phoneCell.textField.placeholder = selected.format(
            String(repeating: "0", count: selected.maxNationalDigits)
        )
        digitsChanged()
    }

    /// The fixed prefix segment: "+33" with a hairline divider before the
    /// number, like Telegram's split row.
    private func makePrefixView() -> UIView {
        let container = UIView()
        let divider = UIView()
        divider.backgroundColor = .separator
        prefixLabel.constrain(in: container) { parent in
            prefixLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            prefixLabel.topAnchor.constraint(equalTo: parent.topAnchor)
            prefixLabel.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }
        divider.constrain(in: container) { parent in
            divider.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: Spacing.md)
            divider.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
            divider.widthAnchor.constraint(equalToConstant: 0.5)
            divider.topAnchor.constraint(equalTo: parent.topAnchor, constant: -Spacing.xs)
            divider.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: Spacing.xs)
        }
        container.frame.size = container.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return container
    }

    private func continueTapped() {
        let digits = nationalDigits
        guard country.isValidNationalNumber(digits) else { return }
        onSendCode?(country.e164(digits), "\(country.prefix) \(country.format(digits))")
    }

    // MARK: - Table

    private enum Section: Int, CaseIterable {
        case form
        case action
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .form: 2
        case .action: 1
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .form:
            return indexPath.row == 0 ? countryCell : phoneCell
        case .action:
            return continueCell
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard Section(rawValue: section) == .form else { return nil }
        return makeHeroHeader(
            emoji: "\u{260E}\u{FE0F}",
            title: "Your Phone",
            subtitle: "Please enter your phone number."
        )
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .form: UITableView.automaticDimension // the hero block
        case .action: Spacing.lg - Self.collapsedFooterHeight
        }
    }
}
