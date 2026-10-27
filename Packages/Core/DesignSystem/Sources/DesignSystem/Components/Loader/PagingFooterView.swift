import UIKit

/// THE footer under a list's last loaded page (#1768): a quiet spinner while
/// the next page is on its way, "Couldn't load more. Try Again" after one
/// failed — the one shape of the seven footers the 2026-10-27 audit counted.
///
/// Deliberately small. It appears *under a full list*: the viewer already has
/// plenty to look at and simply scrolled, so anything larger reads as the
/// screen reloading rather than as the list continuing. (A first load is the
/// opposite situation and gets the opposite treatment: the screen's skeleton.)
///
/// It turns only while its host says so (`state`): an endless spinner under
/// rows the viewer is not looking at still redraws the screen every frame
/// (#580).
public final class PagingFooterView: UIView {
    public enum State: Equatable, Sendable {
        /// Nothing: no next page, or none asked yet.
        case idle
        /// The next page is on its way.
        case loading
        /// The next page failed: Try Again.
        case failed
    }

    /// The footer's height: a row's, and room for the spinner.
    public static let height: CGFloat = 56

    public var state: State = .idle {
        didSet { if state != oldValue { apply() } }
    }

    /// Try Again. Nil when the host's own selection retries (a list cell):
    /// the footer then lets the touch through.
    public var onRetry: (() -> Void)? {
        didSet { isUserInteractionEnabled = onRetry != nil }
    }

    /// What VoiceOver reads while loading — "Loading more people".
    public var loadingAccessibilityLabel = "Loading more" {
        didSet { apply() }
    }

    private let spinner = AppLoaderView(size: .medium)
    private let failure = UILabel()

    public init(state: State = .idle) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height))
        isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        spinner.constrain(in: self) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.adjustsFontForContentSizeCategory = true
        failure.attributedText = Self.failureText
        failure.constrain(in: self) { parent in
            failure.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            failure.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            failure.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.lg)
            failure.topAnchor.constraint(greaterThanOrEqualTo: parent.topAnchor, constant: Spacing.md)
            failure.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -Spacing.md)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retry)))
        isAccessibilityElement = true
        self.state = state
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The table-footer spelling: spinning, or nothing.
    public func setSpinning(_ spinning: Bool) {
        state = spinning ? .loading : .idle
    }

    /// Whether the spinner turns.
    public var isSpinning: Bool { spinner.isAnimating }
    /// Whether "Couldn't load more. Try Again" shows.
    public var showsFailure: Bool { !failure.isHidden }

    private static var failureText: NSAttributedString {
        let font = UIFont.appFont(forTextStyle: .subheadline)
        let text = NSMutableAttributedString(
            string: "Couldn't load more. ",
            attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]
        )
        text.append(NSAttributedString(
            string: "Try Again",
            attributes: [.font: font, .foregroundColor: UIColor.tintColor]
        ))
        return text
    }

    private func apply() {
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        failure.isHidden = state != .failed
        switch state {
        case .idle:
            accessibilityLabel = nil
            accessibilityTraits = .none
            accessibilityElementsHidden = true
        case .loading:
            accessibilityLabel = loadingAccessibilityLabel
            accessibilityTraits = .staticText
            accessibilityElementsHidden = false
        case .failed:
            accessibilityLabel = "Couldn't load more. Try Again"
            accessibilityTraits = .button
            accessibilityElementsHidden = false
        }
    }

    @objc private func retry() {
        guard state == .failed else { return }
        onRetry?()
    }

    #if DEBUG
    /// Taps Try Again, as a finger would.
    public func debugTapRetry() { retry() }
    #endif
}

/// The footer as a list row — a diffable list's last item. A failed row is
/// tapped through the list's own selection (`didSelectItemAt`).
public final class PagingFooterCell: UICollectionViewListCell {
    public let footer = PagingFooterView()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        footer.pin(to: contentView)
        let height = footer.heightAnchor.constraint(greaterThanOrEqualToConstant: PagingFooterView.height)
        height.priority = .required - 1
        height.isActive = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(_ state: PagingFooterView.State) {
        footer.state = state
        isUserInteractionEnabled = state == .failed
        // The row reads as the footer.
        isAccessibilityElement = true
        accessibilityLabel = footer.accessibilityLabel
        accessibilityTraits = footer.accessibilityTraits
    }

    override public func prepareForReuse() {
        super.prepareForReuse()
        footer.state = .idle
    }
}

/// The footer as a section's supplementary view, spinning while shown — a
/// host shows it only while a next page is on its way.
public final class PagingFooterSupplementaryView: UICollectionReusableView {
    public let footer = PagingFooterView(state: .loading)

    override public init(frame: CGRect) {
        super.init(frame: frame)
        footer.pin(to: self)
        let height = footer.heightAnchor.constraint(equalToConstant: PagingFooterView.height)
        height.priority = .required - 1
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        footer.state = .loading
    }
}
