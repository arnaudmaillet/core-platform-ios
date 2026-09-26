import DesignSystem
import UIKit

/// The sound sheet's head: the artwork that plays and pauses the sound, what
/// the sound is, "Use this sound" and share, and the grid's title.
///
/// Laid out inside the section's side insets; the sheet measures its
/// collapsed detent from this view alone (`measureCollapsedHeight`).
final class SoundSheetHeaderView: UICollectionReusableView {
    static let artworkSide: CGFloat = 96
    private static let actionHeight: CGFloat = 48

    var onTogglePreview: (() -> Void)?
    var onUse: (() -> Void)?
    var onShare: (() -> Void)?

    private let artwork = UIImageView()
    private let playButton = UIButton(configuration: .glass())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let useButton = UIButton(configuration: .prominentGlass())
    private let shareButton = UIButton(configuration: .glass())
    private let gridTitle = UILabel()
    private let actionsFiller = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 14
        artwork.layer.cornerCurve = .continuous
        artwork.backgroundColor = .tertiarySystemFill
        artwork.isUserInteractionEnabled = true
        artwork.accessibilityIgnoresInvertColors = true
        artwork.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(togglePreview)))

        playButton.configuration?.cornerStyle = .capsule
        playButton.configuration?.baseForegroundColor = .white
        playButton.addAction(UIAction { [weak self] _ in self?.onTogglePreview?() }, for: .primaryActionTriggered)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        artwork.addSubview(playButton)
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title3).withWeight(.semibold)
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        metaLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
        )
        metaLabel.textColor = .tertiaryLabel

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, metaLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.setCustomSpacing(Spacing.xs, after: subtitleLabel)

        let identity = UIStackView(arrangedSubviews: [artwork, labels])
        identity.spacing = Spacing.lg
        identity.alignment = .center

        useButton.configuration?.title = "Use this sound"
        useButton.configuration?.image = UIImage(systemName: "music.note")
        useButton.configuration?.imagePadding = Spacing.sm
        useButton.configuration?.cornerStyle = .capsule
        useButton.tintColor = .systemRed
        useButton.addAction(UIAction { [weak self] _ in self?.onUse?() }, for: .primaryActionTriggered)

        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.configuration?.cornerStyle = .capsule
        shareButton.accessibilityLabel = "Share sound"
        shareButton.addAction(UIAction { [weak self] _ in self?.onShare?() }, for: .primaryActionTriggered)

        // Holds the row's width when "Use this sound" is not offered, so share
        // keeps its circle at the trailing end instead of stretching.
        actionsFiller.isHidden = true
        let actions = UIStackView(arrangedSubviews: [useButton, actionsFiller, shareButton])
        actions.spacing = Spacing.sm

        gridTitle.font = .preferredFont(forTextStyle: .headline)
        gridTitle.text = "Videos with this sound"
        gridTitle.adjustsFontForContentSizeCategory = true

        let column = UIStackView(arrangedSubviews: [identity, actions, gridTitle])
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.setCustomSpacing(Spacing.xl, after: actions)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let bottom = column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
            artwork.widthAnchor.constraint(equalToConstant: Self.artworkSide),
            artwork.heightAnchor.constraint(equalToConstant: Self.artworkSide),
            useButton.heightAnchor.constraint(equalToConstant: Self.actionHeight),
            shareButton.heightAnchor.constraint(equalToConstant: Self.actionHeight),
            shareButton.widthAnchor.constraint(equalToConstant: Self.actionHeight),
        ])
        setPlaying(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, subtitle: String, meta: String, canPreview: Bool, canUse: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        metaLabel.text = meta
        playButton.isHidden = !canPreview
        artwork.isUserInteractionEnabled = canPreview
        useButton.isHidden = !canUse
        actionsFiller.isHidden = canUse
    }

    func setArtwork(_ image: UIImage?) {
        UIView.transition(with: artwork, duration: 0.2, options: .transitionCrossDissolve) {
            self.artwork.image = image
        }
    }

    func setPlaying(_ playing: Bool) {
        playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = playing ? "Pause sound" : "Play sound"
    }

    func setMeta(_ meta: String) {
        metaLabel.text = meta
    }

    @objc private func togglePreview() {
        onTogglePreview?()
    }
}
