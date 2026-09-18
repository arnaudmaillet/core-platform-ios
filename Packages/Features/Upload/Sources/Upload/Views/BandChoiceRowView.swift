import DesignSystem
import MediaPlayback
import UIKit

/// A row of choices under the collapsed track: the transitions a cut can
/// carry (`MediaTransitionRowView`), or the filters a piece can wear
/// (`MediaSegmentFilterRowView`).
///
/// ⚠️ **ONE ROW, TWO CLIENTS.** The piece's filter row was asked for
/// *"exactement comme on a fait avec l'affichage des transitions disponibles"* —
/// so it IS that row, with pictures on its cards instead of symbols: the fade,
/// the glass, the rest stops, the reveal and the "no touch until it has landed"
/// rule are written once.
///
/// ```
///   ────────▓▓▓▓█▓▓▓▓──────────              ← the track, collapsed
///   ┌────┐ ┌────┐ ┌────┐ ┌────┐
///   │ ⊘  │ │ ☾  │ │ ☀  │ │ ⤡  │           (✕) ← this row
///   │None│ │Blck│ │Whte│ │Zoom│
///   └────┘ └────┘ └────┘ └────┘
/// ```
///
/// ⚠️ **ASKED FOR IN THOSE WORDS**: *"dans la scrollview des transitions, il y
/// aura une icône de croix à droite fixe (dans un liquid glass natif) … les
/// éléments de la scrollview se fadent lorsqu'ils passent par derrière ce
/// bouton"*, and *"un choix nul/vide pour supprimer toute transition"*.
///
/// ⚠️ **CARDS, NOT A PLATE** — asked for as *"je ne voudrais pas des pilules
/// mais des cards avec l'icône et le texte en dessous dans la card"*. Each
/// choice is its own tile with footage between them, which is what the filter
/// row already puts in this band; what the band forbids is one surface across
/// it. An unchosen card is black at 55% with a faint white rim — the lowest fill
/// that keeps white ink at 4.5:1 over pure white footage, and the rim is what
/// draws its edge over dark footage — and the chosen one is white with black
/// ink, the white the selection is drawn in. No shadow on either: under a
/// filled shape a shadow reads as a plate. The close button is the band's one
/// MATERIAL (charter F28), and only while the row is open: a material left
/// materialised under a hidden row still costs a compositing pass.
///
/// ⚠️ **THE FADE IS A MASK ON A HOST THAT DOES NOT SCROLL** — the crop tools'
/// lesson: a mask framed in a scroll view's bounds travels with its content.
@MainActor
final class BandChoiceRowView<Choice: Equatable>: UIView {
    /// What a card says about its choice.
    struct Face {
        /// The symbol on the card — nil for a card that shows a picture.
        var glyph: String?
        var label: String
        var spoken: String
    }

    private typealias Metrics = BandChoiceMetrics

    /// ⚠️ **EXACTLY THE ROOM THE LINE FREES.** The track keeps its height while
    /// it collapses; this row lives in what the film gave up, less the band's
    /// own gap between the two.
    nonisolated static var height: CGFloat {
        MediaTimelineTrackView.height - MediaTimelineTrackView.compactHeight - Spacing.sm
    }

    /// A choice was tapped. Fires on every tap, the chosen one included:
    /// tapping it again replays it.
    var onPick: ((Choice) -> Void)?
    /// The close button was tapped.
    var onClose: (() -> Void)?

    private(set) var isOpen = false

    private let fadeHost = UIView()
    private let fade: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor.black.cgColor, UIColor.black.cgColor,
            UIColor.clear.cgColor, UIColor.clear.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }()
    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private var cards: [ChoiceCard] = []
    private var chosen: Choice

    private let closeHost = CloseHost()
    private let glass = UIVisualEffectView(effect: nil)
    private let closeButton = UIButton(type: .custom)

    init(
        choices: [Choice], initial: Choice, closeLabel: String, face: (Choice) -> Face
    ) {
        chosen = initial
        super.init(frame: .zero)
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = false

        row.axis = .horizontal
        // The cards take the row's whole height.
        row.alignment = .fill
        row.spacing = Spacing.sm
        row.translatesAutoresizingMaskIntoConstraints = false

        scroller.backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        scroller.contentInsetAdjustmentBehavior = .never
        // ⚠️ **NO CLIPPING: THE MASK IS WHAT TAKES A CHIP AWAY.**
        scroller.clipsToBounds = false
        scroller.addSubview(row)
        fadeHost.layer.mask = fade
        scroller.pin(to: fadeHost)
        fadeHost.pin(to: self)

        for choice in choices {
            let card = ChoiceCard(choice: choice, face: face(choice))
            card.onTap = { [weak self] in self?.pick(choice) }
            cards.append(card)
            row.addArrangedSubview(card)
        }
        dress()

        glass.isUserInteractionEnabled = true
        glass.clipsToBounds = true
        glass.cornerConfiguration = .capsule()
        closeButton.setImage(
            UIImage(
                systemName: MediaTransitionCatalog.closeGlyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = closeLabel
        closeButton.addAction(
            UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered
        )
        glass.contentView.addSubview(closeButton)
        closeHost.target = closeButton
        closeHost.addSubview(glass)
        // Added last: the glass stands over the cards passing behind it.
        addSubview(closeHost)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the glass begins, in this row's points.
    private var closeMinX: CGFloat { bounds.width - Spacing.sm - Metrics.close }

    /// ⚠️ **THE STOPS ARE COMPUTED, AND THE LAST CHIP RESTS PAST THE RAMP.** A
    /// card that came to rest inside the fade would sit half dissolved for good,
    /// which reads as a rendering fault rather than as a fade.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let reach = Metrics.closeReach
        closeHost.frame = CGRect(
            x: closeMinX - (reach - Metrics.close) / 2, y: 0, width: reach, height: bounds.height
        )
        glass.frame = CGRect(
            x: (reach - Metrics.close) / 2, y: (bounds.height - Metrics.close) / 2,
            width: Metrics.close, height: Metrics.close
        )
        closeButton.frame = glass.contentView.bounds

        let insets = UIEdgeInsets(
            top: 0, left: Spacing.sm, bottom: 0,
            right: (width - closeMinX) + Metrics.fade + Metrics.restPastTheRamp
        )
        if scroller.contentInset != insets { scroller.contentInset = insets }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = fadeHost.bounds
        fade.locations = [
            0,
            NSNumber(value: Double((closeMinX - Metrics.fade) / width)),
            NSNumber(value: Double(closeMinX / width)),
            1
        ]
        CATransaction.commit()
    }

    /// States which choice is held, without announcing it.
    func show(kind: Choice) {
        guard kind != chosen else { return }
        chosen = kind
        dress()
    }

    /// Opens the row — the glass materialising as it does — or closes it.
    ///
    /// ⚠️ **THE GLASS IS ASSIGNED INSIDE THE ANIMATION**, which is how a
    /// `UIGlassEffect` materialises rather than popping in, and taken away
    /// inside it on the way out; the row is hidden only once the fade lands, and
    /// only if nothing reopened it meanwhile.
    ///
    /// ⚠️ **AND IT TAKES NO TOUCH UNTIL IT HAS LANDED.** The finger that opened
    /// it is still over it — a double tap on a cut's `+` would otherwise choose
    /// the card fading in under the second tap.
    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let animating = animated && window != nil
        isUserInteractionEnabled = open && !animating
        if open {
            isHidden = false
            layoutIfNeeded()
            scroller.contentOffset.x = -scroller.contentInset.left
            revealChosen(animated: false)
            fadeHost.alpha = 0
            closeButton.alpha = 0
        }
        let changes = { [self] in
            fadeHost.alpha = open ? 1 : 0
            closeButton.alpha = open ? 1 : 0
            glass.effect = open ? Self.makeGlass() : nil
        }
        let landed = { [weak self] in
            guard let self else { return }
            if isOpen {
                isUserInteractionEnabled = true
            } else {
                isHidden = true
            }
        }
        guard animating else {
            changes()
            landed()
            return
        }
        UIView.animate(
            withDuration: 0.3, delay: 0, options: [.allowUserInteraction, .curveEaseOut],
            animations: changes
        ) { _ in landed() }
    }

    /// Scrolls the chosen card into the stretch before the ramp, and leaves the
    /// row where it is when the card is already there.
    ///
    /// ⚠️ **FIFTEEN CARDS DO NOT FIT, SO THE ROW MUST GO TO THE CHOICE.** A cut
    /// carrying Crumble opened on None, Black, White and Zoom, with nothing on
    /// screen saying what the cut carries — the white card was scrolled away.
    func revealChosen(animated: Bool) {
        guard let card = cards.first(where: { $0.choice == chosen }), bounds.width > 0 else { return }
        layoutIfNeeded()
        let frame = card.convert(card.bounds, to: scroller)
        let offset = scroller.contentOffset.x
        let firstStop = offset + Spacing.sm
        let lastStop = offset + closeMinX - Metrics.fade
        var wanted = offset
        if frame.maxX > lastStop {
            wanted = frame.maxX - (closeMinX - Metrics.fade)
        } else if frame.minX < firstStop {
            wanted = frame.minX - Spacing.sm
        }
        let lowest = -scroller.contentInset.left
        let highest = max(lowest, scroller.contentSize.width + scroller.contentInset.right - scroller.bounds.width)
        wanted = min(max(wanted, lowest), highest)
        guard abs(wanted - offset) > 0.5 else { return }
        scroller.setContentOffset(CGPoint(x: wanted, y: scroller.contentOffset.y), animated: animated)
    }

    private static func makeGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }

    /// Puts `picture` on the card of `choice` — the filter row's thumbnails.
    func setPicture(_ picture: UIImage?, for choice: Choice) {
        cards.first { $0.choice == choice }?.setPicture(picture)
    }

    private func pick(_ kind: Choice) {
        show(kind: kind)
        onPick?(kind)
    }

    private func dress() {
        for card in cards { card.setChosen(card.choice == chosen) }
    }

    /// One choice: its symbol and its word under it, on a card — or, for a
    /// choice with no symbol, its picture filling the card under its word.
    private final class ChoiceCard: UIControl {
        let choice: Choice
        let face: Face
        var onTap: (() -> Void)?
        private let glyph = UIImageView()
        private let caption = UILabel()
        /// ⚠️ **INSET BY THE RING, SO THE CARD'S OWN FILL DRAWS IT** — white when
        /// chosen, dark otherwise, the same fill a symbol card is read by.
        private let picture = UIImageView()
        private let shade = CAGradientLayer()

        init(choice: Choice, face: Face) {
            self.choice = choice
            self.face = face
            super.init(frame: .zero)
            if let symbol = face.glyph {
                glyph.image = UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.glyph, weight: .semibold)
                )
            } else {
                picture.contentMode = .scaleAspectFill
                picture.clipsToBounds = true
                picture.layer.cornerRadius = Metrics.cardCorner - Metrics.ring
                picture.layer.cornerCurve = .continuous
                picture.isUserInteractionEnabled = false
                shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.6).cgColor]
                shade.locations = [0.35, 1]
                picture.layer.addSublayer(shade)
                picture.constrain(in: self) { view in
                    picture.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.ring)
                    picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.ring)
                    picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.ring)
                    picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.ring)
                }
            }
            glyph.contentMode = .center
            caption.text = face.label
            caption.font = .systemFont(ofSize: Metrics.caption, weight: .semibold)
            caption.textAlignment = .center
            caption.numberOfLines = 1
            caption.adjustsFontSizeToFitWidth = true
            caption.minimumScaleFactor = 0.8
            let stack = UIStackView(arrangedSubviews: face.glyph == nil ? [caption] : [glyph, caption])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = Metrics.glyphGap
            stack.isUserInteractionEnabled = false
            // A symbol card centres its stack; a picture card sets its word
            // along the bottom, over the shade.
            let vertical = face.glyph == nil
                ? stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.cardInset)
                : stack.centerYAnchor.constraint(equalTo: centerYAnchor)
            stack.constrain(in: self) { view in
                stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
                vertical
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.cardInset)
                stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.cardInset)
            }
            widthAnchor.constraint(equalToConstant: Metrics.cardWidth).isActive = true
            layer.cornerRadius = Metrics.cardCorner
            layer.cornerCurve = .continuous
            layer.borderColor = Metrics.cardRim.cgColor
            addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
            isAccessibilityElement = true
            let word = face.label
            let spoken = face.spoken
            accessibilityLabel = spoken
            // Voice Control is asked by what is written on the card.
            accessibilityUserInputLabels = word == spoken ? [word] : [word, spoken]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.55 : 1 }
        }

        /// The chosen card is white with black ink; the others are dark cards
        /// with white ink and a faint rim.
        func setChosen(_ chosen: Bool) {
            backgroundColor = chosen ? .white : Metrics.cardFill
            layer.borderWidth = chosen ? 0 : Metrics.rim
            // ⚠️ A PICTURE'S WORD STAYS WHITE, over its shade; only the ring
            // around the picture says it is chosen.
            let ink: UIColor = chosen && face.glyph != nil ? .black : .white
            glyph.tintColor = ink
            caption.textColor = ink
            accessibilityTraits = chosen ? [.button, .selected] : [.button]
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shade.frame = picture.bounds
            CATransaction.commit()
        }

        func setPicture(_ image: UIImage?) {
            picture.image = image
        }

        #if DEBUG
        var debugPicture: UIImage? { picture.image }
        var debugGlyph: UIView { face.glyph == nil ? picture : glyph }
        var debugCaption: UIView { caption }
        #endif
    }

    /// ⚠️ **A FINGER WIDE, THOUGH THE GLASS IS NOT.** Anything inside the host
    /// is the close button's.
    private final class CloseHost: UIView {
        weak var target: UIView?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !isHidden, isUserInteractionEnabled, alpha > 0.01, bounds.contains(point) else {
                return nil
            }
            return target
        }
    }
}

#if DEBUG
extension BandChoiceRowView {
    /// Internal for tests: each choice's word, in the order shown.
    var debugLabels: [String] { cards.map(\.face.label) }
    /// Internal for tests: the word of the card DRAWN as chosen — read off its
    /// fill, not off a flag set beside it.
    var debugChosen: [String] {
        cards.filter { $0.backgroundColor == .white }.map(\.face.label)
    }
    /// Internal for tests: taps a choice exactly as a finger would.
    func debugTap(_ kind: Choice) {
        cards.first { $0.choice == kind }?.sendActions(for: .touchUpInside)
    }
    /// Internal for tests: the picture each card shows, in order.
    var debugPictures: [UIImage?] { cards.map(\.debugPicture) }
    func debugTapClose() { closeButton.sendActions(for: .primaryActionTriggered) }
    var debugFadeStops: [Double] { (fade.locations ?? []).map(\.doubleValue) }
    var debugFadeFrame: CGRect { fade.frame }
    var debugMaskIsOnTheHost: Bool { fadeHost.layer.mask === fade && scroller.layer.mask == nil }
    var debugHasGlass: Bool { glass.effect != nil }
    var debugGlassFrame: CGRect { glass.convert(glass.bounds, to: self) }
    var debugCloseButton: UIView { closeButton }
    /// Internal for tests: where each card, its symbol and its word are drawn,
    /// in this row's points.
    var debugCardFrames: [CGRect] { cards.map { $0.convert($0.bounds, to: self) } }
    /// ⚠️ **THE SYMBOL'S LAYOUT BOX, NOT ITS FRAME.** A symbol image carries
    /// alignment insets, so its view's frame is taller or shorter than the box
    /// Auto Layout gave it — measured 17.3 to 20pt for an 18pt box.
    var debugGlyphFrames: [CGRect] {
        cards.map { $0.debugGlyph.convert($0.debugGlyph.alignmentRect(forFrame: $0.debugGlyph.bounds), to: self) }
    }
    var debugCaptionFrames: [CGRect] { cards.map { $0.debugCaption.convert($0.debugCaption.bounds, to: self) } }
    var debugCards: [UIView] { cards }
    var debugTakesTouches: Bool { isUserInteractionEnabled && !isHidden }
    var debugScroller: UIScrollView { scroller }
}
#endif

/// ⚠️ **AT FILE SCOPE: A GENERIC TYPE CANNOT HOLD STATIC STORED PROPERTIES.**
private enum BandChoiceMetrics {
    /// A card is as tall as the row, and as wide as the filter row's
    /// thumbnails — the strips of this flow agree.
    static let cardWidth: CGFloat = 56
    static let cardCorner: CGFloat = 10
    static let cardInset: CGFloat = 4
    /// ⚠️ **NO BOX OF ITS OWN IS NEEDED FOR THE WORDS TO LINE UP.** The four
    /// symbols draw at different heights, but their alignment rects — what
    /// the stack lays out — are one height at one point size (measured: a
    /// fixed 18pt box changed nothing).
    static let glyph: CGFloat = 14
    static let glyphGap: CGFloat = 2
    static let caption: CGFloat = 11
    static let rim: CGFloat = 1
    /// The chosen ring around a picture card.
    static let ring: CGFloat = 2
    static let cardFill = UIColor.black.withAlphaComponent(0.55)
    static let cardRim = UIColor.white.withAlphaComponent(0.2)
    static let close: CGFloat = 36
    /// A finger's width around the glass.
    static let closeReach: CGFloat = 44
    /// How far a card travels while it dissolves, before the glass.
    static let fade: CGFloat = 52
    /// Past the ramp, where the last card comes to rest.
    static let restPastTheRamp: CGFloat = 8
}


/// The transitions a cut can carry.
typealias MediaTransitionRowView = BandChoiceRowView<VideoTransitionKind?>

extension BandChoiceRowView where Choice == VideoTransitionKind? {
    convenience init() {
        self.init(
            choices: MediaTransitionCatalog.choices, initial: nil, closeLabel: "Close transitions"
        ) { kind in
            Face(
                glyph: MediaTransitionCatalog.glyph(for: kind),
                label: MediaTransitionCatalog.label(for: kind),
                spoken: kind?.spokenLabel ?? "No transition"
            )
        }
    }
}

/// The filters one piece of a clip can wear — `nil` first, for none.
typealias MediaSegmentFilterRowView = BandChoiceRowView<MediaFilter?>

extension BandChoiceRowView where Choice == MediaFilter? {
    /// Every choice the row offers, in order: nothing first, then the looks.
    static var filterChoices: [MediaFilter?] {
        [nil] + MediaFilter.allCases.filter { $0 != .original }.map { $0 }
    }

    convenience init() {
        self.init(choices: Self.filterChoices, initial: nil, closeLabel: "Close filters") { filter in
            Face(
                glyph: nil,
                label: filter?.name ?? "None",
                spoken: filter.map { "\($0.name) filter" } ?? "No filter"
            )
        }
    }
}

// MARK: - Arriving

extension BandChoiceRowView: PoppingTenant {
    /// The cards — a transition's, or a piece's looks.
    var poppableElements: [UIView] { row.arrangedSubviews }
}
