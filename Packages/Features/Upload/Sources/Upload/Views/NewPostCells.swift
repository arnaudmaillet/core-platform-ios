import DesignSystem
import UIKit

/// The chosen media, laid along the top of the new-post screen in the order they
/// will publish in — the first of them being the cover.
///
/// A scroll view of image views rather than a second collection view: the count
/// is capped at twenty, none of it is reused, and a nested collection view here
/// would buy recycling nobody needs at the price of another data source.
///
/// ⚠️ **NO CARD BEHIND IT.** This strip is the subject of its section, not a row
/// in a settings list, so its section is drawn plain and its cell background is
/// cleared. A white platter behind pictures reads as a frame nobody asked for.
final class NewPostMediaCell: UICollectionViewListCell {
    private enum Metrics {
        /// Tall enough to judge a photograph by, which a 72pt chip was not.
        static let height: CGFloat = 208
        /// ⚠️ **9:16, AND THE RATIO IS THE POINT.** These were 3:4 — the same
        /// shape the debug fixture renders its portrait tiles at — so fitting
        /// such a picture into such a frame letterboxed by ZERO and made fill
        /// and fit pixel-identical. A screenshot could not tell them apart, and
        /// I read that as the feature being broken. A 9:16 frame is narrower
        /// than any photograph it will hold, so fitting always shows ground and
        /// filling always crops: the choice becomes visible on sight.
        static let width: CGFloat = (208 * 9 / 16).rounded()
        static let corner: CGFloat = 14
    }

    /// ⚠️ A `CarouselScrollView`, NOT A PLAIN ONE: at its leading edge it
    /// declines a rightward drag so the stack's back-swipe can carry the screen
    /// back. See `CarouselBackSwipe`.
    private let scroller = CarouselScrollView()
    private let row = UIStackView()
    /// What the strip currently stands for, so a re-configure of the same
    /// selection in the same order does not rebuild and re-fetch it.
    private var shown: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.clipsToBounds = false
        // ⚠️ COMPUTED IN `layoutSubviews`, NOT FIXED HERE. The strip centres its
        // thumbnails while they fit and runs edge to edge once they do not, so
        // the side room depends on the count and the width — see
        // `centreContentIfItFits`. A constant stated here would add to that and
        // push a centred row off-centre by exactly one margin.
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: 0, bottom: Spacing.sm, trailing: 0
        ))
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⚠️ A VIDEO IS MARKED, NOT HIDDEN. It cannot be published yet — the
    /// library seam vends images only — and the screen's footer says so. Drawing
    /// them anyway, badged, is what keeps the strip honest about the selection
    /// the viewer actually made.
    ///
    /// ⚠️ **THE COVER IS NAMED, NOT ASSUMED TO BE FIRST.** Only photos publish,
    /// so if the viewer's first pick is a video the leading tile is NOT what the
    /// feed will show this post by — badging index 0 would promise a cover that
    /// never arrives, which is the very thing §22 exists to stop. The screen
    /// says which item is the cover and this draws that one.
    /// ⚠️ **THE THUMBNAILS HONOUR THE EDITOR'S CHOICE.** A picture the author
    /// chose to show WHOLE must not come back cropped one screen later — the
    /// strip is the same media, so it obeys the same decision.
    func show(
        _ items: [MediaLibraryItem],
        coverID: String?,
        fits: [String: ContentFit] = [:],
        thumbnail: @escaping @MainActor (String, CGSize) async -> UIImage?
    ) {
        // ⚠️ THE KEY CARRIES EACH TILE'S FIT, NOT JUST ITS IDENTITY. The same
        // pictures in the same order can still need redrawing, because the
        // author may have changed one from filled to whole in the editor.
        let wanted = items.map { "\($0.id)=\(fits[$0.id] ?? .fill)" }
        guard wanted != shown else { return }
        shown = wanted
        for view in row.arrangedSubviews { view.removeFromSuperview() }

        let size = CGSize(width: Metrics.width * 2, height: Metrics.height * 2)
        for item in items {
            let picture = UIImageView()
            picture.contentMode = (fits[item.id] ?? .fill).mode
            picture.clipsToBounds = true
            // ⚠️ BLACK, NOT A GREY FILL. In a 9:16 frame a fitted picture shows
            // its ground on two sides, and that ground IS the letterbox — it
            // should read as the editor's canvas does, not as a placeholder
            // still waiting for an image.
            picture.backgroundColor = .black
            picture.layer.cornerRadius = Metrics.corner
            picture.layer.cornerCurve = .continuous
            picture.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picture.widthAnchor.constraint(equalToConstant: Metrics.width),
                picture.heightAnchor.constraint(equalToConstant: Metrics.height)
            ])
            picture.isAccessibilityElement = true
            let isCover = item.id == coverID
            picture.accessibilityLabel = Self.label(for: item, isCover: isCover)

            if isCover {
                picture.addSubview(Self.badge(text: "Cover"))
            }
            if item.isVideo {
                let badge = UIImageView(image: UIImage(systemName: "video.slash.fill"))
                badge.tintColor = .white
                badge.translatesAutoresizingMaskIntoConstraints = false
                picture.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: -Spacing.sm),
                    badge.bottomAnchor.constraint(equalTo: picture.bottomAnchor, constant: -Spacing.sm)
                ])
            }

            row.addArrangedSubview(picture)
            let id = item.id
            Task { [weak picture] in
                let image = await thumbnail(id, size)
                picture?.image = image
            }
        }
    }

    #if DEBUG
    /// Internal for tests: how each thumbnail lays its picture, in strip order.
    ///
    /// ⚠️ **ASKED OF THE STRIP, NOT HUNTED FOR IN THE WINDOW.** A recursive
    /// search for `UIImageView` also finds the video badge, which would make the
    /// count wrong and the order meaningless. And a screenshot cannot answer
    /// this at all: the tiles are pinned to 156x208, which IS 3:4, so a 3:4
    /// picture fitted into one letterboxes by ZERO — fill and fit are
    /// pixel-identical for those items.
    var debugContentModes: [UIView.ContentMode] {
        row.arrangedSubviews.compactMap { ($0 as? UIImageView)?.contentMode }
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        centreContentIfItFits()
    }

    /// Centres the thumbnails while they fit, and lets them run edge to edge
    /// once they do not — the same rule the picker's tray follows.
    private func centreContentIfItFits() {
        let count = row.arrangedSubviews.count
        guard count > 0, bounds.width > 0 else { return }
        let content = CGFloat(count) * Metrics.width + CGFloat(count - 1) * Spacing.sm
        let side = max(Spacing.lg, (bounds.width - content) / 2)
        guard abs(scroller.contentInset.left - side) > 0.5 else { return }
        scroller.contentInset.left = side
        scroller.contentInset.right = side
    }

    private static func label(for item: MediaLibraryItem, isCover: Bool) -> String {
        let subject = item.isVideo ? "Video, can't be posted yet" : "Photo"
        return isCover ? "\(subject), the cover" : subject
    }

    /// A small capsule laid on the picture. Pinned inside its host on the way
    /// out, so the caller only has to add it.
    private static func badge(text: String) -> UIView {
        CoverBadgeHost(text: text)
    }
}

/// The "Cover" capsule, positioned against whatever picture it is added to.
///
/// ⚠️ **A BADGE CANNOT CONSTRAIN ITSELF BEFORE IT HAS A PARENT.** Building the
/// capsule and pinning it in the same breath needs the superview, which does not
/// exist until `addSubview`. This view does its own pinning in
/// `didMoveToSuperview`, so the caller adds it and nothing else.
private final class CoverBadgeHost: UIView {
    /// ⚠️ **NO EFFECT AT BIRTH.** Materialising a `UIBlurEffect` in an
    /// initializer contacts the render server, and on a headless CI simulator
    /// that stalled the main actor ~45s and reddened an unrelated suite
    /// (PR #46). The effect is set in `didMoveToWindow`, which is the same
    /// recipe the comment ticker and `ProgressiveBlurView` follow.
    private let frost = UIVisualEffectView(effect: nil)
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false

        label.text = text
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white

        frost.clipsToBounds = true
        frost.layer.cornerCurve = .continuous
        frost.pin(to: self)
        label.pin(to: frost.contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.xs / 2, leading: Spacing.sm,
            bottom: Spacing.xs / 2, trailing: Spacing.sm
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, frost.effect == nil else { return }
        frost.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let host = superview else { return }
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor, constant: Spacing.sm),
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Spacing.sm)
        ])
    }

    /// ⚠️ **A PERFECT PILL IS HALF THE HEIGHT, AND ONLY LAYOUT KNOWS IT.** The
    /// previous radius was a fixed 10pt with a comment claiming the frame
    /// clamped it — nothing clamps a corner radius, so at Dynamic Type sizes
    /// either side of the default it read as a rounded rectangle rather than a
    /// capsule.
    override func layoutSubviews() {
        super.layoutSubviews()
        frost.layer.cornerRadius = bounds.height / 2
    }
}

/// A row whose whole content is one button — "Change cover".
///
/// A button rather than a selectable list row, because it opens a menu: the
/// menu has to hang off a view UIKit can present from, and a list cell's
/// selection is not one.
final class NewPostButtonCell: UICollectionViewListCell {
    private let button = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        // Centred in the screen, not tucked against the leading edge: it is the
        // one action belonging to the strip above it, so it sits under its
        // middle rather than beside its first tile.
        button.contentHorizontalAlignment = .center
        button.configuration?.contentInsets = .zero
        button.pin(to: contentView, insets: NSDirectionalEdgeInsets(
            top: Spacing.xs, leading: 0, bottom: Spacing.xs, trailing: 0
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbolName: String, menu: UIMenu, isEnabled: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePadding = Spacing.sm
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.menu = menu
        button.isEnabled = isEnabled
    }
}

/// The title field.
///
/// ⚠️ **DRAWN, TYPED INTO, AND NOT SENT** (`dev/BACKEND_GAPS.md` §21).
/// `post.v1` has exactly one free-text field, `caption`, and folding a title
/// into it would publish a composite string no reader could split back apart.
final class NewPostTitleCell: UICollectionViewListCell {
    private let field = UITextField()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.font = .preferredFont(forTextStyle: .headline)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = "Add a title"
        field.returnKeyType = .next
        field.addAction(
            UIAction { [weak self] action in
                guard let field = action.sender as? UITextField else { return }
                self?.onChange?(field.text ?? "")
            },
            for: .editingChanged
        )
        // ⚠️ INTERNAL MARGINS ARE STATED, NOT INHERITED. Pinned to the content
        // view's edges the text runs into the card's rounded corner and is
        // clipped by it — which is exactly how this first shipped.
        field.pin(to: contentView, insets: Self.textInsets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The padding that keeps text clear of an inset-grouped card's corner.
    /// Shared with the caption below, so the two fields line up.
    static let textInsets = NSDirectionalEdgeInsets(
        top: Spacing.md, leading: Spacing.sm, bottom: Spacing.md, trailing: Spacing.sm
    )

    func configure(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        if field.text != text { field.text = text }
    }
}

/// The caption field.
///
/// A `UITextView` with a placeholder LABEL beside it, and a height that grows
/// with the text to a ceiling — the recipe Feed's `CommentsInputBar` uses, which
/// cannot be imported here (features do not import one another) and is small
/// enough to restate rather than promote.
///
/// ⚠️ **A `UITextView` HAS NO PLACEHOLDER.** The label is a real sibling toggled
/// on `hasText`; every "placeholder" on a text view in UIKit is this.
final class NewPostCaptionCell: UICollectionViewListCell {
    private enum Metrics {
        static let minimumHeight: CGFloat = 96
        static let maximumHeight: CGFloat = 220
    }

    private let field = UITextView()
    private let placeholder = UILabel()
    private var heightConstraint: NSLayoutConstraint!
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        // ⚠️ **ALWAYS SCROLLABLE, SO THERE IS NO SWITCH LEFT TO MISS.** This was
        // false, with scrolling turned on once the text passed a ceiling — a flip
        // that never fired because the comparison landed exactly on its own edge
        // (`fitting > maximumHeight`, both 220). Scrolling from the start deletes
        // the flip rather than repairing it. See `resize()` for the measurement,
        // and for the wrong mechanism I first wrote there.
        field.isScrollEnabled = true
        field.delegate = self

        placeholder.text = "Write a caption…"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0

        // The same internal margins the title wears — see the note there.
        field.pin(to: contentView, insets: NewPostTitleCell.textInsets)
        placeholder.constrain(in: contentView) { _ in
            placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor)
            placeholder.trailingAnchor.constraint(equalTo: field.trailingAnchor)
            placeholder.topAnchor.constraint(equalTo: field.topAnchor)
        }
        heightConstraint = field.heightAnchor.constraint(equalToConstant: Metrics.minimumHeight)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        if field.text != text { field.text = text }
        placeholder.isHidden = field.hasText
        resize()
    }

    /// ⚠️ **THE FIRST MEASUREMENT USED TO BE THE ONLY ONE, AND IT WAS TAKEN AT
    /// ZERO WIDTH.** `configure` runs before the cell has a rectangle — measured
    /// `width=0.0 fitting=22.0` — and nothing re-ran it afterwards: not a layout
    /// pass, not even focusing the field, which was confirmed by the probe
    /// staying at a single line through both. Re-running it here is what gives
    /// the caption a real width to measure against.
    override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ **THE CELL'S LAYOUT PASS SIZES `contentView`, NOT ITS SUBVIEWS.**
        // Measured right here: `contentW=370.0` while `field.bounds.width` was
        // still `0.0`. The container had just been given its frame; the field's
        // own constraints resolve in a LATER pass, so a measurement taken now
        // describes a zero-width text container and `contentSize` means nothing.
        // That is why adding this override did not, on its own, fix the
        // first-measurement bug — the probe still read `width=0.0` from here.
        //
        // Laying the content out first is what hands the measurement a real
        // width. The guard in `resize()` is what stops the extra pass looping.
        contentView.layoutIfNeeded()
        resize()
    }

    /// Grows to a ceiling, then scrolls past it, so a long caption never pushes
    /// the settings off the screen.
    private func resize() {
        // ⚠️ **`contentSize` — AND THE FIRST EXPLANATION WRITTEN HERE WAS WRONG.**
        // It claimed `sizeThatFits` was clamped by the very ceiling it existed to
        // detect crossing, citing `fitting=220.0` across 450 consecutive calls as
        // proof. That was a coincidence dressed as a mechanism: 449 characters at
        // this width are genuinely 220pt tall, and the ceiling is also 220.
        // Doubling the text settled it — `fitting` went to 418.0, so nothing was
        // ever clamped.
        //
        // What the old rule actually died on was the strict comparison landing on
        // that knife edge: `fitting > maximumHeight` with both at exactly 220 is
        // false, so scrolling never switched on. Measuring `contentSize` against
        // a view that always scrolls deletes the flip, so there is no edge left
        // to land on — and the symptom the viewer reported (four lines, the rest
        // unreachable) came from the CELL never re-measuring, not from here.
        let fitting = field.contentSize.height
        let height = min(max(fitting, Metrics.minimumHeight), Metrics.maximumHeight)
        // ⚠️ THE GUARD ALSO BREAKS THE LAYOUT LOOP. `layoutSubviews` calls this,
        // and this invalidates the cell's measurement — which lays out again.
        // Bailing once the height has settled is what stops that going round.
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        // ⚠️ **AND THE CELL HAS TO BE TOLD, MEASURED AFTER LAYOUT.** With the
        // constraint reading 220 the cell was still 120: a self-sizing list cell
        // does not re-measure itself because a constraint inside it moved, so the
        // caption was clipped on top of never scrolling.
        invalidateIntrinsicContentSize()
    }
}

extension NewPostCaptionCell: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = textView.hasText
        resize()
        onChange?(textView.text ?? "")
        keepCaretVisible()
    }

    /// Arrow keys, a tap into the middle of the text, or the selection moving
    /// after a paste — all of them can put the caret outside the window without
    /// the text changing at all.
    func textViewDidChangeSelection(_ textView: UITextView) {
        keepCaretVisible()
    }
}

private extension NewPostCaptionCell {
    /// ⚠️ **GROWING TO A CEILING IS ONLY HALF A TEXT AREA.** Once the field has
    /// reached its maximum height it scrolls, and from that moment a caret that
    /// walks off the top or the bottom is invisible while you are typing into
    /// it. `scrollRangeToVisible` follows the CARET; the height rule only
    /// follows the text.
    ///
    /// ⚠️ Deferred a turn on purpose: when the delegate fires, the layout
    /// manager has not yet laid out the glyph just typed, so asking to reveal
    /// the selection now scrolls to where the caret USED to be.
    func keepCaretVisible() {
        guard field.isScrollEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, field.isScrollEnabled else { return }
            field.scrollRangeToVisible(field.selectedRange)
        }
    }
}
