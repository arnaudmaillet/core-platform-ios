import DesignSystem
import UIKit

/// Inset-grouped row hosting a full-width text field, in the style of Mail's
/// account form rows (placeholder-labelled, flush with cell margins).
final class TextFieldCell: UITableViewCell {
    let textField = CredentialTextField()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        textField.constrain(in: contentView) { parent in
            textField.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            textField.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            textField.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.md)
            textField.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.md)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
