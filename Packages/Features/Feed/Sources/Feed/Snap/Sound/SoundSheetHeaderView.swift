import DesignSystem
import MediaCore
import UIKit

/// The sound sheet's head: the RECORD of the post the sheet opened over, and
/// what the sound is — nothing else.
///
/// The record mirrors the post (#1148): it turns while the post plays —
/// muted too — wears the mute badge while the feed's sound is off, and its
/// tap plays or pauses the POST (`onTogglePlayback`), the glyph following.
/// It is the column bubble's own component (`SoundRecordGlass`, #1150): the
/// cover inside its glass, the badge a glass inside the rim. "Use this sound" and share are bar items
/// of the sheet's native TOOLBAR, and a section of posts that holds more than
/// it shows opens from its title's chevron (`SectionTitleView`).
///
/// Laid out inside its section's insets (`SoundSheetHeaderCell`) —
/// `SoundSheetViewController.headerInset` from the sheet's leading edge, as
/// far from its top (`topInset`): twice the tiles' gutter, the one block of
/// the sheet with air around it (asked for, 2026-09-30) — and the app's
/// section gap under it (`DetentMetrics.sectionGap`), at the ABSOLUTE height
/// `fittingHeight` computes.
///
/// ```
///  ╭────╮  Veridis Quo Veridis Qu…   (✕)   the sheet's close button, a bar
///  │ ▶︎  │  Daft Punk                      item floating over this header
///  ╰────╯  0:30 · 23 posts
/// ```
///
/// **IT STANDS UNDER THE SHEET'S NAVIGATION BAR**, whose one item is the
/// close button at the top trailing corner: the lines stop short of it
/// (`closeClearance`) and each is ONE line, truncated — so the header's
/// height never depends on how long the sound's name is.
final class SoundSheetHeaderView: UICollectionReusableView {
    static let artworkSide: CGFloat = 96
    /// What the lines leave free at the header's trailing edge for the
    /// sheet's close button: the bar's glass circle (44) and its margin (16),
    /// less what the header is already inset by (`headerInset`, 16), plus a
    /// gutter of air before the circle. Measured on iOS 27 (iPhone 18 Pro,
    /// sheet at large, 402 wide): the circle is drawn from x 341 to 386, the
    /// lines end at 334.
    static let closeClearance: CGFloat = 44 + 16 - SoundSheetViewController.headerInset + SoundSheetViewController.gutter

    var onTogglePlayback: (() -> Void)?

    private let record = Record()
    private let recordGlass = SoundRecordGlass()
    private var artwork: UIImageView { recordGlass.cover }
    private let playButton = UIButton(configuration: .glass())
    /// ▶︎ / ❚❚, drawn in the glass disc by an image view of its own, swapped
    /// by our own bounce and fade (`swapGlyph`). The glass button's
    /// configured image swapped with no transition, even with
    /// `symbolContentTransition` set.
    private let playGlyph = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: glyphConfiguration))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let artworkBackdrop = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // ROUND: a sound is a record, not a picture — and a circle reads as
        // "this plays" next to the square tiles of the posts below.
        artwork.accessibilityIgnoresInvertColors = true
        // The record's own muted glyph stays down here: the button in the
        // middle says muted itself, in place of ❚❚ / ▶︎ (`applyGlyph`).
        recordGlass.coverSide = nil
        // The record's TAP is the sheet's (`SoundSheetViewController
        // .installRecordTap`, #1162): a recognizer here never fired under the
        // sheet's bar. This view only says where the record is.
        recordGlass.translatesAutoresizingMaskIntoConstraints = false
        record.addSubview(recordGlass)
        NSLayoutConstraint.activate([
            recordGlass.topAnchor.constraint(equalTo: record.topAnchor),
            recordGlass.leadingAnchor.constraint(equalTo: record.leadingAnchor),
            recordGlass.trailingAnchor.constraint(equalTo: record.trailingAnchor),
            recordGlass.bottomAnchor.constraint(equalTo: record.bottomAnchor),
        ])
        // Under the picture, for a sound that has none.
        let note = UIImageView(image: UIImage(systemName: "music.note"))
        note.tintColor = .tertiaryLabel
        note.preferredSymbolConfiguration = .init(pointSize: 34, weight: .medium)
        note.translatesAutoresizingMaskIntoConstraints = false
        artworkBackdrop.backgroundColor = .tertiarySystemFill
        artworkBackdrop.layer.cornerRadius = (Self.artworkSide - 2 * SoundRecordGlass.rim) / 2
        artworkBackdrop.translatesAutoresizingMaskIntoConstraints = false
        artworkBackdrop.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: artworkBackdrop.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: artworkBackdrop.centerYAnchor),
        ])

        playButton.configuration?.cornerStyle = .capsule
        playButton.configuration?.baseForegroundColor = .white
        // The glass's own ink (`.label`), as the button drew its image, at
        // the size it drew it.
        playGlyph.tintColor = .label
        playGlyph.contentMode = .center
        playGlyph.preferredSymbolConfiguration = Self.glyphConfiguration
        playGlyph.isUserInteractionEnabled = false
        playGlyph.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ ONE TOGGLE PER TAP: the glyph is drawn, not tapped — the record's
        // tap takes it all. A button that also answered toggled the post
        // twice (paused, then played again) for one tap on the glyph.
        playButton.isUserInteractionEnabled = false
        playButton.isAccessibilityElement = false
        record.isAccessibilityElement = true
        record.accessibilityTraits = .button
        record.onActivate = { [weak self] in self?.onTogglePlayback?() }
        playButton.translatesAutoresizingMaskIntoConstraints = false
        // On the RECORD, beside the artwork rather than in it: the artwork
        // turns while the sound plays, the button stays upright.
        record.addSubview(playButton)
        // IN the glass (the owner, 2026-10-16: the glyph is the glass's
        // content, not a sticker over it).
        playButton.addSubview(playGlyph)
        NSLayoutConstraint.activate([
            playGlyph.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            playGlyph.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            playButton.centerXAnchor.constraint(equalTo: record.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: record.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        titleLabel.font = .scaledFont(forTextStyle: .title3, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = .appFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        metaLabel.font = .scaledMonospacedDigitSystemFont(
            ofSize: UIFont.defaultPointSize(for: .footnote), relativeTo: .footnote
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

        // NO GAP OF ITS OWN under the record: the room under the sound is its
        // SECTION's (`SoundSheetViewController.DetentMetrics.sectionGap`),
        // counted by the detents from the same value.
        let bottom = identity.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            identity.topAnchor.constraint(equalTo: topAnchor),
            identity.leadingAnchor.constraint(equalTo: leadingAnchor),
            identity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.closeClearance),
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
        width: CGFloat, title: String, subtitle: String, meta: String, canToggle: Bool
    ) -> CGFloat {
        let header = SoundSheetHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        header.configure(title: title, subtitle: subtitle, meta: meta, canToggle: canToggle)
        return header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height.rounded(.up)
    }

    /// `canToggle` false — a post with no audio — shows the record without
    /// its glyph, and it ignores taps.
    func configure(title: String, subtitle: String, meta: String, canToggle: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        metaLabel.text = meta
        playButton.isHidden = !canToggle
        record.isUserInteractionEnabled = canToggle
    }

    /// The sound's picture through the slot (#1772): the bone on the record
    /// while it is on its way, dissolved in, the note's backdrop if it never
    /// comes.
    private lazy var artworkSlot: CoverSlot = {
        let slot = CoverSlot(view: artwork, size: .px256)
        slot.onChange = { [weak self] _ in self?.artworkBackdrop.isHidden = true }
        return slot
    }()

    func loadArtwork(_ url: URL, pipeline: ImagePipeline) {
        // ⚠️ A file is read as it is: the mock pipeline paints a colour for
        // any URL it does not recognise, a file among them.
        guard url.isFileURL else { return artworkSlot.load(url, pipeline: pipeline, item: url) }
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
            guard let image else { return }
            self?.artworkSlot.apply(image)
        }
    }

    /// The post plays (the record turns, ❚❚) or not (it stops in place, ▶︎).
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        applyGlyph()
        applyPlayingRest(playing)
    }

    private var isPlaying = false

    /// ▶︎ while paused, ❚❚ while it plays — no muted state since #1931: the
    /// sound follows the device, and this button only pauses and resumes.
    private func applyGlyph() {
        let name = isPlaying ? "pause.fill" : "play.fill"
        guard name != shownGlyph else { return }
        shownGlyph = name
        if let image = UIImage(systemName: name, withConfiguration: Self.glyphConfiguration) {
            swapGlyph(to: image, animated: window != nil)
        }
    }

    /// ⚠️ NOT THE SYSTEM'S SYMBOL REPLACE (the owner, 2026-10-16): inside
    /// the glass button, `setSymbolImage(_:contentTransition: .replace)` is
    /// drawn in the glass's own pass — on a device it stuttered ("as if at
    /// 30 fps"), on the simulator it was a plain cut, at any `.speed`. The
    /// glyph stays IN the glass, and the swap is ours: the old symbol shrinks
    /// and fades on a copy while the new one bounces up from small as it
    /// fades in — view animations, which the glass composites like any other.
    private func swapGlyph(to image: UIImage, animated: Bool) {
        guard animated, let old = playGlyph.image else {
            playGlyph.image = image
            return
        }
        let outgoing = UIImageView(image: old)
        outgoing.tintColor = playGlyph.tintColor
        outgoing.contentMode = .center
        outgoing.isUserInteractionEnabled = false
        outgoing.frame = playGlyph.frame
        playButton.insertSubview(outgoing, belowSubview: playGlyph)
        UIView.performWithoutAnimation {
            playGlyph.image = image
            playGlyph.alpha = 0
            playGlyph.transform = CGAffineTransform(scaleX: Self.swapScale, y: Self.swapScale)
        }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            outgoing.alpha = 0
            outgoing.transform = CGAffineTransform(scaleX: Self.swapScale, y: Self.swapScale)
        } completion: { _ in
            outgoing.removeFromSuperview()
        }
        UIView.animate(
            withDuration: 0.42, delay: 0.06, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.playGlyph.alpha = 1
            self.playGlyph.transform = .identity
        }
    }

    /// How small a symbol is when it leaves, and when the next one starts.
    static let swapScale: CGFloat = 0.4

    /// ▶︎ / ❚❚'s size and weight — the glass button's image as it drew it.
    static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

    /// The glyph shown — so a repeat of the same state replaces nothing.
    private var shownGlyph = "play.fill"

    private func applyPlayingRest(_ playing: Bool) {
        record.accessibilityLabel = playing ? "Pause post" : "Play post"
        recordGlass.setSpinning(playing)
    }

    #if DEBUG
    var debugIsSpinning: Bool { recordGlass.isSpinning }
    /// The glyph says ❚❚ (the post plays) rather than ▶︎.
    var debugShowsPause: Bool { record.accessibilityLabel == "Pause post" }
    /// The glyph's symbol, as last asked for.
    var debugShownGlyph: String { shownGlyph }
    /// The glyph's image as drawn, and whether it is drawn in the glass
    /// button.
    var debugGlyphImage: UIImage? { playGlyph.image }
    var debugGlyphIsInTheGlass: Bool { playGlyph.isDescendant(of: playButton) }
    var debugCanToggle: Bool { record.isUserInteractionEnabled && !playButton.isHidden }
    func debugTapRecord() { togglePlayback() }
    /// The record's frame, in this view's space.
    var debugRecordFrame: CGRect { record.frame }
    #endif

    /// Whether `point`, in this view's space, is on the record — the WHOLE
    /// disc (#1162) — and the record takes taps.
    func recordTakesTap(at point: CGPoint) -> Bool {
        guard record.isUserInteractionEnabled, !record.isHidden else { return false }
        let local = convert(point, to: record)
        let radius = min(record.bounds.width, record.bounds.height) / 2
        let centre = CGPoint(x: record.bounds.midX, y: record.bounds.midY)
        return hypot(local.x - centre.x, local.y - centre.y) <= radius
    }

    func setMeta(_ meta: String) {
        metaLabel.text = meta
    }

    @objc private func togglePlayback() {
        onTogglePlayback?()
    }

    /// The record as VoiceOver reads it: one button, whose activation is the
    /// tap's toggle.
    final class Record: UIView {
        var onActivate: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            guard isUserInteractionEnabled, let onActivate else { return false }
            onActivate()
            return true
        }
    }
}
