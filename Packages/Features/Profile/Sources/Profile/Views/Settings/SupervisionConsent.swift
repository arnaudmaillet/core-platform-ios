import DesignSystem
import UIKit

/// What a teen agrees to share by linking with a supervisor (#1116, owner's
/// decision 2026-10-13): said plainly on the accept screen before Link, and
/// again on each supervisor's page so it can be re-read.
///
/// ⚠️ THE WORDS MATCH WHAT THE APP SHARES, nothing more and nothing less:
/// the daily time in this app (reported since #1110) and the limits. The
/// backend can also list a teen's connections and reports to a supervisor;
/// the app shows neither, and if it ever does, these lines must say so.
enum SupervisionConsent {
    struct Line: Hashable {
        let symbol: String
        let text: String
    }

    static let teenTitle = "What your supervisor will see"
    /// A link opened before the age is read: the words still reach a teen.
    static let unknownTitle = "If you're the teen, your supervisor will see"
    /// On a supervisor's page, once linked.
    static let linkedTitle = "What They See"

    /// `linked`: on a supervisor's page, after linking; else before.
    static func lines(linked: Bool) -> [Line] {
        let from: String = linked
            ? "Shared since you linked, not before."
            : "This is shared from the moment you link, not before."
        return [
            Line(symbol: "clock", text: "Your daily time in this app, on every device you use it on."),
            Line(
                symbol: "slider.horizontal.3",
                text: "The limits they set on your account: a daily limit, a private account, who can message or comment, and hiding you from search."
            ),
            Line(symbol: "calendar", text: from),
            Line(
                symbol: "xmark.circle",
                text: "You can end the supervision at any time in Settings → Family and Teens. They'll be told."
            ),
        ]
    }

    /// The title the accept screen shows for the viewer's side; nil for an
    /// adult, who shares nothing by accepting.
    static func acceptTitle(for role: SupervisionRole?) -> String? {
        switch role {
        case .teen: teenTitle
        case nil: unknownTitle
        case .supervisor: nil
        }
    }
}

/// The consent lines as a grouped card: a title, then one row per line with
/// its symbol. Grows with the text size; nothing truncates.
final class SupervisionConsentView: UIView {
    private let titleLabel = UILabel()
    private let rows = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous

        titleLabel.font = .appFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        rows.axis = .vertical
        rows.spacing = Spacing.md

        let stack = UIStackView(arrangedSubviews: [titleLabel, rows])
        stack.axis = .vertical
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.lg),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The words on the card, title first: what a test reads.
    private(set) var texts: [String] = []

    func configure(title: String, lines: [SupervisionConsent.Line]) {
        titleLabel.text = title
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in lines {
            let icon = UIImageView(image: UIImage(systemName: line.symbol))
            icon.tintColor = .secondaryLabel
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.isAccessibilityElement = false
            // One column for every symbol, whatever its own width, so the
            // lines start together; it grows with the text size.
            icon.widthAnchor.constraint(
                equalToConstant: UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 24, compatibleWith: TextSizeCeiling.currentTraits)
            ).isActive = true

            let label = UILabel()
            label.text = line.text
            label.font = .appFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0

            let row = UIStackView(arrangedSubviews: [icon, label])
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = Spacing.md
            rows.addArrangedSubview(row)
        }
        texts = [title] + lines.map(\.text)
    }
}
