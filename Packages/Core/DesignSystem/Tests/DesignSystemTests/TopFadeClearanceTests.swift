import Testing
import UIKit
@testable import DesignSystem

/// The titled contract starts the content below the soft fade at rest
/// (#2240): what the first content's INK lacks (#2286) is added to the top
/// inset — the whole depth for a plain list whose first row draws from its
/// top, less for a row whose ink starts lower, nothing for one whose own
/// padding clears it.
@MainActor
struct TopFadeClearanceTests {
    /// The fade's end plus the margin: how deep the first ink must start.
    private static let fade = SoftTopEdge.clearanceDepth
    /// The windows the lists stand in, kept for the suite's life.
    private static var windows: [UIWindow] = []

    /// Which layout the list wears: our compositional sections, or UIKit's
    /// list layout (its swipe-actions slot and section background are
    /// decorations of its own).
    private enum Layout { case sections, systemList }

    /// A list of `rows` rows whose first section starts `sectionTop` points
    /// into the content (0: a plain list's first row at the very top). Each
    /// row draws an avatar-like disc `inkTop` points below its own top, and
    /// `dress` adds what a case needs.
    private final class List: NSObject, UICollectionViewDataSource {
        let rows: Int
        let inkTop: CGFloat
        let dress: ((UICollectionViewCell) -> Void)?
        init(rows: Int, inkTop: CGFloat, dress: ((UICollectionViewCell) -> Void)?) {
            self.rows = rows
            self.inkTop = inkTop
            self.dress = dress
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            if let dress {
                dress(cell)
            } else {
                let disc = UIView(frame: CGRect(x: 16, y: inkTop, width: 40, height: 40))
                disc.backgroundColor = .systemGray5
                cell.contentView.addSubview(disc)
            }
            return cell
        }
    }

    private func makeList(rows: Int, sectionTop: CGFloat, inkTop: CGFloat = 0, layout kind: Layout = .sections,
                          dress: ((UICollectionViewCell) -> Void)? = nil) -> (UICollectionView, List) {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.backgroundColor = .systemBackground
        let systemList = UICollectionViewCompositionalLayout.list(using: listConfiguration)
        let sections = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: sectionTop, leading: 0, bottom: 0, trailing: 0)
            return section
        }
        let layout: UICollectionViewLayout = kind == .systemList ? systemList : sections
        let list = UICollectionView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), collectionViewLayout: layout)
        list.backgroundColor = .systemBackground
        list.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        let source = List(rows: rows, inkTop: inkTop, dress: dress)
        list.dataSource = source
        // On screen: the clearance is measured only there.
        let window = UIWindow(frame: list.frame)
        // Hidden: attached is enough (`window` is set), and a visible
        // window kept for the suite's life would take the key window from
        // the suites that present (ToastFullMessageTests failed).
        window.addSubview(list)
        Self.windows.append(window)
        return (list, source)
    }

    @Test func theMathAddsWhatTheFirstContentLacks() {
        #expect(SoftTopEdge.clearance(below: 0) == Self.fade)
        #expect(SoftTopEdge.clearance(below: 8) == Self.fade - 8)
        #expect(SoftTopEdge.clearance(below: 8, inset: 12) == Self.fade - 20)
        #expect(SoftTopEdge.clearance(below: Self.fade) == 0)
        #expect(SoftTopEdge.clearance(below: 120) == 0)
        #expect(SoftTopEdge.clearance(below: -30) == Self.fade, "content above the top is at the top")
    }

    /// The owner's case: a plain list's first row at the bar's bottom gets
    /// the whole fade, and rests below it.
    @Test func aPlainListGetsTheWholeFade() {
        let (list, source) = makeList(rows: 20, sectionTop: 0)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade)
        #expect(list.contentInset.top == Self.fade)
        #expect(list.contentOffset.y == -list.adjustedContentInset.top, "not at rest")
        withExtendedLifetime(source) {}
    }

    /// A grouped list whose section padding already clears the fade gets
    /// nothing: no screen changes look that did not need to.
    @Test func aListThatClearsTheFadeGetsNothing() {
        let (list, source) = makeList(rows: 20, sectionTop: Self.fade + 4)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == 0)
        #expect(list.contentInset.top == 0)
        #expect(list.contentOffset.y == -list.adjustedContentInset.top, "not at rest")
        withExtendedLifetime(source) {}
    }

    /// Padding that covers part of the fade: only the rest is added.
    @Test func aListThatCoversPartOfTheFadeGetsTheRest() {
        let (list, source) = makeList(rows: 20, sectionTop: 16)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade - 16)
        withExtendedLifetime(source) {}
    }

    /// Before its first layout — and while it is empty, under its skeleton
    /// or its empty state — a list reads as a plain one: the space is in
    /// place before the first frame, never added under the viewer's eyes.
    @Test func anEmptyListHasTheSpaceFromTheStart() {
        let (list, source) = makeList(rows: 0, sectionTop: 0)
        list.applyTopEdge(for: .titled)
        #expect(list.topFadeClearance == Self.fade)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade)
        withExtendedLifetime(source) {}
    }

    /// A screen's own top inset counts toward the fade, whether it was
    /// assigned before the contract or after it.
    @Test func theScreensOwnInsetCounts() {
        let (list, source) = makeList(rows: 20, sectionTop: 0)
        list.contentInset.top = 24
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade - 24)
        #expect(list.contentInset.top == Self.fade)
        // Assigned afterwards, as the post detail's stream shape does: the
        // value is the screen's base and the clearance is topped up again.
        list.contentInset.top = 10
        #expect(list.topFadeClearance == Self.fade - 10)
        #expect(list.contentInset.top == Self.fade)
        list.contentInset.top = 120
        #expect(list.topFadeClearance == 0)
        #expect(list.contentInset.top == 120)
        withExtendedLifetime(source) {}
    }

    /// A plain scroll view's content is its subviews.
    @Test func aPlainScrollViewMeasuresItsContent() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let content = UIView(frame: CGRect(x: 0, y: 12, width: 402, height: 900))
        content.backgroundColor = .systemGray6
        scroll.addSubview(content)
        scroll.contentSize = CGSize(width: 402, height: 912)
        let window = UIWindow(frame: scroll.frame)
        window.addSubview(scroll)
        Self.windows.append(window)
        scroll.applyTopEdge(for: .titled)
        #expect(scroll.topFadeClearance == Self.fade - 12)
    }

    /// The owner's Followers case (#2286): a row's avatar sits 7 pt inside
    /// its frame. The ink counts, not the frame: 7 pt less is added.
    @Test func aRowsInkNotItsFrameIsMeasured() {
        let (list, source) = makeList(rows: 20, sectionTop: 0, inkTop: 7)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade - 7)
        #expect(list.contentOffset.y == -list.adjustedContentInset.top, "not at rest")
        withExtendedLifetime(source) {}
    }

    /// UIKit's list layout adds decorations of its own — the swipe actions'
    /// slot at each row's top, the section's background from far above —
    /// which draw nothing there: the row's ink is what counts (measured on
    /// the relationships list, #2286).
    @Test func aSystemListLayoutsDecorationsAreNotInk() {
        let (list, source) = makeList(rows: 20, sectionTop: 0, inkTop: 7, layout: .systemList)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade - 7)
        withExtendedLifetime(source) {}
    }

    /// A row whose ink already starts past the depth gets nothing, though
    /// its frame starts at the bar's bottom.
    @Test func aListWhoseInkClearsTheFadeGetsNothing() {
        let (list, source) = makeList(rows: 20, sectionTop: 0, inkTop: Self.fade + 2)
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == 0)
        #expect(list.contentInset.top == 0)
        withExtendedLifetime(source) {}
    }

    /// A heading's ink is its text's cap top, not the label's frame, nor the
    /// header's (the inbox's "Join requests", #2286).
    @Test func aHeadingIsMeasuredFromItsText() {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let (list, source) = makeList(rows: 20, sectionTop: 0) { cell in
            let label = UILabel()
            label.font = font
            label.text = "Join requests"
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 16, y: 10)
            cell.contentView.addSubview(label)
        }
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        let capTop: CGFloat = 10 + font.ascender - font.capHeight
        #expect(list.topFadeClearance == (Self.fade - capTop).rounded(.up))
        withExtendedLifetime(source) {}
    }

    /// A fill the colour of the list's own ground draws nothing visible (a
    /// plain list's white cell): the disc below it is the ink.
    @Test func aFillTheGroundsColourIsNotInk() {
        let (list, source) = makeList(rows: 20, sectionTop: 0) { cell in
            cell.backgroundColor = .systemBackground
            cell.contentView.backgroundColor = .systemBackground
            let disc = UIView(frame: CGRect(x: 16, y: 9, width: 40, height: 40))
            disc.backgroundColor = .systemGray5
            cell.contentView.addSubview(disc)
            // A separator at the row's top is a hairline, not ink.
            let separator = UIView(frame: CGRect(x: 16, y: 0, width: 386, height: 0.33))
            separator.backgroundColor = .separator
            cell.contentView.addSubview(separator)
        }
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade - 9)
        withExtendedLifetime(source) {}
    }

    /// A card's ground in another colour than the screen's is ink from its
    /// top (an inset-grouped row): nothing changes for those.
    @Test func aGroundInAnotherColourIsInk() {
        let (list, source) = makeList(rows: 20, sectionTop: 0) { cell in
            cell.contentView.backgroundColor = .secondarySystemBackground
            let label = UILabel(frame: CGRect(x: 16, y: 20, width: 200, height: 20))
            label.text = "Account"
            cell.contentView.addSubview(label)
        }
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == Self.fade)
        withExtendedLifetime(source) {}
    }

    /// The fade's end is ONE value per header kind, and the depth is it
    /// plus the margin.
    @Test func theDepthIsTheFadesEndPlusTheMargin() {
        #expect(SoftTopEdge.clearanceDepth == SoftTopEdge.fadeLength + SoftTopEdge.inkMargin)
        #expect(SoftTopEdge.clearanceDepth(underStackedSearch: true)
            == SoftTopEdge.fadeLengthUnderStackedSearch + SoftTopEdge.inkMargin)
        #expect(SoftTopEdge.fadeLength < 40, "#2240's 40 pt was the effect view's frame, not the softening")
        #expect(SoftTopEdge.fadeLengthUnderStackedSearch < SoftTopEdge.fadeLength)
    }

    /// Under a search field stacked below the title (the inbox), the fade
    /// passes under the field: a list there keeps only the margin's worth.
    @Test func underAStackedSearchFieldOnlyTheMarginIsKept() {
        let (list, source) = makeList(rows: 20, sectionTop: 0)
        let screen = UIViewController()
        screen.view.addSubview(list)
        screen.navigationItem.searchController = UISearchController(searchResultsController: nil)
        screen.navigationItem.preferredSearchBarPlacement = .stacked
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        // Shown: a hidden window never installs its root's view, and the
        // clearance is measured only on screen. Hidden again at the end, so
        // the suites that present keep the key window.
        window.isHidden = false
        defer { window.isHidden = true }
        Self.windows.append(window)
        navigation.view.layoutIfNeeded()
        list.applyTopEdge(for: .titled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == SoftTopEdge.clearanceDepth(underStackedSearch: true))
        withExtendedLifetime(source) {}
    }

    /// The untitled header stays clear and gets no space (#1591).
    @Test func anUntitledHeaderGetsNoSpace() {
        let (list, source) = makeList(rows: 20, sectionTop: 0)
        list.applyTopEdge(for: .untitled)
        list.layoutIfNeeded()
        #expect(list.topFadeClearance == 0)
        #expect(list.contentInset.top == 0)
        withExtendedLifetime(source) {}
    }
}

/// Through the pager (#1628, #2240): the blur is the pager's, the space is
/// its lists'.
@MainActor
struct HorizontalPagerTopFadeClearanceTests {
    private static let fade = SoftTopEdge.clearanceDepth
    /// The windows the lists stand in, kept for the suite's life.
    private static var windows: [UIWindow] = []

    /// The clearance is measured only on screen.
    private func onScreen(_ view: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        view.layoutIfNeeded()
        Self.windows.append(window)
    }

    private func page() -> (UIView, UICollectionView) {
        let host = UIView()
        let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        list.pin(to: host)
        return (host, list)
    }

    @Test func theTitledPagerHandsTheSpaceToItsLists() {
        let first = page(), second = page()
        let pager = HorizontalPagerView(pages: [first.0, second.0], prefersClearTopEdge: false)
        onScreen(pager)
        pager.pagingScrollView.applyTopEdge(for: .titled)
        #expect(pager.pagingScrollView.topEdgeEffect.style == .soft)
        #expect(pager.pagingScrollView.contentInset.top == 0, "the pager's own content does not scroll under the bar")
        #expect(first.1.topFadeClearance == Self.fade)
        #expect(second.1.topFadeClearance == Self.fade)
    }

    /// A lazy page gets it when it is made, not only the pages made first.
    @Test func aLazyPageGetsItWhenItIsMade() {
        var made: [UICollectionView] = []
        let makers: [() -> UIView] = (0..<3).map { _ in
            {
                let (host, list) = self.page()
                made.append(list)
                return host
            }
        }
        let pager = HorizontalPagerView(lazyPages: makers, initialIndex: 0, prefersClearTopEdge: false)
        onScreen(pager)
        pager.pagingScrollView.applyTopEdge(for: .titled)
        #expect(made.count == 1)
        #expect(made[0].topFadeClearance == Self.fade)
        pager.setActivePage(2, animated: false)
        pager.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        pager.layoutIfNeeded()
        pager.pagingScrollView.contentOffset.x = 402 * 2
        #expect(made.count > 1, "no page was made")
        #expect(made.allSatisfy { $0.topFadeClearance == Self.fade })
    }

    /// A clear pager (the inbox, For You) hands nothing.
    @Test func aClearPagerHandsNothing() {
        let first = page()
        _ = HorizontalPagerView(pages: [first.0, page().0])
        #expect(first.1.topFadeClearance == 0)
    }
}
