import DesignSystem
import MediaPlayback
import UIKit

/// The row of looks that sits in the editing band: the picture being edited,
/// shown small in each filter, with the chosen one ringed.
///
/// ```
/// ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐
/// │▣▣▣▣│ │▣▣▣▣│ │▣▣▣▣│ │▣▣▣▣│ │▣▣▣▣│  →
/// └────┘ └────┘ └────┘ └────┘ └────┘
///  Origin Chrome  Fade  Instant Mono
/// ```
///
/// ⚠️ **ONE SOURCE IMAGE, NINE LOCAL RENDERS.** The row is handed a single
/// picture and filters it itself. Asking the library for nine thumbnails would
/// be nine `PHImageManager` requests — with iCloud access allowed — for one
/// photograph; the seam caches nothing.
///
/// ⚠️ **THE PREVIEWS ARE 56pt AND THE CANVAS IS NOT.** Selecting a look cannot
/// reuse the thumbnail it was chosen from: the page behind wants a render at
/// canvas size, and pushing this one up there would show a blurred picture. The
/// two renders are deliberately separate, and the screen owns the second.
///
/// Metrics follow `SelectedMediaTrayView` rather than inventing a third size for
/// a horizontal strip in this flow.
@MainActor
final class MediaFilterRowView: UIView {
    private enum Metrics {
        /// The tray's thumbnail, so the two strips in this flow agree.
        static let thumbnail: CGFloat = 56
        static let corner: CGFloat = 10
        static let ring: CGFloat = 2
        /// Room under the picture for one line of caption.
        static let caption: CGFloat = 16
        static var cell: CGFloat { thumbnail + Spacing.xs + caption }
    }

    static var height: CGFloat { Metrics.cell }

    /// The side of one preview, which is what a caller should ask the library
    /// for — the row is taller than its pictures by a caption, and fetching at
    /// `height` would pull a picture larger than anything shown.
    static var thumbnailSide: CGFloat { Metrics.thumbnail }

    /// Called with the look the viewer picked.
    var onPick: ((MediaFilter) -> Void)?

    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private var buttons: [MediaFilter: FilterChip] = [:]
    private var selected: MediaFilter = .original

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        scroller.showsHorizontalScrollIndicator = false
        // ⚠️ THE BAND HAS NO BACKGROUND, SO NEITHER DOES THIS. A scroller with a
        // ground of its own would put the plate back that the band exists to
        // avoid.
        scroller.backgroundColor = .clear
        scroller.clipsToBounds = false

        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false

        scroller.addSubview(row)
        scroller.pin(to: self)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.cell)
        ])

        for filter in MediaFilter.allCases {
            let chip = FilterChip(
                filter: filter, side: Metrics.thumbnail,
                corner: Metrics.corner, ring: Metrics.ring, captionHeight: Metrics.caption
            )
            chip.onTap = { [weak self] in self?.pick(filter) }
            buttons[filter] = chip
            row.addArrangedSubview(chip)
        }
        buttons[.original]?.setChosen(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ **CENTRED WHILE IT FITS, EDGE TO EDGE ONCE IT DOES NOT** — the tray
    /// computes the same inset for the same reason: neither a scroll view nor a
    /// collection view has an alignment to set.
    override func layoutSubviews() {
        super.layoutSubviews()
        let count = CGFloat(MediaFilter.allCases.count)
        let content = count * Metrics.thumbnail + (count - 1) * Spacing.sm
        let side = max(Spacing.lg, (bounds.width - content) / 2)
        guard abs(scroller.contentInset.left - side) > 0.5 else { return }
        scroller.contentInset.left = side
        scroller.contentInset.right = side
    }

    /// Hands every chip the picture to show itself in, wearing the rest of
    /// the page's look — its dials and its effect — under each chip's preset.
    ///
    /// ⚠️ **THE WHOLE LOOK, NOT THE PRESET ALONE.** A chip is a promise of what
    /// the page will look like once it is tapped; a page whose brightness is
    /// raised would otherwise be offered nine looks darker than any it can wear.
    func show(_ image: UIImage?, wearing look: FrameLook = .neutral) {
        dressedIn = look
        for (filter, chip) in buttons {
            let chipLook = FrameLook(preset: filter, adjustments: look.adjustments, effect: look.effect)
            chip.show(image.map { MediaLookThumbnails.dressed($0, in: chipLook) })
        }
    }

    /// The dials and effect the chips were last dressed in (their presets are
    /// their own).
    private(set) var dressedIn = FrameLook.neutral

    /// States the selection without announcing it — for restoring a per-item
    /// choice when the viewer swipes to another picture.
    func setSelected(_ filter: MediaFilter) {
        guard filter != selected else { return }
        buttons[selected]?.setChosen(false)
        selected = filter
        buttons[filter]?.setChosen(true)
    }

    private func pick(_ filter: MediaFilter) {
        setSelected(filter)
        onPick?(filter)
    }

    /// Internal for tests: which look is ringed.
    var debugSelected: MediaFilter { selected }
    /// Internal for tests: the looks offered, in order.
    var debugFilters: [MediaFilter] { MediaFilter.allCases }
    /// Internal for tests: whether every chip has a picture yet.
    var debugAllChipsHaveAPicture: Bool { buttons.values.allSatisfy(\.hasPicture) }
    /// Internal for tests: the picture on one chip.
    func debugPicture(for filter: MediaFilter) -> UIImage? { buttons[filter]?.image }

    /// Internal for tests: the ring a chip is wearing — its colour and its
    /// width, which is zero when the chip is not the chosen one.
    func debugRing(for filter: MediaFilter) -> (colour: UIColor?, width: CGFloat)? {
        buttons[filter].map { ($0.ringColour, $0.ringWidth) }
    }
    /// Internal for tests: presses a chip the way a finger would.
    func debugTap(_ filter: MediaFilter) { pick(filter) }

    /// Internal for tests: whether a drag starting on a chip is handed to the
    /// scroll rather than kept by the chip's button.
    func debugScrollWinsADragOver(_ view: UIView) -> Bool {
        scroller.touchesShouldCancel(in: view)
    }

    /// Internal for tests: whether `other` is made to wait for the row's own pan.
    func debugRowIsAskedBefore(_ other: UIGestureRecognizer) -> Bool {
        scroller.gestureRecognizer(scroller.panGestureRecognizer, shouldBeRequiredToFailBy: other)
    }

    /// Internal for tests: the row's own scroller, to ask the question of a
    /// recogniser that genuinely belongs to it.
    var debugScroller: UIScrollView { scroller }

    /// Internal for tests: the chips, to ask the question of a real one.
    func debugChips() -> [UIView] {
        row.arrangedSubviews
    }
}

/// The row's scroller, which hands a drag to the scroll rather than to the
/// button under the finger.
///
/// ⚠️ **A `UIControl` REFUSES TO GIVE UP A TOUCH, AND EVERY CHIP IS ONE.**
/// `UIScrollView.touchesShouldCancel(in:)` returns **false** for a `UIControl` by
/// default — the documented behaviour — so a drag that begins on a chip is held
/// by its button and the row does not move. Every chip carries a full-surface
/// `UIButton`, which is what makes it tappable at all, so without this override
/// the row can only be scrolled from the 8pt gutters between chips.
///
/// Reported from a device: scrolling worked from some places and not others,
/// which is exactly the shape of a row that only moves when the finger misses a
/// button.
/// ⚠️ **ONE DEFINITION, TWO USERS.** It was file-private while the filter row was
/// the only strip of chips in this band; `MediaCropToolsView`'s row of shapes sits
/// in the same band, competes with the same three outside pans, and would have
/// needed a byte-for-byte copy of every rule below. `CarouselBackSwipe.edgeWidth`
/// states the same reasoning: two copies of an arbitration rule drift, and the
/// drift is invisible until a drag goes missing on one of them.
final class ChipScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    /// ⚠️ **THE ROW IS ASKED BEFORE ANYTHING OUTSIDE IT.** A drag that begins in
    /// the row competes with pans that live on ancestors — the sheet's own
    /// dismissal pan, and the stack's back-swipe — and losing that race is why
    /// the row sometimes refused to move. Returning true here means *this* pan
    /// must fail before the outsider may begin, which is the priority the row
    /// needs.
    ///
    /// ⚠️ **AND ONLY AGAINST OUTSIDERS.** Recognisers belonging to the row's own
    /// subtree (a chip's button, chiefly) must keep their normal relationship, or
    /// tapping a look would start waiting on a scroll that never begins.
    ///
    /// ⚠️ **A "COST" WAS STATED HERE AND IT WAS AN INFERENCE, NOT A MEASUREMENT —
    /// IT WAS WRONG.** This comment claimed the sheet could no longer be pulled
    /// shut by dragging the filter row, and called that the right trade. Measured
    /// on a device with distance AND speed matched — a 139pt flick at ~3000pt/s
    /// from the row (y 729→868) against the identical flick from the canvas
    /// (y 560→699) — **both dismiss the sheet.** There is no trade.
    ///
    /// The reason is what this rule actually grants: **first refusal, not
    /// ownership.** A vertical drag fails the row's horizontal pan almost at once,
    /// the dependency is satisfied, and the sheet's dismissal pan proceeds
    /// untouched. The row wins the horizontal drags it needs and costs the
    /// vertical ones nothing.
    ///
    /// ⚠️ **A WEAK DRAG PROVES NOTHING HERE.** 130pt at ~500pt/s dismisses from
    /// NOWHERE — row or canvas — so a null from one of those looked exactly like
    /// this rule swallowing the gesture. Dismissal is velocity-dominated: any
    /// future check must match SPEED, not merely distance.
    /// ⚠️ **NOT AN `override`.** `UIScrollView` adopts `UIGestureRecognizerDelegate`
    /// but does not implement this method, so there is nothing to override — the
    /// compiler says so plainly. `touchesShouldCancel(in:)` above IS the
    /// superclass's and does take the keyword; the two look alike and are not.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else { return false }
        guard let owner = other.view else { return true }
        return !owner.isDescendant(of: self)
    }
}

/// One look: the picture, and its name underneath.
private final class FilterChip: UIView {
    private let picture = UIImageView()
    private let caption = UILabel()
    private let button = UIButton(type: .custom)

    var onTap: (() -> Void)?
    var hasPicture: Bool { picture.image != nil }
    var image: UIImage? { picture.image }

    init(filter: MediaFilter, side: CGFloat, corner: CGFloat, ring: CGFloat, captionHeight: CGFloat) {
        super.init(frame: .zero)

        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = corner
        picture.layer.cornerCurve = .continuous
        // ⚠️ **WHITE, AND LITERALLY WHITE — THE BAND'S SELECTION COLOUR.** The
        // ring used to be `.tintColor`, which drew it blue; every other row in
        // this band marks its choice in white (charter F28: *"the chosen one is
        // white with black ink, the white the selection is drawn in"*), and a
        // chip ringed blue while the transitions beside it ringed white read as
        // two different kinds of chosen. Being literal, it also needs no
        // re-stating when light and dark change — which is why the trait
        // registration that used to stand here is gone.
        picture.layer.borderColor = UIColor.white.cgColor
        picture.layer.borderWidth = 0
        picture.translatesAutoresizingMaskIntoConstraints = false

        caption.text = filter.name
        caption.font = .preferredFont(forTextStyle: .caption2)
        caption.adjustsFontForContentSizeCategory = true
        caption.textAlignment = .center
        caption.textColor = .secondaryLabel
        caption.translatesAutoresizingMaskIntoConstraints = false

        button.accessibilityLabel = filter.name
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)

        addSubview(picture)
        addSubview(caption)
        // ⚠️ LAST, AND THAT IS THE POINT: `pin(to:)` begins with `addSubview`, so
        // the button lands in front of the picture and the caption and takes the
        // touch for both.
        button.pin(to: self)

        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: side),
            picture.heightAnchor.constraint(equalToConstant: side),
            caption.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: Spacing.xs),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.heightAnchor.constraint(equalToConstant: captionHeight),
            // ⚠️ **THE CHIP HAD NO HEIGHT FROM BELOW, AND THAT IS WHAT KILLED THE
            // TAP.** Without this the chip measured 56x34 while its picture
            // measured 56x56: the image overflowed the chip by 22pt, visible but
            // OUTSIDE it, and `button.pin(to: self)` inherited the same 34pt. A
            // finger aimed at the middle of a thumbnail landed below the button
            // and nothing happened — the row rendered perfectly and answered no
            // touch at all. Measured with a frame probe, after a device tap moved
            // nothing.
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: side)
        ])
        self.ring = ring
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var ring: CGFloat = 2

    func show(_ image: UIImage?) { picture.image = image }

    func setChosen(_ chosen: Bool) {
        picture.layer.borderWidth = chosen ? ring : 0
        caption.textColor = chosen ? .label : .secondaryLabel
    }

    /// Internal for tests: what the ring is drawn in, and how wide it is.
    var ringColour: UIColor? { picture.layer.borderColor.map(UIColor.init(cgColor:)) }
    var ringWidth: CGFloat { picture.layer.borderWidth }
}
