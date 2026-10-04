import DesignSystem
import UIKit

/// The map's way to the device's country (guest mode §3.1), on a row above
/// the filter bars:
///
/// - the **card** — "See posts around you" — while nothing at all is open on
///   the map (a guest without location, decision 9). It says what allowing
///   location does, or, once denied, where to turn it back on;
/// - otherwise the **locate button** at the trailing edge — the same question
///   in a glyph, and, once allowed, the way back to the country the device is
///   in.
///
/// Either one is how location is ever asked for: in context, never at launch.
/// The row passes every touch outside its controls through to the map.
final class MapLocationControlsView: UIView {
    enum Face: Equatable {
        /// Nothing shown (no locator).
        case none
        case card(LocationPermission)
        case button(LocationPermission)
    }

    /// The card or the button was tapped, with the permission it showed.
    var onTap: ((LocationPermission) -> Void)?

    private(set) var face: Face = .none
    private let card = UIButton(configuration: .glass())
    private let locateButton = UIButton(configuration: .glass())
    /// The button's row, so the button keeps its size at the trailing end.
    private let buttonRow = UIView()

    static let buttonSize: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.configuration?.cornerStyle = .large
        card.configuration?.imagePadding = Spacing.md
        card.configuration?.titleAlignment = .leading
        card.configuration?.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
        )
        card.contentHorizontalAlignment = .leading
        card.accessibilityIdentifier = "map.location-card"
        card.addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)

        locateButton.configuration?.cornerStyle = .capsule
        locateButton.accessibilityIdentifier = "map.locate"
        locateButton.addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)

        for control in [card, locateButton] {
            PressFeedback.attach(to: control, sound: nil)
        }
        // A stack, so the hidden face takes no room: the card spans the row,
        // the button stands at its trailing end in a row of its own.
        locateButton.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(locateButton)
        let stack = UIStackView(arrangedSubviews: [card, buttonRow])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let margin = Spacing.lg
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            locateButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            locateButton.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            locateButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            locateButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            locateButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        apply(.none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ face: Face) {
        self.face = face
        switch face {
        case .none:
            card.isHidden = true
            buttonRow.isHidden = true
            card.isEnabled = false
            locateButton.isEnabled = false
        case .card(let permission):
            card.isHidden = false
            buttonRow.isHidden = true
            card.isEnabled = true
            locateButton.isEnabled = false
            var title = AttributedString("See posts around you")
            title.font = .appFont(forTextStyle: .headline)
            card.configuration?.attributedTitle = title
            card.configuration?.subtitle = permission == .denied
                ? "Location is off. Turn it on in Settings to open the country you're in."
                : "Allow location to open the country you're in."
            card.configuration?.image = UIImage(
                systemName: permission == .denied ? "location.slash" : "location.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            )
            card.accessibilityHint = permission == .denied ? "Opens Settings" : nil
        case .button(let permission):
            card.isHidden = true
            buttonRow.isHidden = false
            card.isEnabled = false
            locateButton.isEnabled = true
            locateButton.configuration?.image = UIImage(
                systemName: permission == .allowed ? "location.fill" : "location",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            )
            locateButton.accessibilityLabel = permission == .allowed
                ? "Go to the country you're in" : "Use your location"
            locateButton.accessibilityHint = permission == .denied ? "Opens Settings" : nil
        }
        isHidden = face == .none
    }

    private func tapped() {
        switch face {
        case .none: break
        case .card(let permission), .button(let permission): onTap?(permission)
        }
    }

    /// Only the controls take touches; the rest of the row — the stack and
    /// the button's row included — is the map's.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event),
              hit.isDescendant(of: card) || hit.isDescendant(of: locateButton) else { return nil }
        return hit
    }
}

