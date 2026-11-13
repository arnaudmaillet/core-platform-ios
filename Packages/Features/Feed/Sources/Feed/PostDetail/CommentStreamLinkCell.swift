import DesignSystem
import ThreadKit
import UIKit

/// A row of the comments panel that leads further into it (#2298):
///
/// - **Popular's last, "See all n comments"**: Popular shows only the
///   threads that fit its room (`PopularCommentsCut`); this turns to Recent,
///   the tab's own change, the selector following.
/// - **Recent's first, "Earlier comments"**: older comments load on this
///   tap only, never by themselves as the reader scrolls up, so the top of
///   what is loaded is a real edge. A small loader while the page is on its
///   way, a retry in place if it fails.
///
/// ⚠️ DRAWN AS THE BRAND'S TEXT BUTTON (#2349, the owner 2026-11-12), not as
/// a thread's fold: the two lead out of what is shown, where a fold
/// ("View n more replies…", `CommentThreadToggleRow`, grey footnote) opens
/// inside a thread — drawn alike, "See all" read as one more fold of the
/// last thread, not as the end of Popular.
///
/// - **The primary as text** (`Palette.brandText`, #2282), `subheadline`
///   semibold, its chevron in the same ink — Apple's lists end a cut section
///   with a tinted "See All".
/// - **Left-aligned on the comments' text column** (where the names and the
///   words start, `CommentRowView.replyIndent`): a centred line would break
///   the list's column, and centred is for empty states. No capsule: at the
///   bottom it would compete with the composer's glass and look like the
///   pull's pill.
/// - **A 44 pt target**, the words centred in it; 16 pt of air between it
///   and the thread on its other side (the thread row's own air above "See
///   all"; `Spacing.lg` under "Earlier comments", at the stream's top).
/// - The loader and the retry stay, the retry in the same ink.
///
/// The whole row is the target.
final class CommentStreamLinkCell: UICollectionViewCell {
    /// Where the row stands with what it leads to.
    enum State: Equatable {
        case idle
        /// The page it asked for is on its way.
        case loading
        /// The page it asked for failed: a tap asks again.
        case failed
    }

    /// Where the row stands in the stream: at its end (Popular's "See all",
    /// a thread above it), or at its top (Recent's "Earlier comments", the
    /// threads under it).
    enum Placement: Equatable {
        case end
        case top
    }

    /// What the row says and where its chevron points.
    struct Content: Equatable {
        var title: String
        var symbol: String
        var state: State = .idle
        var identifier: String
        var placement: Placement = .end
    }

    /// The type: the text button's.
    static var font: UIFont { .scaledFont(forTextStyle: .subheadline, weight: .semibold) }
    /// The ink: the primary as text (#2282), Increased Contrast included.
    static let ink: UIColor = Palette.brandText
    /// The row's target, never under a control's 44 pt.
    static let minimumTarget: CGFloat = 44
    /// Between the target and the thread on its far side.
    static let threadAir: CGFloat = Spacing.lg

    var onTap: (() -> Void)?

    private let label = UILabel()
    private let chevron = UIImageView()
    /// The branded loader (never the stock spinner, `StockSpinnerGuardTests`),
    /// shown through the kit's gate past the loader's grace (#1768).
    private let spinner = AppLoaderView(size: .medium)
    private lazy var loaderGate = LoaderGate(loader: spinner)
    private(set) var content: Content?

    /// Under the target: the threads' air under "Earlier comments", none
    /// under "See all" (the section's own inset follows it).
    private var airBelow: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Self.ink
        label.numberOfLines = 0
        chevron.tintColor = Self.ink
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        // ⚠️ ONE HEIGHT IN EVERY STATE: the spinner stands OVER the chevron,
        // out of the layout. In the row it was taller than the footnote line
        // (20 pt against ~15.7), so the row grew as its page started to load
        // and pushed the rows under it down by the difference — the list
        // moved at the tap, before the page that must not move it had even
        // landed — and shrank again off screen, where a self-sizing list
        // doesn't measure it, so the move stayed.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(arrangedSubviews: [label, chevron])
        row.axis = .horizontal
        row.spacing = Spacing.xs
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.addSubview(spinner)
        // The target: at least 44 pt, the words centred in it, with some air
        // above and below them when they wrap at a large text size.
        let target = UILayoutGuide()
        contentView.addLayoutGuide(target)
        let airBelow = target.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        self.airBelow = airBelow
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: chevron.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            target.topAnchor.constraint(equalTo: contentView.topAnchor),
            target.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            target.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            airBelow,
            target.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTarget),
            row.centerYAnchor.constraint(equalTo: target.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: target.topAnchor, constant: Spacing.sm),
            row.bottomAnchor.constraint(lessThanOrEqualTo: target.bottomAnchor, constant: -Spacing.sm),
            // On the comments' text column, where the names and words start.
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: CommentRowView.replyIndent),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
        ])
        // The target hugs its words: no taller than they and their air need.
        let hug = target.heightAnchor.constraint(equalToConstant: Self.minimumTarget)
        hug.priority = .defaultLow
        hug.isActive = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: Content) {
        self.content = content
        label.text = content.state == .failed ? Self.failedTitle : content.title
        airBelow?.constant = content.placement == .top ? -Self.threadAir : 0
        // The chevron at the words' size and weight, in their ink.
        chevron.image = UIImage(
            systemName: content.state == .failed ? "arrow.clockwise" : content.symbol,
            withConfiguration: UIImage.SymbolConfiguration(font: label.font, scale: .small)
        )
        // Hidden by alpha, never `isHidden`: the stack keeps its place.
        chevron.alpha = content.state == .loading ? 0 : 1
        if content.state == .loading {
            loaderGate.begin { [weak self] in self?.content?.state == .loading }
        } else {
            loaderGate.end()
        }
        accessibilityIdentifier = content.identifier
        accessibilityLabel = label.text
        accessibilityTraits = content.state == .loading ? [.button, .notEnabled] : .button
    }

    /// What a failed page says, in place of the row's title.
    /// Short, so it takes the line the title took: a row that wrapped on
    /// failure would move the list as well.
    static let failedTitle = "Couldn't load. Try Again"

    @objc private func tapped() {
        guard content?.state != .loading else { return }
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }

    /// The row's height at `width`, for the cut (`PopularCommentsCut`):
    /// measured through the cell itself, never displayed.
    static func height(of content: Content, width: CGFloat, sizing cell: CommentStreamLinkCell) -> CGFloat {
        guard width > 0 else { return 0 }
        cell.configure(content)
        cell.bounds.size.width = width
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        return ceil(cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    #if DEBUG
    var debugLabel: UILabel { label }
    var debugChevron: UIImageView { chevron }
    #endif
}
