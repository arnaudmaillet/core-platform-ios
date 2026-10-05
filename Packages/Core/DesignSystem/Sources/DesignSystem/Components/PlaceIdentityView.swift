import UIKit

/// A place's identity row — a country's or a city's — laid out as the
/// profile's (`ProfileHeaderView`): its round FLAG where the avatar stands,
/// the rank in a bubble over the flag's bottom-trailing rim, and beside it
/// the title over the counters, the block centred on the flag.
///
/// ```
///  ╭────╮ Spain  Europe            ╭────╮ Central African Republic
///  │ 🇪🇸 │  38K    35              │ 🇨🇫 │ Africa
///  ╰─#19╯ Likes  Posts   ·    ·    ╰#126╯  8.7K    5
///                                         Likes  Posts   ·    ·
/// ```
///
/// One component for the two places it is drawn — a locked country's unlock
/// sheet (Maps) and a place's page (Feed) — so they cannot drift apart.
///
/// - The TITLE (`PlaceTitleLabel`) is the name, and after it on its line its
///   subtitle (a country's continent, a city's country) — or under it when
///   the two do not fit; the name is always ONE line, cut with "…".
/// - The COUNTERS are the profile's columns (`PlaceStatView`), the figure
///   over its word, in the first of `counterParts` equal parts across the
///   column, the last ones kept free.
/// - The title over the counters at a fixed gap, the block CENTRED on the
///   flag: with no case for the title's length, the title's middle stands at
///   the same height on one line or two, and the counters come up by half a
///   line when it takes one. On two lines the block is the flag's height.
///
/// Page ink by default; a place page standing it on a picture gives each
/// half the picture's ink (`setTitleInk`, `setCountersInk`).
public final class PlaceIdentityView: UIView {
    /// A counter: its figure ("38K") and the word for what it counts.
    public struct Counter: Equatable, Sendable {
        public let value: String
        public let caption: String

        public init(value: String, caption: String) {
            self.value = value
            self.caption = caption
        }
    }

    /// The flag's side: the profile avatar's, so the app's identity rows read
    /// as one.
    public static let flagSide: CGFloat = 96
    /// The flag's Dynamic-Type ceiling — the avatar's.
    public static let flagMaxSide: CGFloat = 110
    /// The equal parts the counters' row is cut into; the counters fill the
    /// first ones, in order.
    public static let counterParts = 4
    /// The air between the title and the counters: on two lines, the block
    /// is then as tall as the flag.
    public static let titleToCounters: CGFloat = Spacing.sm

    /// The round flag — or, for a place with none, a neutral disc.
    public let flagView = PlaceFlagView()
    /// "#19" over the flag's rim; hidden without a rank.
    public let rankBubble = PlaceRankBubble()
    /// The name and its subtitle.
    public let titleLabel: PlaceTitleLabel
    /// The counters' row: `counterParts` equal parts.
    public let countersRow = UIStackView()
    /// The counters, in order — each centred in its part.
    public private(set) var statViews: [PlaceStatView] = []
    /// The title over the counters.
    public let column = UIStackView()

    public init(flag: UIImage?, name: String, subtitle: String?, counters: [Counter], rank: String?) {
        titleLabel = PlaceTitleLabel(name: name, subtitle: subtitle ?? "")
        super.init(frame: .zero)

        flagView.contentMode = .scaleAspectFit
        flagView.clipsToBounds = true
        flagView.accessibilityIdentifier = "place.identity.flag"
        // No intrinsic size: the bitmap's would be an unopposed preference
        // for the flag's side (the profile avatar's trap).
        flagView.setContentHuggingPriority(.init(1), for: .vertical)
        flagView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        setFlag(flag)
        rankBubble.accessibilityIdentifier = "place.identity.rank"
        setRank(rank)
        let flagBox = UIView()
        for view in [flagView, rankBubble] {
            view.translatesAutoresizingMaskIntoConstraints = false
            flagBox.addSubview(view)
        }

        // FOUR EQUAL PARTS across the column, each counter centred in its
        // own, the last ones kept free — so the columns stand where four
        // would, whatever their figures' widths.
        statViews = counters.prefix(Self.counterParts).map { PlaceStatView(value: $0.value, caption: $0.caption) }
        for index in 0..<Self.counterParts {
            let part = UIView()
            part.accessibilityIdentifier = "place.identity.counterPart"
            countersRow.addArrangedSubview(part)
            guard index < statViews.count else { continue }
            let stat = statViews[index]
            stat.translatesAutoresizingMaskIntoConstraints = false
            part.addSubview(stat)
            NSLayoutConstraint.activate([
                stat.topAnchor.constraint(equalTo: part.topAnchor),
                stat.bottomAnchor.constraint(equalTo: part.bottomAnchor),
                stat.centerXAnchor.constraint(equalTo: part.centerXAnchor),
                stat.leadingAnchor.constraint(greaterThanOrEqualTo: part.leadingAnchor),
            ])
        }
        countersRow.alignment = .fill
        countersRow.distribution = .fillEqually

        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(countersRow)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Self.titleToCounters

        let row = UIStackView(arrangedSubviews: [flagBox, column])
        row.alignment = .center
        row.spacing = Spacing.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // The side is high and the flag at least the column's height at 999:
        // a Dynamic-Type title that outgrows the disc grows the flag with it
        // up to its cap, and past the cap the column outgrows it rather than
        // clipping a label — the profile's avatar rule.
        let side = flagView.heightAnchor.constraint(equalToConstant: Self.flagSide)
        side.priority = .defaultHigh
        let spans = flagView.heightAnchor.constraint(greaterThanOrEqualTo: column.heightAnchor)
        spans.priority = .init(999)
        // A wide rank ("#126") slides LEFT over the disc rather than being
        // truncated against its cap.
        let rankCentre = rankBubble.centerXAnchor.constraint(equalTo: flagView.trailingAnchor, constant: -14)
        rankCentre.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            flagView.topAnchor.constraint(equalTo: flagBox.topAnchor),
            flagView.leadingAnchor.constraint(equalTo: flagBox.leadingAnchor),
            flagView.trailingAnchor.constraint(equalTo: flagBox.trailingAnchor),
            flagView.bottomAnchor.constraint(equalTo: flagBox.bottomAnchor),
            flagView.widthAnchor.constraint(equalTo: flagView.heightAnchor),
            side,
            flagView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.flagMaxSide),
            spans,
            // The bubble straddles the disc's rim at its bottom-trailing
            // corner, as a badge does: it may overhang into the gap beside it,
            // never into the column.
            rankBubble.bottomAnchor.constraint(equalTo: flagView.bottomAnchor, constant: -2),
            rankBubble.trailingAnchor.constraint(lessThanOrEqualTo: flagView.trailingAnchor, constant: Spacing.md - 4),
            rankCentre,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The round flag; nil draws a neutral disc.
    public func setFlag(_ image: UIImage?) {
        flagView.image = image
        flagView.backgroundColor = image == nil ? .tertiarySystemFill : .clear
    }

    /// "#19"; nil hides the bubble.
    public func setRank(_ rank: String?) {
        rankBubble.text = rank
        rankBubble.isHidden = rank == nil
    }

    /// New figures for the counters, in order — the words stay.
    public func setCounterValues(_ values: [String]) {
        for (stat, value) in zip(statViews, values) { stat.setValue(value) }
    }

    /// New figures and words for the counters, in order ("1 Post").
    public func setCounters(_ counters: [Counter]) {
        for (stat, counter) in zip(statViews, counters) {
            stat.setValue(counter.value)
            stat.setCaption(counter.caption)
        }
    }

    /// The title's ink: the page's (nil), or a picture's.
    public func setTitleInk(_ tone: HeroInk.Tone?) {
        titleLabel.setInk(tone)
    }

    /// The counters' ink: the page's (nil), or a picture's.
    public func setCountersInk(_ tone: HeroInk.Tone?) {
        for stat in statViews { stat.setInk(tone) }
    }

    /// Each counter's own ink, in order — over a picture, each column reads
    /// the ground behind IT: two columns stand far apart, and one ink for
    /// the row is the worse of two grounds.
    public func setCounterInks(_ tones: [HeroInk.Tone?]) {
        for (stat, tone) in zip(statViews, tones) { stat.setInk(tone) }
    }
}

/// The flag's disc. It ROUNDS ITSELF, in its own layout pass: the row's
/// pass runs before the nested stacks give the disc its final size, so a
/// radius set from there is the previous size's (`CircleAvatarView`'s trap).
public final class PlaceFlagView: UIImageView {
    override public func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// A place's name and its subtitle: on ONE line when the two fit the width,
/// the subtitle after the name, a step back; the subtitle on the NEXT line
/// when they do not. The name is always ONE line, cut with "…" when even
/// alone it is too wide ("South Georgia and the South…"); so is the subtitle.
///
/// One label, so the two lines share the text layout: the text is composed
/// for the width UIKit asks about (`textRect`) — a space between the two when
/// they fit, a line break when they do not, each line cut to the width by
/// hand (a label truncates only its LAST line).
public final class PlaceTitleLabel: UILabel {
    public let name: String
    public let subtitle: String

    init(name: String, subtitle: String) {
        self.name = name
        self.subtitle = subtitle
        super.init(frame: .zero)
        // Never more than the name's line and the subtitle's: each is cut to
        // the width before it gets here.
        numberOfLines = 2
        lineBreakMode = .byTruncatingTail
        accessibilityTraits = .header
        setContentCompressionResistancePriority(.required, for: .vertical)
        compose(fits: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the subtitle stands on the name's line at the width laid out.
    public private(set) var subtitleFollowsName = true

    /// The picture's ink, or nil for the page's.
    private var tone: HeroInk.Tone?

    /// The profile's name: title3 semibold.
    private var nameFont: UIFont { .scaledFont(forTextStyle: .title3, weight: .semibold) }
    /// The profile's @handle: subheadline, secondary.
    private var subtitleFont: UIFont { .appFont(forTextStyle: .subheadline) }

    private func composed(fits: Bool, width: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let name = fits ? self.name : Self.cut(self.name, font: nameFont, to: width)
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: nameFont, .foregroundColor: tone?.primary ?? .label,
        ])
        guard !subtitle.isEmpty else { return text }
        let subtitle = fits ? self.subtitle : Self.cut(self.subtitle, font: subtitleFont, to: width)
        text.append(NSAttributedString(string: fits ? "  " : "\n", attributes: [.font: subtitleFont]))
        text.append(NSAttributedString(string: subtitle, attributes: [
            .font: subtitleFont, .foregroundColor: tone?.secondary ?? .secondaryLabel,
        ]))
        return text
    }

    /// `text` as it fits `width` on one line in `font`: whole, or its longest
    /// prefix that fits with "…".
    public static func cut(_ text: String, font: UIFont, to width: CGFloat) -> String {
        let measure = { (candidate: String) in
            (candidate as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        guard measure(text) > width else { return text }
        let characters = Array(text)
        var (low, high) = (0, characters.count)
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…"
            if measure(candidate) <= width { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The width the text was last cut for, when it does not fit one line.
    private var composedWidth: CGFloat = .greatestFiniteMagnitude

    private func compose(fits: Bool, width: CGFloat = .greatestFiniteMagnitude) {
        subtitleFollowsName = fits
        composedWidth = width
        attributedText = composed(fits: fits, width: width)
        accessibilityLabel = subtitle.isEmpty ? name : "\(name), \(subtitle)"
    }

    /// Whether the name and the subtitle fit one line `width` wide.
    public func fitsOneLine(_ width: CGFloat) -> Bool {
        let line = composed(fits: true).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        return line.width.rounded(.up) <= width
    }

    func setInk(_ tone: HeroInk.Tone?) {
        self.tone = tone
        compose(fits: subtitleFollowsName, width: composedWidth)
        HeroInk.applyShadow(to: self, tone: tone ?? .dark, onPicture: tone == nil ? 0 : 1)
    }

    override public func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        // Asked for a width (a layout pass, a fitting size): compose for it.
        // Stable: the same width always asks for the same text.
        if bounds.width > 0, bounds.width < CGFloat.greatestFiniteMagnitude / 2 {
            let fits = fitsOneLine(bounds.width)
            if fits != subtitleFollowsName || (!fits && bounds.width != composedWidth) {
                compose(fits: fits, width: fits ? .greatestFiniteMagnitude : bounds.width)
            }
        }
        return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Attributed fonts do not follow Dynamic Type on their own.
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            compose(fits: subtitleFollowsName, width: composedWidth)
        }
    }
}

/// One counter as the profile draws its own (`ProfileStatView`): the figure
/// over the word that says what it counts, centred on each other, the column
/// as wide as the wider of the two.
public final class PlaceStatView: UIView {
    public let valueLabel = UILabel()
    public let captionLabel = UILabel()

    init(value: String, caption: String) {
        super.init(frame: .zero)
        // The profile's type, capped (#482).
        valueLabel.font = .scaledSystemFont(ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .center
        captionLabel.font = .scaledSystemFont(ofSize: 12, relativeTo: .caption1, maximumPointSize: 16)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textAlignment = .center
        captionLabel.text = caption
        for label in [valueLabel, captionLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = caption
        setValue(value)
        setInk(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ value: String) {
        valueLabel.text = value
        accessibilityValue = value
    }

    func setCaption(_ caption: String) {
        captionLabel.text = caption
        accessibilityLabel = caption
    }

    /// The page's ink (nil), or a picture's: white or black by what is
    /// behind (`HeroInk`), with a soft shadow of the opposite tone.
    func setInk(_ tone: HeroInk.Tone?) {
        valueLabel.textColor = tone?.primary ?? .label
        captionLabel.textColor = tone?.secondary ?? .secondaryLabel
        for label in [valueLabel, captionLabel] {
            HeroInk.applyShadow(to: label, tone: tone ?? .dark, onPicture: tone == nil ? 0 : 1)
        }
    }
}

/// The place's rank, worn over its flag: "#4", white on a near-black capsule,
/// ringed in the page's ground so it lifts off the disc.
///
/// ⚠️ FIXED INK, NOT `.label` INVERTED. A glass sheet draws its labels
/// vibrant: in dark mode a black-on-white bubble came out white on white —
/// the figure vanished. White on a dark capsule survives both appearances.
public final class PlaceRankBubble: UIView {
    public let label = UILabel()

    public var text: String? {
        get { label.text }
        set {
            label.text = newValue
            accessibilityLabel = newValue.map { "Rank \($0.dropFirst())" }
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.1, alpha: 1)
        layer.borderColor = UIColor.systemBackground.cgColor
        layer.borderWidth = 2
        layer.cornerCurve = .continuous
        label.font = .scaledMonospacedDigitSystemFont(
            ofSize: 13, weight: .heavy, relativeTo: .caption1, maximumPointSize: 19
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // A CGColor does not follow the appearance on its own.
        layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }
}
