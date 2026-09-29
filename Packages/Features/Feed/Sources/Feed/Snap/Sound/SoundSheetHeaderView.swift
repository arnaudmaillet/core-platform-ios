import DesignSystem
import UIKit

/// The sound sheet's head: the artwork that plays and pauses the sound, and
/// what the sound is — nothing else. "Use this sound" and share are bar items
/// of the sheet's native TOOLBAR, and each section of posts has its own
/// "View all" (`SoundSheetSectionHeaderView`).
///
/// Laid out inside its section's side insets (`SoundSheetHeaderCell`) — one
/// gutter from the sheet's edge, on the tiles' left edge — at the ABSOLUTE
/// height `fittingHeight` computes.
final class SoundSheetHeaderView: UICollectionReusableView {
    static let artworkSide: CGFloat = 96

    var onTogglePreview: (() -> Void)?

    private let record = UIView()
    private let artwork = UIImageView()
    private let playButton = UIButton(configuration: .glass())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let artworkBackdrop = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        // ROUND: a sound is a record, not a picture — and a circle reads as
        // "this plays" next to the square tiles of the posts below.
        artwork.layer.cornerRadius = Self.artworkSide / 2
        artwork.backgroundColor = .clear
        artwork.accessibilityIgnoresInvertColors = true
        record.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(togglePreview)))
        artwork.translatesAutoresizingMaskIntoConstraints = false
        record.addSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: record.topAnchor),
            artwork.leadingAnchor.constraint(equalTo: record.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: record.trailingAnchor),
            artwork.bottomAnchor.constraint(equalTo: record.bottomAnchor),
        ])
        // Under the picture, for a sound that has none.
        let note = UIImageView(image: UIImage(systemName: "music.note"))
        note.tintColor = .tertiaryLabel
        note.preferredSymbolConfiguration = .init(pointSize: 34, weight: .medium)
        note.translatesAutoresizingMaskIntoConstraints = false
        artworkBackdrop.backgroundColor = .tertiarySystemFill
        artworkBackdrop.layer.cornerRadius = Self.artworkSide / 2
        artworkBackdrop.translatesAutoresizingMaskIntoConstraints = false
        artworkBackdrop.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: artworkBackdrop.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: artworkBackdrop.centerYAnchor),
        ])

        playButton.configuration?.cornerStyle = .capsule
        playButton.configuration?.baseForegroundColor = .white
        playButton.addAction(UIAction { [weak self] _ in self?.onTogglePreview?() }, for: .primaryActionTriggered)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        // On the RECORD, beside the artwork rather than in it: the artwork
        // turns while the sound plays, the button stays upright.
        record.addSubview(playButton)
        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: record.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: record.centerYAnchor),
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

        artwork.insertSubview(artworkBackdrop, at: 0)
        NSLayoutConstraint.activate([
            artworkBackdrop.topAnchor.constraint(equalTo: artwork.topAnchor),
            artworkBackdrop.leadingAnchor.constraint(equalTo: artwork.leadingAnchor),
            artworkBackdrop.trailingAnchor.constraint(equalTo: artwork.trailingAnchor),
            artworkBackdrop.bottomAnchor.constraint(equalTo: artwork.bottomAnchor),
        ])
        let identity = UIStackView(arrangedSubviews: [record, labels])
        identity.spacing = Spacing.lg
        identity.alignment = .center
        identity.translatesAutoresizingMaskIntoConstraints = false
        addSubview(identity)

        // The gap to the grid below is the header's own, so the first row
        // starts where the header says it ends.
        let bottom = identity.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.lg)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            identity.topAnchor.constraint(equalTo: topAnchor),
            identity.leadingAnchor.constraint(equalTo: leadingAnchor),
            identity.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
            record.widthAnchor.constraint(equalToConstant: Self.artworkSide),
            record.heightAnchor.constraint(equalToConstant: Self.artworkSide),
        ])
        setPlaying(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How tall a header `width` wide is with these lines, at the CURRENT
    /// trait environment's text size (call it inside `performAsCurrent`) —
    /// what the sound sheet's collapsed detent counts, and what its layout
    /// then gives the header, so the two cannot disagree.
    static func fittingHeight(
        width: CGFloat, title: String, subtitle: String, meta: String, canPreview: Bool
    ) -> CGFloat {
        let header = SoundSheetHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        header.configure(title: title, subtitle: subtitle, meta: meta, canPreview: canPreview)
        return header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height.rounded(.up)
    }

    func configure(title: String, subtitle: String, meta: String, canPreview: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        metaLabel.text = meta
        playButton.isHidden = !canPreview
        record.isUserInteractionEnabled = canPreview
    }

    func setArtwork(_ image: UIImage?) {
        UIView.transition(with: artwork, duration: 0.2, options: .transitionCrossDissolve) {
            self.artwork.image = image
            self.artworkBackdrop.isHidden = image != nil
        }
    }

    func setPlaying(_ playing: Bool) {
        playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = playing ? "Pause sound" : "Play sound"
        artwork.layer.setRecordSpinning(playing)
    }

    func setMeta(_ meta: String) {
        metaLabel.text = meta
    }

    @objc private func togglePreview() {
        onTogglePreview?()
    }
}
