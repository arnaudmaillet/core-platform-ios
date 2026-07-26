import DesignSystem
import MediaCore
import UIKit

/// The share sheet's quick-send row: a horizontally scrolling strip of people
/// the viewer can send this profile to, avatar over name, led by a Search
/// bubble.
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
        /// How many placeholders the skeleton shows. Enough to fill the row on
        /// the widest phone, so the loading state doesn't read as "four
        /// results" and then grow.
        static let skeletonCount = 6
    }

    var onSelect: ((ProfileShareTarget) -> Void)?
    /// The leading Search bubble. Always present — including while loading, so
    /// the one action that works without data is reachable immediately.
    var onSearch: (() -> Void)?

    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private let imagePipeline: ImagePipeline?
    private var avatarTasks: [Task<Void, Never>] = []

    /// - Parameter inset: the host's horizontal margin. Applied as a CONTENT
    ///   inset rather than a frame inset, which is the whole point of the row:
    ///   the scroll view itself reaches the sheet's edges, so the first and
    ///   last avatars scroll in from under the rounded corners instead of
    ///   being clipped against a margin.
    init(imagePipeline: ImagePipeline?, inset: CGFloat) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        // Off, so an avatar isn't shaved at the row's bounds as it scrolls
        // past the edge.
        scrollView.clipsToBounds = false
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

    // MARK: - States

    /// Placeholders, shown from the first frame while the social graph is read.
    ///
    /// The row is never empty and never changes height, so the sheet's detent
    /// is settled before the data lands — the alternative (hiding the row until
    /// it fills) made the sheet grow under the user a beat after it opened.
    /// - Parameter leadingSearch: false while the sheet is already in search,
    ///   where a Search bubble would be a button back to where you are.
    func renderSkeletons(leadingSearch: Bool = true) {
        reset()
        if leadingSearch { row.addArrangedSubview(makeSearchItem()) }
        for _ in 0..<Metrics.skeletonCount {
            row.addArrangedSubview(makeSkeletonItem())
        }
    }

    func render(_ targets: [ProfileShareTarget], leadingSearch: Bool = true) {
        reset()
        if leadingSearch { row.addArrangedSubview(makeSearchItem()) }
        for target in targets {
            row.addArrangedSubview(makeItem(for: target))
        }
    }

    private func reset() {
        avatarTasks.forEach { $0.cancel() }
        avatarTasks = []
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: - Items

    /// Search leads the row rather than trailing it: it is the only entry that
    /// reaches someone the graph didn't suggest, and it has to be findable
    /// without scrolling past a dozen faces to reach it.
    private func makeSearchItem() -> UIView {
        // Filled, not `.glass()`. Glass on a glass sheet has nothing distinct
        // to refract and renders as a bare glyph with no bubble at all —
        // verified here exactly as it was on the action chips. The neutral
        // fill also sits correctly beside the opaque avatars it leads.
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        )
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        // Opaque for the reason the rest of this sheet documents: semantic
        // colours resolve translucent inside an iOS 26 sheet.
        configuration.baseBackgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(1)
        configuration.baseForegroundColor = .label
        let bubble = UIButton(configuration: configuration)
        bubble.isUserInteractionEnabled = false

        NSLayoutConstraint.activate([
            bubble.widthAnchor.constraint(equalToConstant: Metrics.avatarDiameter),
            bubble.heightAnchor.constraint(equalToConstant: Metrics.avatarDiameter)
        ])
        return makeColumnItem(
            top: bubble,
            title: "Search",
            accessibilityLabel: "Search profiles",
            action: { [weak self] in self?.onSearch?() }
        )
    }

    private func makeSkeletonItem() -> UIView {
        // `.fixed(r)`, not `.capsule`: capsule derives its radius in
        // `layoutSubviews` from the resolved height, and these bones render
        // square in the row's first frames. The diameter is a constant here,
        // so the radius can be stated up front and applied in the initializer.
        let bone = SkeletonBoneView(rounding: .fixed(Metrics.avatarDiameter / 2))
        let name = SkeletonBoneView(rounding: .fixed(4.5))
        // A stand-in for the caption's ink, not its box: sized to a plausible
        // first name so the row's rhythm survives the swap to real data.
        NSLayoutConstraint.activate([
            name.heightAnchor.constraint(equalToConstant: 9),
            name.widthAnchor.constraint(equalToConstant: 40)
        ])
        let column = UIStackView(arrangedSubviews: [bone, name])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm
        column.isUserInteractionEnabled = false

        let container = UIView()
        column.pin(to: container)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Metrics.itemWidth),
            bone.widthAnchor.constraint(equalToConstant: Metrics.avatarDiameter),
            bone.heightAnchor.constraint(equalToConstant: Metrics.avatarDiameter)
        ])
        return container
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
        NSLayoutConstraint.activate([
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

        return makeColumnItem(
            // First name only: at 72pt a full name truncates to nothing
            // readable, and the row is for recognition, not identification.
            top: well,
            title: target.displayName.split(separator: " ").first.map(String.init) ?? target.handle,
            accessibilityLabel: "Send to \(target.displayName)",
            action: { [weak self] in self?.onSelect?(target) }
        )
    }

    /// The shared shape of every live item: something round on top, a caption
    /// under it, and a button over the whole column so the caption is as
    /// tappable as the circle.
    private func makeColumnItem(
        top: UIView, title: String, accessibilityLabel: String, action: @escaping () -> Void
    ) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .preferredFont(forTextStyle: .caption1)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.textAlignment = .center
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail

        let column = UIStackView(arrangedSubviews: [top, name])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.sm
        column.isUserInteractionEnabled = false

        let button = UIButton(type: .system)
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.configurationUpdateHandler = { [weak column] button in
            column?.alpha = button.isHighlighted ? 0.55 : 1
        }
        column.pin(to: button)
        button.widthAnchor.constraint(equalToConstant: Metrics.itemWidth).isActive = true
        return button
    }
}
