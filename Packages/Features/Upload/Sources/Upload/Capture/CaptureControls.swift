import DesignSystem
import UIKit

/// A row of glass pills, one chosen — the band tenant for flash, timer and
/// ratio.
///
/// ⚠️ **PILLS, NOT CARDS.** These are three words each, not pictures; a card
/// with nothing to show is a pill with a larger hit area and an emptier face.
/// The filter row, which has pictures, is the editor's own
/// (`MediaFilterRowView`).
///
/// ⚠️ **THE CHOSEN PILL IS FILLED WHITE WITH BLACK INK** — the selection
/// colour the editor's cards use — and the others are clear glass, so the
/// choice reads over any picture behind.
@MainActor
final class CaptureChoiceRowView<Choice: Equatable>: UIView, PoppingTenant {
    var onPick: ((Choice) -> Void)?

    private let row = UIStackView()
    private var buttons: [(choice: Choice, button: UIButton)] = []
    private(set) var chosen: Choice

    static var height: CGFloat { 44 }

    /// `spoken` is what VoiceOver says for a choice, where its label would be
    /// read wrongly — "9:16" is read as a time of day.
    init(
        choices: [Choice], chosen: Choice, label: (Choice) -> String,
        spoken: ((Choice) -> String)? = nil, symbol: ((Choice) -> String?)? = nil
    ) {
        self.chosen = chosen
        super.init(frame: .zero)
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.distribution = .equalSpacing
        row.constrain(in: self) { view in
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            row.topAnchor.constraint(equalTo: view.topAnchor)
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            row.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.lg)
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        for choice in choices {
            let button = UIButton(configuration: .glass())
            button.configuration?.title = label(choice)
            // Survives `dress()`, which replaces the configuration and traits.
            button.accessibilityLabel = spoken?(choice)
            if let name = symbol?(choice) {
                button.configuration?.image = UIImage(systemName: name)
                button.configuration?.imagePadding = Spacing.xs
                button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            }
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 15, weight: .semibold)
                return attributes
            }
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            button.addAction(UIAction { [weak self] _ in self?.pick(choice) }, for: .primaryActionTriggered)
            row.addArrangedSubview(button)
            buttons.append((choice, button))
        }
        dress()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var poppableElements: [UIView] { buttons.map(\.button) }

    func setChosen(_ choice: Choice) {
        chosen = choice
        dress()
    }

    private func pick(_ choice: Choice) {
        guard choice != chosen else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        setChosen(choice)
        onPick?(choice)
    }

    private func dress() {
        for (choice, button) in buttons {
            let isChosen = choice == chosen
            var configuration: UIButton.Configuration = isChosen ? .prominentGlass() : .glass()
            configuration.title = button.configuration?.title
            configuration.image = button.configuration?.image
            configuration.imagePadding = button.configuration?.imagePadding ?? 0
            configuration.preferredSymbolConfigurationForImage = button.configuration?.preferredSymbolConfigurationForImage
            configuration.titleTextAttributesTransformer = button.configuration?.titleTextAttributesTransformer
            configuration.contentInsets = button.configuration?.contentInsets ?? .zero
            configuration.baseBackgroundColor = isChosen ? .white : nil
            configuration.baseForegroundColor = isChosen ? .black : .white
            button.configuration = configuration
            button.accessibilityTraits = isChosen ? [.button, .selected] : [.button]
        }
    }

    /// Internal for tests.
    func debugPick(_ choice: Choice) { pick(choice) }
    var debugTitles: [String] { buttons.compactMap { $0.button.configuration?.title } }
    var debugSpoken: [String?] { buttons.map(\.button.accessibilityLabel) }
}

/// The lens stops over the shutter — "0.5  1×  2  3" — the chosen one wearing
/// the live zoom ("1.4×"), the way the system Camera spells it.
@MainActor
final class CaptureLensChipsView: UIView {
    var onPick: ((CaptureLens) -> Void)?

    private let row = UIStackView()
    private var lenses: [CaptureLens] = []
    private var buttons: [UIButton] = []
    private(set) var zoom: CGFloat = 1

    static let side: CGFloat = 38

    init() {
        super.init(frame: .zero)
        row.axis = .horizontal
        row.spacing = Spacing.xs
        row.alignment = .center
        row.pin(to: self)
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setLenses(_ lenses: [CaptureLens], zoom: CGFloat) {
        if lenses != self.lenses {
            self.lenses = lenses
            buttons.forEach { $0.removeFromSuperview() }
            buttons = lenses.map { lens in
                let button = UIButton(configuration: .glass())
                button.addAction(UIAction { [weak self] _ in self?.onPick?(lens) }, for: .primaryActionTriggered)
                button.widthAnchor.constraint(equalToConstant: Self.side).isActive = true
                button.heightAnchor.constraint(equalToConstant: Self.side).isActive = true
                row.addArrangedSubview(button)
                return button
            }
            // One stop is no choice at all — the front camera, usually.
            isHidden = lenses.count < 2
        }
        setZoom(zoom)
    }

    /// The stop the zoom is AT: the highest one at or below it.
    static func activeIndex(for zoom: CGFloat, in lenses: [CaptureLens]) -> Int? {
        lenses.lastIndex { $0.factor <= zoom + 0.01 } ?? (lenses.isEmpty ? nil : 0)
    }

    func setZoom(_ zoom: CGFloat) {
        self.zoom = zoom
        let active = Self.activeIndex(for: zoom, in: lenses)
        for (index, button) in buttons.enumerated() {
            let lens = lenses[index]
            let isActive = index == active
            var title = lens.label
            if isActive {
                let shown = (zoom * 10).rounded() / 10
                title = (shown == shown.rounded() ? "\(Int(shown))" : String(format: "%.1f", shown)) + "×"
            }
            var configuration = UIButton.Configuration.glass()
            configuration.title = title
            configuration.contentInsets = .zero
            configuration.baseForegroundColor = isActive ? .systemYellow : .white
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: isActive ? 13 : 12, weight: .bold)
                return attributes
            }
            button.configuration = configuration
            button.accessibilityLabel = "Zoom \(lens.label)"
            button.accessibilityTraits = isActive ? [.button, .selected] : [.button]
        }
    }

    var debugTitles: [String] { buttons.compactMap { $0.configuration?.title } }
    func debugTap(_ index: Int) { onPick?(lenses[index]) }
}

/// The rule of thirds, inside the ratio's window.
@MainActor
final class CaptureGridView: UIView {
    private let lines = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        lines.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
        lines.lineWidth = 1 / max(1, traitCollection.displayScale)
        lines.fillColor = nil
        layer.addSublayer(lines)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        lines.frame = bounds
        let path = UIBezierPath()
        for third in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: bounds.width * third, y: 0))
            path.addLine(to: CGPoint(x: bounds.width * third, y: bounds.height))
            path.move(to: CGPoint(x: 0, y: bounds.height * third))
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height * third))
        }
        lines.path = path.cgPath
    }
}

/// What stands in the preview when there is no camera to show: refused —
/// with the one place that can change it — or not there at all.
@MainActor
final class CaptureAccessNoticeView: UIView {
    enum Kind: Equatable {
        /// Camera access is off; Settings can turn it back on.
        case denied
        /// There is no camera. Nothing to open, so no button to open it.
        case unavailable
    }

    var onOpenSettings: (() -> Void)?
    let kind: Kind
    private let title = UILabel()
    private let body = UILabel()
    private var button: UIButton?

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: kind == .denied ? "camera.fill" : "video.slash.fill"))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        title.text = kind == .denied ? "Camera access is off" : "No camera available"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        body.text = kind == .denied
            ? "Allow the camera in Settings to take photos and record videos for your posts."
            : "This device has no camera to take photos or record videos with. You can still post from your library."
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textColor = .secondaryLabel
        body.numberOfLines = 0
        body.textAlignment = .center
        body.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [icon, title, body])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.md
        if kind == .denied {
            var configuration = UIButton.Configuration.prominentGlass()
            configuration.title = "Open Settings"
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.onOpenSettings?()
            })
            stack.setCustomSpacing(Spacing.xl, after: body)
            stack.addArrangedSubview(button)
            self.button = button
        }
        stack.constrain(in: self) { view in
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.xl)
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.xl)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Internal for tests.
    var debugTitle: String? { title.text }
    var debugOffersSettings: Bool { button != nil }
}
