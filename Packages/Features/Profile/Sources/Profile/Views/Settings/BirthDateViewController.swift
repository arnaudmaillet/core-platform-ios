import DesignSystem
import UIKit

/// Settings → Account → Date of Birth (#394), when none is on file.
///
/// A date picker, what the date is for, and that it is set once: afterwards
/// only support changes it (the backend refuses a second one). Under the
/// minimum age the Save button stays off and the screen says why — the
/// server would refuse it anyway (ACC-2004).
final class BirthDateViewController: UIViewController {
    private let setter: any AccountBirthDateSetting
    private let onSaved: () -> Void
    private let today: () -> Date
    private let picker = UIDatePicker()
    private let note = UILabel()
    private var isSaving = false
    /// Save waits for the viewer to turn the wheel: the opening date is a
    /// guess, and this is set once.
    private var hasChosen = false

    static let explanation = "Private: only you can see it. It's used to give you the protections that fit your age. "
        + "You can add it once; to correct it later, contact support."

    init(setter: any AccountBirthDateSetting, onSaved: @escaping () -> Void, today: @escaping () -> Date = Date.init) {
        self.setter = setter
        self.onSaved = onSaved
        self.today = today
        super.init(nibName: nil, bundle: nil)
        title = "Date of Birth"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .prominent, target: self, action: #selector(confirm))

        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .wheels
        picker.maximumDate = today()
        picker.minimumDate = Calendar.current.date(byAdding: .year, value: -120, to: today())
        // Nothing pre-chosen that could be saved by accident: the wheel opens
        // on a plausible adult year and Save waits for a real choice.
        picker.date = Calendar.current.date(byAdding: .year, value: -25, to: today()) ?? today()
        picker.addAction(UIAction { [weak self] _ in
            self?.hasChosen = true
            self?.refresh()
        }, for: .valueChanged)

        note.font = .appFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel
        note.numberOfLines = 0

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        picker.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(picker)
        let stack = UIStackView(arrangedSubviews: [card, note])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            picker.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            picker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
        ])
        refresh()
    }

    private var chosen: BirthDate { BirthDate(date: picker.date) }

    static func noteText(for check: BirthDatePolicy.Check) -> String {
        switch check {
        case .ok: explanation
        case .inTheFuture: "Choose a date in the past."
        case .underMinimumAge: "You need to be at least \(BirthDatePolicy.minimumAge) to use the app."
        }
    }

    private func refresh() {
        let check = BirthDatePolicy.check(chosen, today: today())
        note.text = Self.noteText(for: check)
        note.textColor = check == .ok ? .secondaryLabel : .systemRed
        navigationItem.rightBarButtonItem?.isEnabled = check == .ok && hasChosen && !isSaving
    }

    @objc private func confirm() {
        guard BirthDatePolicy.check(chosen, today: today()) == .ok, hasChosen, !isSaving else { return }
        let formatted = DateFormatter.localizedString(from: picker.date, dateStyle: .long, timeStyle: .none)
        let alert = UIAlertController(
            title: "Save \(formatted)?",
            message: "You can't change it yourself afterwards.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.save() })
        present(alert, animated: true)
    }

    private func save() {
        isSaving = true
        refresh()
        let birthDate = chosen
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await setter.setDateOfBirth(birthDate)
                HapticNotification().notificationOccurred(.success)
                onSaved()
                navigationController?.popViewController(animated: true)
            } catch {
                isSaving = false
                refresh()
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let message: String
        switch error as? BirthDateError {
        case .underMinimumAge:
            message = "You need to be at least \(BirthDatePolicy.minimumAge) to use the app here. Nothing was saved."
        case .alreadySet:
            message = "A date of birth is already on file. To correct it, contact support."
        default:
            message = "Couldn't save your date of birth. Check your connection and try again."
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
