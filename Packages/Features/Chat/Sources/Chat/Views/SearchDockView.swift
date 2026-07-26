import DesignSystem
import UIKit

/// The compose picker's search field, docked at the bottom of the screen.
///
/// A floating glass capsule rather than `navigationItem.searchController`,
/// because the placement is the point: on a screen whose primary action is
/// search, the field belongs under the thumb. iOS 26 *does* dock a search
/// controller's field at the bottom by itself — but only when its view
/// controller is the ROOT of its navigation stack (the Search tab, a sheet's
/// root). The picker is pushed, and for a pushed screen `.automatic` resolves
/// to the navigation bar, with no explicit "bottom" placement to ask for.
///
/// Owning the field has a second payoff. A `UISearchController`'s bar lives in
/// the navigation bar, which does not travel with a push or pop — that is what
/// left it stranded across the destination's chrome mid-transition, and what
/// the transition-coordinator choreography existed to paper over. This is an
/// ordinary subview of the screen it belongs to, so it slides with it for free.
///
/// Built to match `ChatInputBar`: same glass, same capsule, same dock against
/// `keyboardLayoutGuide` — the two screens are one step apart in the same flow
/// and their bottom bars should read as the same object.
final class SearchDockView: UIView {
    /// What the trailing button does right now. Mirrors `ChatInputBar`'s
    /// send/dismiss split one screen along: the same control changes job with
    /// the field's state rather than crowding the dock with two buttons.
    private enum TrailingAction {
        /// Focused with something typed — clear it, keeping focus so the next
        /// query can be typed straight away.
        case clear
        /// Focused and empty — there is nothing to clear, so the useful thing
        /// is to put the keyboard away.
        case dismissKeyboard
        /// Unfocused and empty: no job, no button.
        case none

        var symbol: String? {
            switch self {
            case .clear: "xmark"
            case .dismissKeyboard: "keyboard.chevron.compact.down"
            case .none: nil
            }
        }

        var label: String? {
            switch self {
            case .clear: "Clear search"
            case .dismissKeyboard: "Hide keyboard"
            case .none: nil
            }
        }
    }

    /// Fires on every keystroke, already trimmed of nothing — the view model
    /// owns debouncing and trimming.
    var onQueryChange: ((String) -> Void)?

    /// The dock's top edge, for anything that must stay clear of it.
    var dockTopAnchor: NSLayoutYAxisAnchor { topAnchor }

    var text: String {
        get { field.text ?? "" }
        set {
            field.text = newValue
            syncTrailingButton(animated: false)
            onQueryChange?(newValue)
        }
    }

    private let glass = UIVisualEffectView(effect: nil)
    private let field = UITextField()
    private let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let trailingButton = UIButton(type: .system)
    private var trailingAction = TrailingAction.none
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        magnifier.tintColor = .secondaryLabel
        magnifier.contentMode = .scaleAspectFit
        magnifier.setContentHuggingPriority(.required, for: .horizontal)

        field.placeholder = "Search"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        // The button's job depends on focus as well as content, so both edges
        // of the editing session have to move it.
        field.addTarget(self, action: #selector(editingStateChanged), for: .editingDidBegin)
        field.addTarget(self, action: #selector(editingStateChanged), for: .editingDidEnd)

        let capsuleRow = UIStackView(arrangedSubviews: [magnifier, field])
        capsuleRow.alignment = .center
        capsuleRow.spacing = Spacing.sm
        capsuleRow.pin(to: glass.contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        ))

        // A control of its own rather than `field.clearButtonMode`: that draws a
        // small grey glyph INSIDE the capsule, which is neither glass nor
        // reachable without aiming, and it can only ever mean "clear". A
        // full-size glass button beside the field — the same object the rest of
        // the screen is made of — can also carry the dismiss-keyboard job when
        // there is nothing to clear.
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .secondaryLabel
        trailingButton.configuration = configuration
        trailingButton.setContentHuggingPriority(.required, for: .horizontal)
        trailingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingButton.isHidden = true
        trailingButton.addAction(
            UIAction { [weak self] _ in self?.performTrailingAction() },
            for: .primaryActionTriggered
        )

        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Spacing.sm
        row.addArrangedSubview(glass)
        row.addArrangedSubview(trailingButton)
        row.pin(to: self)

        NSLayoutConstraint.activate([
            magnifier.widthAnchor.constraint(equalToConstant: 20),
            magnifier.heightAnchor.constraint(equalToConstant: 20),
            trailingButton.widthAnchor.constraint(equalTo: glass.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Materialized here rather than in init, for the reason `ChatInputBar`
        // documents: building a glass effect off-window stalls the render
        // server on headless CI simulators.
        if glass.effect == nil {
            let effect = UIGlassEffect()
            // The native press response — the glass flexes under a touch rather
            // than sitting inert like a styled rectangle. Matches the system's
            // own search fields, and the capsule is a touch target (it focuses
            // the field), so it should answer to being pressed.
            effect.isInteractive = true
            glass.effect = effect
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.layer.cornerRadius = glass.bounds.height / 2
        glass.clipsToBounds = true
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        field.resignFirstResponder()
    }

    private func performTrailingAction() {
        switch trailingAction {
        case .clear:
            // Focus is kept: the viewer cleared the query to type another one,
            // not to leave. The button becomes "hide keyboard" on the next sync.
            field.text = ""
            syncTrailingButton(animated: true)
            onQueryChange?("")
        case .dismissKeyboard:
            field.resignFirstResponder()
        case .none:
            break
        }
    }

    @objc private func editingChanged() {
        syncTrailingButton(animated: true)
        onQueryChange?(field.text ?? "")
    }

    @objc private func editingStateChanged() {
        syncTrailingButton(animated: true)
    }

    private func syncTrailingButton(animated: Bool) {
        let next: TrailingAction = if !(field.text ?? "").isEmpty {
            .clear
        } else if field.isFirstResponder {
            .dismissKeyboard
        } else {
            .none
        }
        guard next != trailingAction else { return }
        trailingAction = next

        if let symbol = next.symbol {
            trailingButton.configuration?.image = UIImage(systemName: symbol)
            trailingButton.accessibilityLabel = next.label
        }
        let shouldShow = next != .none
        guard trailingButton.isHidden == shouldShow else { return }
        guard animated, window != nil else {
            trailingButton.isHidden = !shouldShow
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            self.trailingButton.isHidden = !shouldShow
            self.layoutIfNeeded()
        }
    }
}
