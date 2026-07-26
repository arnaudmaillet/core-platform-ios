import DesignSystem
import MediaCore
import UIKit

/// The share sheet's quick-send row: a horizontally scrolling strip of people
/// the viewer can send this profile to, avatar over name.
///
/// A scroll view over a stack, not a collection view: the row is capped at a
/// dozen items that are all built at once, so a collection view's recycling
/// would be machinery with nothing to recycle.
final class ProfileShareTargetsView: UIView {
    private enum Metrics {
        static let avatarDiameter: CGFloat = 56
        static let itemWidth: CGFloat = 72
        /// Fixed so the sheet's detent is stable: the row reserves its height
        /// before the targets land, and an async arrival fills it in rather
        /// than resizing the sheet under the user's thumb.
        static let height: CGFloat = 92
    }

    var onSelect: ((ProfileShareTarget) -> Void)?

    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private let imagePipeline: ImagePipeline?
    private var avatarTasks: [Task<Void, Never>] = []

    init(imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // The strip runs edge to edge and scrolls its content in from the
        // margin, so items can pass under the sheet's rounded corners rather
        // than stopping short of them.
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Spacing.xs, bottom: 0, right: Spacing.xs)
        scrollView.pin(to: self)

        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Spacing.md
        row.constrain(in: scrollView) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            row.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        }
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { avatarTasks.forEach { $0.cancel() } }

    func render(_ targets: [ProfileShareTarget]) {
        avatarTasks.forEach { $0.cancel() }
        avatarTasks = []
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for target in targets {
            row.addArrangedSubview(makeItem(for: target))
        }
        // An empty row is hidden outright rather than left as a gap: the sheet
        // re-measures and the detent tightens around what is actually there.
        isHidden = targets.isEmpty
    }

    private func makeItem(for target: ProfileShareTarget) -> UIView {
        let avatar = AvatarImageView()
        avatar.backgroundColor = .tertiarySystemFill
        avatar.isUserInteractionEnabled = false

        let monogram = UILabel()
        monogram.text = target.displayName.first.map { String($0).uppercased() } ?? "?"
        monogram.font = .systemFont(ofSize: 22, weight: .semibold)
        monogram.textColor = .secondaryLabel
        monogram.textAlignment = .center

        let well = UIView()
        monogram.pin(to: well)
        avatar.pin(to: well)

        let name = UILabel()
        // First name only: at 72pt a full name truncates to nothing readable,
        // and the row is for recognition, not identification.
        name.text = target.displayName.split(separator: " ").first.map(String.init) ?? target.handle
        name.font = .preferredFont(forTextStyle: .caption1)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.textAlignment = .center
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail

        let column = UIStackView(arrangedSubviews: [well, name])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm

        let button = UIButton(type: .system)
        button.accessibilityLabel = "Send to \(target.displayName)"
        button.addAction(
            UIAction { [weak self] _ in self?.onSelect?(target) }, for: .primaryActionTriggered
        )
        // The column is decoration; the button over it is the whole hit target.
        column.isUserInteractionEnabled = false
        column.pin(to: button)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.itemWidth),
            well.widthAnchor.constraint(equalToConstant: Metrics.avatarDiameter),
            well.heightAnchor.constraint(equalToConstant: Metrics.avatarDiameter)
        ])

        if let url = target.avatarURL, let imagePipeline {
            avatarTasks.append(Task { [weak avatar] in
                guard let image = try? await imagePipeline.image(for: url) else { return }
                guard !Task.isCancelled else { return }
                avatar.map { $0.image = image }
            })
        }
        return button
    }
}
