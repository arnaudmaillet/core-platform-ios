import DesignSystem
import MediaCore
import UIKit

/// The share card: a QR code of the profile's link with the profile's avatar
/// punched into its centre, over the display name and @handle.
///
/// **Deliberately opaque and deliberately always light**, in a design system
/// otherwise built on Liquid Glass. Two reasons, both about the one job this
/// view has:
/// - A QR code has to be high-contrast dark-on-light to scan. Rendered on a
///   translucent material it composites against whatever moves behind it, and
///   in dark mode it inverts into something many scanners reject outright.
/// - The card is also rasterized and shared (`ProfileShareCard`), where it
///   lands on a stranger's screen with no backdrop to refract. A material that
///   samples its surroundings has nothing to sample there.
///
/// So the card fixes `overrideUserInterfaceStyle = .light` and paints a solid
/// background. The glass in this feature lives on the action chips beside it,
/// where it is chrome rather than payload.
final class ProfileQRCardView: UIView {
    private enum Metrics {
        /// Floor for the corner radius, for hosts that don't supply one.
        static let minimumCornerRadius: CGFloat = 20
        /// Padding between the card edge and the QR — doubles as the code's
        /// quiet zone, which the spec wants at four modules and the generator
        /// only partly supplies. It is also the inset the QR well's own radius
        /// is derived from, so the three curves stay concentric.
        static let quietZone: CGFloat = 20
        /// The avatar's diameter as a fraction of the QR's side. A circle this
        /// size occludes ~6% of the code's area — comfortably inside error
        /// correction level H's ~30% budget, so the code still decodes with
        /// the avatar on top (asserted in `ProfileQRCodeTests`).
        static let avatarFraction: CGFloat = 0.22
        /// The white ring punched around the avatar, so the modules never
        /// touch it and the centre reads as intentional rather than damaged.
        static let avatarPunchFraction: CGFloat = 0.28
    }

    /// A LITERAL colour, not `.secondarySystemBackground`.
    ///
    /// Verified in-sim: inside an iOS 26 sheet the semantic background colours
    /// resolve *translucent*, so the card sampled two different greys over two
    /// different parts of the profile behind it. Harmless-looking on screen,
    /// but fatal to `ProfileShareCard`, which renders into an opaque context —
    /// a translucent background composites there against black. A card that is
    /// shared as an image cannot borrow its colour from its surroundings.
    /// (This is light-mode `secondarySystemBackground`'s own value.)
    private static let cardBackground = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    private let qrImageView = UIImageView()
    private let punchView = UIView()
    private let avatarView = AvatarImageView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()

    private let imagePipeline: ImagePipeline?
    private var avatarTask: Task<Void, Never>?
    /// The in-flight QR render, so a re-layout cannot queue a second one.
    private var renderTask: Task<Void, Never>?
    private var renderedURL: URL?
    private var renderedSide: CGFloat = 0

    init(imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        super.init(frame: .zero)
        // The whole point of the card: it does not follow the appearance.
        overrideUserInterfaceStyle = .light
        backgroundColor = Self.cardBackground
        isOpaque = true
        // A concrete radius, seeded here and corrected by the host once it
        // knows the sheet's own (see `setCornerRadius`). `containerConcentric`
        // was tried first and is the wrong tool: it resolves against a
        // *superview's* corner configuration, and the sheet's radius belongs to
        // its presentation controller, not to any view in this hierarchy — so
        // it silently fell back to the minimum and the curves never agreed.
        setCornerRadius(Metrics.minimumCornerRadius)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        avatarTask?.cancel()
        renderTask?.cancel()
    }

    private func configureSubviews() {
        qrImageView.contentMode = .scaleAspectFit
        // Nearest-neighbour, so a code scaled by the sheet's rubber-band keeps
        // hard module edges instead of blurring into something unscannable.
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.layer.minificationFilter = .trilinear
        qrImageView.backgroundColor = .white
        qrImageView.clipsToBounds = true
        // The code is a link, and VoiceOver users cannot scan it — the label
        // says what it is, and the actions below are the accessible path.
        qrImageView.isAccessibilityElement = true
        qrImageView.accessibilityLabel = "QR code for this profile"

        punchView.backgroundColor = .white

        avatarView.backgroundColor = .systemGray5
        // The monogram backs the avatar until (or unless) the image resolves,
        // so the centre is never an empty hole in the middle of the code.
        monogramLabel.textAlignment = .center
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.adjustsFontSizeToFitWidth = true
        monogramLabel.minimumScaleFactor = 0.5

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1

        handleLabel.font = .preferredFont(forTextStyle: .subheadline)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = .secondaryLabel
        handleLabel.textAlignment = .center
        handleLabel.numberOfLines = 1

        let identity = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        identity.axis = .vertical
        identity.alignment = .fill
        identity.spacing = 2
        // The card's height is quiet zone + code + identity, and the identity
        // block is the only part of it a shortfall could squeeze — a label's
        // default vertical compression resistance is only 750. Raised to
        // required, the card has no give at all, so a sheet drag can translate
        // it but never re-proportion it.
        for view in [nameLabel, handleLabel, identity] {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        qrImageView.constrain(in: self) { parent in
            qrImageView.topAnchor.constraint(equalTo: parent.topAnchor, constant: Metrics.quietZone)
            qrImageView.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.quietZone)
            qrImageView.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.quietZone)
            qrImageView.heightAnchor.constraint(equalTo: qrImageView.widthAnchor)
        }
        identity.constrain(in: self) { parent in
            identity.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: Spacing.lg)
            identity.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Metrics.quietZone)
            identity.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Metrics.quietZone)
            identity.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Metrics.quietZone)
        }
        // Punch and avatar are centred on the CODE, not the card — the
        // identity block below would otherwise drag the centre downward.
        punchView.constrain(in: self) { _ in
            punchView.centerXAnchor.constraint(equalTo: qrImageView.centerXAnchor)
            punchView.centerYAnchor.constraint(equalTo: qrImageView.centerYAnchor)
            punchView.widthAnchor.constraint(equalTo: qrImageView.widthAnchor, multiplier: Metrics.avatarPunchFraction)
            punchView.heightAnchor.constraint(equalTo: punchView.widthAnchor)
        }
        avatarView.constrain(in: self) { _ in
            avatarView.centerXAnchor.constraint(equalTo: qrImageView.centerXAnchor)
            avatarView.centerYAnchor.constraint(equalTo: qrImageView.centerYAnchor)
            avatarView.widthAnchor.constraint(equalTo: qrImageView.widthAnchor, multiplier: Metrics.avatarFraction)
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor)
        }
        monogramLabel.constrain(in: self) { _ in
            monogramLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor)
            monogramLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor)
            monogramLabel.widthAnchor.constraint(equalTo: avatarView.widthAnchor, multiplier: 0.8)
        }
        // Monogram under the image, both above the punch.
        bringSubviewToFront(monogramLabel)
        bringSubviewToFront(avatarView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        punchView.layer.cornerRadius = punchView.bounds.width / 2
        monogramLabel.font = .systemFont(ofSize: max(avatarView.bounds.width * 0.38, 8), weight: .semibold)
        renderCodeIfNeeded()
    }

    // MARK: - Configuration

    /// Rounds the card to `radius`, and the QR well inside it to
    /// `radius - quietZone` — the concentric rule applied one level down, so
    /// all three curves (sheet, card, code) stay parallel at their insets.
    ///
    /// The host passes `sheetRadius - outerPadding`; this method only has to
    /// keep the card's own children in step with whatever it is given.
    func setCornerRadius(_ radius: CGFloat) {
        cornerConfiguration = .corners(radius: .fixed(radius))
        qrImageView.cornerConfiguration = .corners(
            radius: .fixed(max(radius - Metrics.quietZone, 4))
        )
    }

    func configure(with card: ProfileViewModel.ShareCard) {
        nameLabel.text = card.displayName
        handleLabel.text = card.handle
        monogramLabel.text = Self.monogram(for: card.displayName)
        renderedURL = card.url
        // Force a re-render: the payload changed even if the side did not.
        renderedSide = 0
        qrImageView.image = nil
        setNeedsLayout()
        loadAvatar(card.avatarURL)
    }

    /// The QR is generated at the resolved pixel size rather than a guessed
    /// one, and only when that size actually changes — regenerating on every
    /// layout pass would re-run CoreImage during the sheet's entrance.
    /// Rasterizes the code ONCE, at the first size the layout resolves, and
    /// never again for that URL.
    ///
    /// ⚠️ It used to regenerate whenever the resolved width changed, which is
    /// every frame of a sheet drag: UIKit rubber-bands a sheet dragged below
    /// its detent by genuinely NARROWING it, so the card re-lays-out
    /// continuously and CoreImage was re-run under the user's thumb — the
    /// visible "resizing" artifact, and expensive enough to cost frames.
    ///
    /// The image view scales the finished bitmap instead (`.scaleAspectFit`
    /// with nearest-neighbour magnification, so module edges stay hard however
    /// far the rubber-band stretches it). A QR is a bitmap of hard-edged
    /// squares; there is nothing to gain by re-rendering it at every
    /// intermediate size.
    /// Renders the code OFF the main thread and applies it when it lands.
    ///
    /// ⚠️ **This used to be synchronous, and it was what made the share sheet
    /// slow to open.** `makeImage` runs a CoreImage filter and a bitmap pass,
    /// and it stood up a fresh `CIContext` each time; called from
    /// `viewDidLoad`, all of that sat on the main thread between the tap and
    /// the first frame. Nothing about a QR needs to be on the main thread —
    /// only the assignment does.
    ///
    /// The guard still runs on the main actor, so the "already rendered" and
    /// "no size yet" cases cost nothing and no duplicate render is scheduled.
    /// Renders the code on THIS thread, now, if it has not landed yet.
    ///
    /// ⚠️ **The export path needs this and cannot wait.** `ProfileShareCard`
    /// snapshots the card into a bitmap synchronously; with only the async
    /// path, sharing produced a card with a blank centre — the code arrived
    /// after the snapshot had already been taken. On-screen display stays
    /// async (that is what keeps the sheet quick to open); export opts back in.
    func renderCodeNow() {
        renderTask?.cancel()
        renderTask = nil
        let side = qrImageView.bounds.width.rounded()
        guard side > 0, let url = renderedURL, qrImageView.image == nil else { return }
        renderedSide = side
        qrImageView.image = ProfileQRCode.makeImage(
            for: url, side: side, scale: traitCollection.displayScale
        )
    }

    private func renderCodeIfNeeded() {
        let side = qrImageView.bounds.width.rounded()
        guard side > 0, let url = renderedURL, qrImageView.image == nil,
              renderTask == nil
        else { return }
        renderedSide = side
        let scale = traitCollection.displayScale
        renderTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ProfileQRCode.makeImage(for: url, side: side, scale: scale)
            }.value
            guard let self, !Task.isCancelled, self.renderedURL == url else { return }
            self.qrImageView.image = image
            self.renderTask = nil
        }
    }

    private func loadAvatar(_ url: URL?) {
        avatarTask?.cancel()
        avatarView.image = nil
        guard let url, let imagePipeline else { return }
        avatarTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled else { return }
            self.avatarView.image = image
        }
    }

    private static func monogram(for displayName: String) -> String {
        let initials = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        return initials.joined().uppercased()
    }
}
