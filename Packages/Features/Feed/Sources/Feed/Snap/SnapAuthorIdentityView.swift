import MediaCore
import CoreModels
import DesignSystem
import UIKit

/// The author identity (avatar + name/meta) hosted as the navigation bar's
/// *trailing* bar item custom view (right-aligned, mirroring system floating
/// actions). The bar never hides or transforms it during a hero flight — the
/// card flies beneath the real, static bar.
///
/// Content-hugging by design: the view sizes itself to its content (zero
/// horizontal padding), so the system glass pill the bar draws around it
/// wraps the avatar and text exactly. A hard width cap keeps long display
/// names truncating instead of crowding the bar; the trade-off, accepted for
/// the flush-pill look, is that an author change re-negotiates the item's
/// size — a settle-time event, never mid-scroll.
final class SnapAuthorIdentityView: UIView {
    /// Matches the bar's standard control height.
    private static let height: CGFloat = 40
    /// The fixed height of the bar's own item wrapper on iOS 26 — the box the
    /// avatar centers in (see the breathing math at the row constraints).
    private static let barItemWrapperHeight: CGFloat = 36
    /// Long display names truncate here rather than crowding the back item.
    private static let maxWidth: CGFloat = 220
    /// The unhydrated (cold-tap) floor: the pill opens at a plausible
    /// footprint instead of a nub, so hydration is a small glide, not a pop.
    private static let minWidth: CGFloat = 150

    /// Called when the identity is tapped, with the shown author.
    var onAuthorTapped: ((ProfileID) -> Void)?
    /// Called when the follow icon is tapped, with the shown author.
    var onFollowTapped: ((ProfileID) -> Void)?

    private let avatarView = AvatarImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let followButton = UIButton(configuration: .plain())
    /// Redacted stand-ins shown where the labels will be until the first
    /// author hydrates (cold tap) — the system placeholder idiom, resolved
    /// through the same cross-fade that swaps authors.
    private let namePlaceholder = SnapAuthorIdentityView.makeRedactionBar(width: 96, height: 12)
    private let metaPlaceholder = SnapAuthorIdentityView.makeRedactionBar(width: 64, height: 9)
    private let labelsStack = UIStackView()

    private var authorID: ProfileID?
    private var avatarTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)

        // Size and circle geometry come from the shared component: the same
        // diameter as the Maps toolbar's profile avatar, and a radius bound
        // to the bounds each layout pass — a perfect circle by construction.
        avatarView.backgroundColor = .darkGray
        avatarView.widthAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true

        nameLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        nameLabel.textColor = .white
        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.75)

        // The bar is transparent over arbitrary media; shadows keep the
        // identity legible without a background.
        for label in [nameLabel, metaLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        var followConfig = UIButton.Configuration.plain()
        followConfig.image = UIImage(systemName: "plus")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        followConfig.baseForegroundColor = .white
        followConfig.contentInsets = .zero
        followButton.configuration = followConfig
        followButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.authorID else { return }
            self?.onFollowTapped?(id)
        }, for: .primaryActionTriggered)

        for view in [nameLabel, namePlaceholder, metaLabel, metaPlaceholder] {
            labelsStack.addArrangedSubview(view)
        }
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        setRedacted(true)

        let row = UIStackView(arrangedSubviews: [avatarView, labelsStack, followButton])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        // The row is edge-pinned, so any width the pill has beyond (or short
        // of) natural content must be absorbed by exactly one member — and at
        // UIKit's defaults the button and the labels stack TIE (hugging
        // 250/250, compression 750/750), letting the solver deform an
        // arbitrary one per pass: the "+" visibly dances during early bar
        // passes and the hydration glide. Make the button rigid, and make the
        // labels area the designated absorber — its content is leading-aligned,
        // so a stretched frame just gains invisible trailing space.
        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        // Interaction stays on: the follow button consumes its own taps (a
        // control descendant defeats the container's gesture), while taps on
        // the avatar/labels fall through to the container's author tap.
        // The avatar's leading inset matches its vertical breathing exactly:
        // the bar's item wrapper renders 36pt tall and the avatar is
        // vertically centered, so the same computed gap on the left keeps it
        // uniform on all three sides whatever the shared diameter is. A
        // slightly larger trailing inset gives the follow glyph room against
        // the pill's rounded end. The bar self-sizes custom views through
        // Auto Layout; the height pin and width cap are the only external
        // metrics.
        let avatarBreathing = (Self.barItemWrapperHeight - AvatarImageView.barDiameter) / 2
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: avatarBreathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.sm)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, not required: the bar wraps items in its own fixed-height
        // container (36pt on iOS 26) via autoresizing constraints; a required
        // height fights it and UIKit breaks ours at runtime with a console
        // warning. Yield to the wrapper — the content row centers regardless.
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true
        // The floor only binds while content is narrower than it (the redacted
        // cold state); real name+meta content exceeds it, keeping the flush
        // pill. 999 so it can never fight the bar's own constraints.
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)
        minWidth.priority = UILayoutPriority(999)
        minWidth.isActive = true

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `model`'s author. A change of author cross-fades the container
    /// and reloads the avatar (guarded against fast page-past); paging between
    /// posts by the same author only refreshes the per-post meta line, with no
    /// fade. The view is content-sized, so a new author re-negotiates the bar
    /// item's width — a settle-time event by construction.
    func setAuthor(_ model: FeedItemDisplayModel, pipeline: ImagePipeline) {
        let changed = model.authorID != authorID
        authorID = model.authorID
        guard changed else {
            metaLabel.text = model.metaText
            return
        }
        defer { animateBarRemeasure() }

        UIView.transition(with: self, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.setRedacted(false)
            self.nameLabel.text = model.authorName
            self.metaLabel.text = model.metaText
            self.avatarView.image = nil
        }

        avatarTask?.cancel()
        guard let url = model.avatarURL else { return }
        let id = model.authorID
        avatarTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.authorID == id else { return }
            UIView.transition(with: self.avatarView, duration: 0.15, options: [.transitionCrossDissolve]) {
                self.avatarView.image = image
            }
        }
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    /// Swaps the label area between redacted stand-ins and the real labels.
    /// The stand-in bars need a gap of their own; label line-heights carry it
    /// once hydrated.
    private func setRedacted(_ redacted: Bool) {
        nameLabel.isHidden = redacted
        metaLabel.isHidden = redacted
        namePlaceholder.isHidden = !redacted
        metaPlaceholder.isHidden = !redacted
        labelsStack.spacing = redacted ? 5 : 0
    }

    /// Content changes resize the pill (content-sized by design). A snap here
    /// is the one thing that reads as jank, so drive the bar's re-measure
    /// through a short eased layout pass: the pill glides between widths —
    /// hydration and author changes alike.
    private func animateBarRemeasure() {
        setNeedsLayout()
        var bar: UIView? = superview
        while let view = bar, !(view is UINavigationBar) { bar = view.superview }
        let host = bar ?? superview
        host?.setNeedsLayout()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            host?.layoutIfNeeded()
        }
    }

    private static func makeRedactionBar(width: CGFloat, height: CGFloat) -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        bar.layer.cornerRadius = height / 2
        bar.layer.cornerCurve = .continuous
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true
        bar.heightAnchor.constraint(equalToConstant: height).isActive = true
        return bar
    }
}

/// The snap feed's navigation-bar controls, built as *custom views* so their
/// on-screen frames are readable with public API (a system-styled
/// `UIBarButtonItem` exposes no view), and so the hero flight's stand-ins can
/// be second instances of the exact same controls — pixel-identical at the
/// landing swap by construction.
enum SnapNavControls {
    /// The back chevron for a presented (map-opened) feed; dismisses to the map.
    static func makeBackButton() -> UIButton {
        makeCircularBarButton(systemName: "chevron.backward", pointSize: 17)
    }

    /// A bottom-toolbar action (share, more): the same 36pt circle as the
    /// back button, hosted as a bar item custom view so the system glass
    /// wraps each action in its own isolated bubble — custom views never
    /// join a shared item background.
    static func makeToolbarActionButton(systemName: String) -> UIButton {
        makeCircularBarButton(systemName: systemName, pointSize: 15)
    }

    /// One symbol in a strict 1:1 box: symbol intrinsic sizes are asymmetric
    /// and the system glass pill wraps the custom view's bounds, which
    /// renders slightly oval without this. Both metrics are 999, never
    /// required: the bar's FIRST pass pins its item wrapper to the raw
    /// intrinsic size with autoresizing constraints, and anything required
    /// loses to that with a console break. 36 matches the wrapper's real
    /// item height, so the settled pill is an exact circle (a 40pt box
    /// would settle 40×36 — subtly oval).
    private static func makeCircularBarButton(systemName: String, pointSize: CGFloat) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        let height = button.heightAnchor.constraint(equalToConstant: 36)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        let aspect = button.widthAnchor.constraint(equalTo: button.heightAnchor)
        aspect.priority = UILayoutPriority(999)
        aspect.isActive = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
        return button
    }
}
