import DesignSystem
import UIKit

/// Bare text field for inset-grouped form rows: no chrome of its own (the
/// cell supplies margins and background). (Its secure-entry reveal went
/// with the password field, #840.)
final class CredentialTextField: UITextField {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .appFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
