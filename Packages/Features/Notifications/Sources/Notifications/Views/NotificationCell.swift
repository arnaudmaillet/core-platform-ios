import DesignSystem
import MediaCore
import UIKit

/// One notification: who (one face, or two stacked for a row with several
/// senders, wearing a small badge that says what kind of thing happened), the
/// sentence with its time, what it was about — a text post's opening under the
/// sentence, a media post's still at the trailing edge.
///
/// No separators and no unread tint: rows are set apart by air, and whether a
/// row is new is said by the SECTION it is in (`NotificationSection`).
///
/// Pictures follow the app's avatar contract (`avatar-rendering-contract`):
/// the initials are the rendered state, the picture dissolves in over them when
/// it arrives, and every fetch is guarded by what the cell shows NOW — a
/// recycled cell never takes a picture meant for the row it used to be.
final class NotificationCell: UICollectionViewListCell {
    enum Metrics {
        /// The avatar area: one 44pt face, or two 32pt faces overlapping.
        static let avatarArea: CGFloat = 44
        static let pairDiameter: CGFloat = 32
        static let badgeDiameter: CGFloat = 20
        /// The page-coloured ring that cuts a front face or the badge out of
        /// what is behind it.
        static let ring: CGFloat = 2
        static let thumbnailSide: CGFloat = 44
        static let thumbnailRadius: CGFloat = 10
        static let verticalPadding: CGFloat = 10
    }

    private let avatar = NotificationAvatarView()
    private let sentenceLabel = UILabel()
    private let excerptLabel = UILabel()
    private let thumbnailView = UIImageView()
    private lazy var textColumn = UIStackView(arrangedSubviews: [sentenceLabel, excerptLabel])

    private var imagePipeline: ImagePipeline?
    private var thumbnailURL: URL?
    private var thumbnailTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailURL = nil
        thumbnailView.image = nil
        avatar.prepareForReuse()
    }

    func configure(with model: NotificationDisplayModel, imagePipeline: ImagePipeline?) {
        self.imagePipeline = imagePipeline
        sentenceLabel.attributedText = Self.sentence(for: model)
        excerptLabel.text = model.excerpt
        excerptLabel.isHidden = model.excerpt == nil
        avatar.configure(faces: model.faces, action: model.action, imagePipeline: imagePipeline)
        loadThumbnail(model.thumbnailURL)
        accessibilityLabel = model.accessibilityText
    }

    /// "**Ava Moreau and 3 others** liked your post. 2h" — the people bold,
    /// the time quieter, one paragraph so it wraps as a sentence.
    static func sentence(for model: NotificationDisplayModel) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let semibold = UIFont(
            descriptor: body.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
            ]),
            size: 0
        )
        let text = NSMutableAttributedString(
            string: model.actorsText,
            attributes: [.font: semibold, .foregroundColor: UIColor.label]
        )
        text.append(NSAttributedString(
            string: " \(model.phrase)",
            attributes: [.font: body, .foregroundColor: UIColor.label]
        ))
        // A no-break space ties the time to the sentence's last word, so it is
        // never stranded alone on a line.
        text.append(NSAttributedString(
            string: "\u{00A0}· \(model.timeText)",
            attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]
        ))
        return text
    }

    private func loadThumbnail(_ url: URL?) {
        thumbnailView.isHidden = url == nil
        guard url != thumbnailURL || thumbnailView.image == nil else { return }
        thumbnailURL = url
        thumbnailTask?.cancel()
        thumbnailView.image = nil
        guard let url, let pipeline = imagePipeline else { return }
        thumbnailTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.thumbnailURL == url else { return }
            UIView.transition(
                with: self.thumbnailView, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.thumbnailView.image = image
            }
        }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        // No resting background: the row lies on the page. A press draws a
        // rounded wash inset from the edges — the list's only highlight.
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isHighlighted || state.isSelected ? .systemFill : .clear
        background.cornerRadius = 14
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)
        backgroundConfiguration = background
    }

    private func build() {
        sentenceLabel.numberOfLines = 3
        sentenceLabel.adjustsFontForContentSizeCategory = true
        excerptLabel.font = .preferredFont(forTextStyle: .subheadline)
        excerptLabel.adjustsFontForContentSizeCategory = true
        excerptLabel.textColor = .secondaryLabel
        excerptLabel.numberOfLines = 2

        textColumn.axis = .vertical
        textColumn.spacing = 2
        textColumn.alignment = .fill

        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = Metrics.thumbnailRadius
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = .tertiarySystemFill
        thumbnailView.isAccessibilityElement = false

        let row = UIStackView(arrangedSubviews: [avatar, textColumn, thumbnailView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Metrics.verticalPadding, leading: Spacing.lg,
            bottom: Metrics.verticalPadding, trailing: Spacing.lg
        ))
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Metrics.avatarArea),
            avatar.heightAnchor.constraint(equalToConstant: Metrics.avatarArea),
            thumbnailView.widthAnchor.constraint(equalToConstant: Metrics.thumbnailSide),
            thumbnailView.heightAnchor.constraint(equalToConstant: Metrics.thumbnailSide)
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

/// The row's avatar area: one face, or two overlapping (older behind, top
/// leading; most recent in front, bottom trailing), with the kind badge at the
/// bottom trailing corner.
final class NotificationAvatarView: UIView {
    private typealias Metrics = NotificationCell.Metrics

    private let singleFace = FaceView(diameter: Metrics.avatarArea, ring: 0)
    private let backFace = FaceView(diameter: Metrics.pairDiameter, ring: 0)
    private let frontFace = FaceView(diameter: Metrics.pairDiameter, ring: Metrics.ring)
    private let badge = KindBadgeView(diameter: Metrics.badgeDiameter, ring: Metrics.ring)

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        for view in [singleFace, backFace, frontFace, badge] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let badgeSide = Metrics.badgeDiameter + Metrics.ring * 2
        NSLayoutConstraint.activate([
            singleFace.centerXAnchor.constraint(equalTo: centerXAnchor),
            singleFace.centerYAnchor.constraint(equalTo: centerYAnchor),
            backFace.topAnchor.constraint(equalTo: topAnchor),
            backFace.leadingAnchor.constraint(equalTo: leadingAnchor),
            // The front face's RING overhangs the area by its width, so the
            // face itself lands flush with the bottom trailing corner.
            frontFace.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.ring),
            frontFace.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Metrics.ring),
            badge.widthAnchor.constraint(equalToConstant: badgeSide),
            badge.heightAnchor.constraint(equalToConstant: badgeSide),
            // Hangs a little off the corner, the way a badge sits on an icon.
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4 + Metrics.ring),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 4 + Metrics.ring)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func prepareForReuse() {
        [singleFace, backFace, frontFace].forEach { $0.prepareForReuse() }
    }

    func configure(
        faces: [NotificationDisplayModel.Face],
        action: NotificationItem.Action,
        imagePipeline: ImagePipeline?
    ) {
        let isPair = faces.count > 1
        singleFace.isHidden = isPair
        backFace.isHidden = !isPair
        frontFace.isHidden = !isPair
        if isPair {
            // The most recent sender is faces[0] and stands in front.
            frontFace.configure(faces[0], imagePipeline: imagePipeline)
            backFace.configure(faces[1], imagePipeline: imagePipeline)
        } else if let face = faces.first {
            singleFace.configure(face, imagePipeline: imagePipeline)
        }
        badge.configure(action)
    }
}

/// One face: the initials disc, the picture over it, and optionally a ring in
/// the page's colour that separates it from a face behind.
private final class FaceView: UIView {
    private let monogram: MonogramAvatarView
    private let picture = AvatarImageView()
    private let diameter: CGFloat
    private let ring: CGFloat
    private var avatarURL: URL?
    private var task: Task<Void, Never>?

    init(diameter: CGFloat, ring: CGFloat) {
        self.diameter = diameter
        self.ring = ring
        monogram = MonogramAvatarView(diameter: diameter)
        super.init(frame: .zero)
        backgroundColor = Surface.page
        layer.cornerRadius = diameter / 2 + ring
        layer.cornerCurve = .circular
        monogram.translatesAutoresizingMaskIntoConstraints = false
        addSubview(monogram)
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter + ring * 2),
            heightAnchor.constraint(equalTo: widthAnchor),
            monogram.centerXAnchor.constraint(equalTo: centerXAnchor),
            monogram.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: diameter),
            picture.heightAnchor.constraint(equalToConstant: diameter),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func prepareForReuse() {
        task?.cancel()
        task = nil
        avatarURL = nil
        picture.image = nil
        monogram.isCovered = false
    }

    func configure(_ face: NotificationDisplayModel.Face, imagePipeline: ImagePipeline?) {
        monogram.setMonogram(face.monogram)
        guard face.avatarURL != avatarURL || picture.image == nil else { return }
        avatarURL = face.avatarURL
        task?.cancel()
        picture.image = nil
        monogram.isCovered = false
        guard let url = face.avatarURL, let imagePipeline else { return }
        task = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.avatarURL == url else { return }
            UIView.transition(
                with: self.picture, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.picture.image = image
            } completion: { _ in
                // A covered disc draws nothing: an avatar is the picture alone.
                if self.avatarURL == url { self.monogram.isCovered = true }
            }
        }
    }
}

/// The small disc at the avatar's corner that says what happened — a heart
/// for a like, a bubble for a comment — so the kind reads before the sentence.
private final class KindBadgeView: UIView {
    private let glyph = UIImageView()
    private let disc = UIView()

    init(diameter: CGFloat, ring: CGFloat) {
        super.init(frame: .zero)
        backgroundColor = Surface.page
        layer.cornerRadius = diameter / 2 + ring
        disc.layer.cornerRadius = diameter / 2
        disc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disc)
        glyph.contentMode = .center
        glyph.tintColor = .white
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: diameter * 0.5, weight: .bold)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(glyph)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: diameter),
            disc.heightAnchor.constraint(equalToConstant: diameter),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor)
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ action: NotificationItem.Action) {
        let (symbol, colour) = Self.style(for: action)
        glyph.image = UIImage(systemName: symbol)
        disc.backgroundColor = colour
    }

    static func style(for action: NotificationItem.Action) -> (String, UIColor) {
        switch action {
        case .reaction: ("heart.fill", .systemRed)
        case .comment: (PostActionSymbol.commentsFilled, .systemBlue)
        case .reply: ("arrowshape.turn.up.left.fill", .systemGreen)
        case .mention: ("at", .systemIndigo)
        case .other: ("bell.fill", .systemGray)
        }
    }
}
