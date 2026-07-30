import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// The For You pager: three format pages (Activity / Media / Short) in one
/// horizontally paging scroll view. Each format owns a fixed layout, so
/// swiping between pages IS the layout transition.
///
/// The nesting works because the axes never compete: this scroll view pages
/// horizontally only (its content height equals its frame height), and each
/// page scrolls vertically only (its content width equals the frame's), so
/// UIKit's standard pan arbitration routes each drag to exactly one of them.
///
/// Unlike the profile gallery's pager, this one does NOT sync its height to
/// the active page: every page is viewport-height and scrolls on its own.
final class ForYouPagerView: UIView {
    /// Pager order == selector order.
    static let pageOrder: [GalleryFilter.Format] = [.activity, .media, .short]

    /// The tapped post's index into the *given format page's* posts.
    var onItemTapped: ((GalleryFilter.Format, Int) -> Void)?
    /// Fired when a swipe settles on a page (not for programmatic paging) —
    /// the selector mirrors it.
    var onPageSettled: ((GalleryFilter.Format) -> Void)?
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?

    private let scrollView = UIScrollView()
    private let pages: [ForYouGridPage]
    private var activeIndex = 0

    /// The posts a page is showing — what a tile tap seeds from.
    func posts(for format: GalleryFilter.Format) -> [GalleryPost] {
        page(for: format)?.posts ?? []
    }

    /// The page itself, for a hero source that needs its geometry.
    func page(for format: GalleryFilter.Format) -> ForYouGridPage? {
        guard let index = Self.pageOrder.firstIndex(of: format) else { return nil }
        return pages[index]
    }

    /// Bottom inset every page keeps clear for the filter tray floating over it.
    var trayClearance: CGFloat = 0 {
        didSet { pages.forEach { $0.additionalBottomInset = trayClearance } }
    }

    init(imagePipeline: ImagePipeline) {
        pages = Self.pageOrder.map { format in
            ForYouGridPage(imagePipeline: imagePipeline, style: format == .media ? .grid : .list)
        }
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.pin(to: self)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for (index, page) in pages.enumerated() {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor)
            ])
            leading = page.trailingAnchor
            let format = Self.pageOrder[index]
            page.onItemTapped = { [weak self] item in self?.onItemTapped?(format, item) }
            page.onRefresh = { [weak self] in self?.onRefresh?() }
            // Only the page the user is actually reading may drive pagination:
            // the other two are laid out and would otherwise fire on their own
            // resting offsets while off-screen.
            page.onNearEnd = { [weak self] in
                guard let self, Self.pageOrder[activeIndex] == format else { return }
                onNearEnd?()
            }
        }
        NSLayoutConstraint.activate([
            leading.constraint(equalTo: content.trailingAnchor),
            content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ snapshot: ForYouViewModel.Snapshot) {
        for (index, format) in Self.pageOrder.enumerated() {
            pages[index].render(snapshot.state(for: format))
        }
    }

    func endRefreshing() {
        pages.forEach { $0.endRefreshing() }
    }

    /// Selector tap → smooth page.
    func setActivePage(_ format: GalleryFilter.Format, animated: Bool) {
        guard let index = Self.pageOrder.firstIndex(of: format), index != activeIndex else { return }
        activeIndex = index
        scrollView.setContentOffset(CGPoint(x: CGFloat(index) * bounds.width, y: 0), animated: animated)
    }

    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the offset page-aligned through width changes (first layout,
        // rotation) — offsets are in points, not page indices.
        guard bounds.width != lastLayoutWidth else { return }
        lastLayoutWidth = bounds.width
        scrollView.contentOffset = CGPoint(x: CGFloat(activeIndex) * bounds.width, y: 0)
    }
}

// MARK: - UIScrollViewDelegate

extension ForYouPagerView: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // The pages own their own delegate (`ForYouGridPage`), so nothing
        // vertical reaches this — only the horizontal pager settles here.
        guard bounds.width > 0 else { return }
        let landed = min(max(Int((scrollView.contentOffset.x / bounds.width).rounded()), 0), pages.count - 1)
        guard landed != activeIndex else { return }
        activeIndex = landed
        onPageSettled?(Self.pageOrder[landed])
    }
}
