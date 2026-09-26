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
    var onToggleExpanded: (() -> Void)?

    private let record = UIView()
    private let artwork = UIImageView()
    private let playButton = UIButton(configuration: .glass())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let useButton = UIButton(configuration: .prominentGlass())
    private let shareButton = UIButton(configuration: .glass())
    private let gridTitle = UIButton(configuration: .plain())
    private let actionsFiller = UIView()
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

        // The grid's title, and its door: collapsed, the grid is below the
        // fold and this is all of it that shows; a tap goes up to it.
        var expander = UIButton.Configuration.plain()
        expander.image = UIImage(systemName: "chevron.up")
        expander.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .bold)
        expander.imagePadding = Spacing.sm
        expander.contentInsets = .init(top: Spacing.sm, leading: 0, bottom: Spacing.sm, trailing: Spacing.sm)
        expander.baseForegroundColor = .secondaryLabel
        var title = AttributedString("Posts with this sound")
        title.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        expander.attributedTitle = title
        gridTitle.configuration = expander
        gridTitle.contentHorizontalAlignment = .leading
        gridTitle.addAction(UIAction { [weak self] _ in self?.onToggleExpanded?() }, for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [identity, actions, gridTitle])
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.setCustomSpacing(Spacing.md, after: actions)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let bottom = column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
            record.widthAnchor.constraint(equalToConstant: Self.artworkSide),
            record.heightAnchor.constraint(equalToConstant: Self.artworkSide),
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
        record.isUserInteractionEnabled = canPreview
        useButton.isHidden = !canUse
        actionsFiller.isHidden = canUse
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
        setSpinning(playing)
    }

    /// The chevron points where a tap goes: up to the grid, or back down.
    func setExpanded(_ expanded: Bool) {
        gridTitle.configuration?.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.up")
        gridTitle.accessibilityHint = expanded ? "Shows less" : "Shows the posts"
    }

    /// The record turns while it plays — slowly, and it stops where it is.
    private func setSpinning(_ spinning: Bool) {
        let key = "sound.spin"
        let layer = artwork.layer
        if spinning {
            guard layer.animation(forKey: key) == nil else {
                resume(layer)
                return
            }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 8
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.add(spin, forKey: key)
            resume(layer)
        } else if layer.animation(forKey: key) != nil, layer.speed != 0 {
            // Paused in place rather than removed: the record stops where it
            // is, and a second play turns it on from there.
            let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = paused
        }
    }

    private func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    func setMeta(_ meta: String) {
        metaLabel.text = meta
    }

    @objc private func togglePreview() {
        onTogglePreview?()
    }
}
