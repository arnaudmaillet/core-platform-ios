import UIKit

/// A `UIRefreshControl` that draws the branded loader (#1329) instead of the
/// stock spinner — a drop-in: `addAction(_:for: .valueChanged)`,
/// `scrollView.refreshControl =`, `endRefreshing()`, `isRefreshing`, all as
/// before.
///
/// UIKit keeps everything it does well — the gesture, the threshold, the
/// inset that holds the list open while refreshing. Only the drawing changes:
/// the stock spinner is tinted away and the loader follows the pull
/// (`setProgress`), turns on from there when the control fires, and closes
/// when it ends.
///
/// ⚠️ Lists under a floating header (the profile, the place) keep
/// `HeroPullToRefreshView`: a refresh control there draws under the header,
/// mid-screen — see that type. This is for the plain lists, where the stock
/// control sat in the right place and only looked wrong.
public final class AppRefreshControl: UIRefreshControl {
    private let loader = AppLoaderView(size: .medium)
    private var offsetObservation: NSKeyValueObservation?

    public override init() {
        super.init()
        // The stock spinner and its pull arrow, tinted away; the loader draws.
        tintColor = .clear
        addSubview(loader)
        // A user's pull fires `.valueChanged` without `beginRefreshing()`.
        addAction(UIAction { [weak self] _ in self?.loader.startAnimating() }, for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        loader.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(loader)
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        offsetObservation = (superview as? UIScrollView)?.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.follow(scrollView) }
        }
    }

    /// The pull, as far past the list's top as the stock control's own reach.
    private func follow(_ scrollView: UIScrollView) {
        guard !isRefreshing else { return }
        let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        loader.setProgress(pulled / HeroPullToRefreshView.threshold)
    }

    public override func beginRefreshing() {
        super.beginRefreshing()
        loader.startAnimating()
    }

    public override func endRefreshing() {
        super.endRefreshing()
        loader.stopAnimating()
    }

    #if DEBUG
    /// The loader this control drives — what a test reads.
    var debugLoader: AppLoaderView { loader }
    #endif
}
